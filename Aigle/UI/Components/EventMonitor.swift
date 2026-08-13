import AppKit
import SwiftUI

/// What the grid (and the zoomed detail view) need from raw AppKit events:
/// ⌘-scroll zoom for mouse users, middle-mouse and space+drag panning, and the
/// space key doubling as Quick Look.
@MainActor
public struct GridEventHandlers {
    public var onCommandScroll: ((CGFloat, CGPoint) -> Void)?
    public var onPan: ((CGSize) -> Void)?
    public var onSpaceKey: (() -> Void)?
    public var spaceHeldChanged: ((Bool) -> Void)?

    public init(
        onCommandScroll: ((CGFloat, CGPoint) -> Void)? = nil,
        onPan: ((CGSize) -> Void)? = nil,
        onSpaceKey: (() -> Void)? = nil,
        spaceHeldChanged: ((Bool) -> Void)? = nil
    ) {
        self.onCommandScroll = onCommandScroll
        self.onPan = onPan
        self.onSpaceKey = onSpaceKey
        self.spaceHeldChanged = spaceHeldChanged
    }
}

@MainActor
final class GridEventMonitor {
    private var monitors: [Any] = []
    private var handlers = GridEventHandlers()
    private var spaceHeld = false
    private var panning = false
    private weak var hostWindow: NSWindow?

    func update(handlers: GridEventHandlers, window: NSWindow?) {
        self.handlers = handlers
        self.hostWindow = window
    }

    func start() {
        guard monitors.isEmpty else { return }

        addMonitor(matching: [.scrollWheel]) { [weak self] event in
            guard let self, self.isOurWindow(event) else { return event }
            if event.modifierFlags.contains(.command) {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 8
                self.handlers.onCommandScroll?(delta, event.locationInWindow)
                return nil
            }
            if self.spaceHeld {
                self.handlers.onPan?(CGSize(width: -event.scrollingDeltaX, height: event.scrollingDeltaY))
                return nil
            }
            return event
        }

        addMonitor(matching: [.otherMouseDown]) { [weak self] event in
            guard let self, self.isOurWindow(event), event.buttonNumber == 2 else { return event }
            self.panning = true
            NSCursor.closedHand.push()
            return nil
        }

        addMonitor(matching: [.otherMouseDragged]) { [weak self] event in
            guard let self, self.panning else { return event }
            self.handlers.onPan?(CGSize(width: -event.deltaX, height: event.deltaY))
            return nil
        }

        addMonitor(matching: [.otherMouseUp]) { [weak self] event in
            guard let self, self.panning else { return event }
            self.panning = false
            NSCursor.pop()
            return nil
        }

        addMonitor(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self, self.spaceHeld else { return event }
            self.handlers.onPan?(CGSize(width: -event.deltaX, height: event.deltaY))
            return nil
        }

        addMonitor(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isOurWindow(event) else { return event }
            guard event.keyCode == 49 else { return event }              // space
            guard !self.isEditingText(event) else { return event }
            if !event.isARepeat {
                self.handlers.onSpaceKey?()
            }
            if !self.spaceHeld {
                self.spaceHeld = true
                self.handlers.spaceHeldChanged?(true)
            }
            return nil
        }

        addMonitor(matching: [.keyUp]) { [weak self] event in
            guard let self, event.keyCode == 49, self.spaceHeld else { return event }
            self.spaceHeld = false
            self.handlers.spaceHeldChanged?(false)
            return nil
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if panning {
            panning = false
            NSCursor.pop()
        }
    }

    private func addMonitor(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(monitor)
        }
    }

    private func isOurWindow(_ event: NSEvent) -> Bool {
        guard let hostWindow else { return true }
        return event.window === hostWindow
    }

    private func isEditingText(_ event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder else { return false }
        if responder is NSTextView { return true }
        return responder.className.contains("TextField")
    }
}

/// Installs the AppKit event monitors for the lifetime of the attached view.
public struct GridEventMonitorModifier: ViewModifier {
    let handlers: GridEventHandlers
    @State private var monitor = GridEventMonitor()
    @State private var window: NSWindow?

    public func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window = $0 })
            .onAppear {
                monitor.update(handlers: handlers, window: window)
                monitor.start()
            }
            .onDisappear { monitor.stop() }
            .onChange(of: window) { _, newValue in
                monitor.update(handlers: handlers, window: newValue)
            }
            .task(id: ObjectIdentifier(GridEventMonitor.self)) {
                monitor.update(handlers: handlers, window: window)
            }
    }
}

extension View {
    public func gridEventMonitors(_ handlers: GridEventHandlers) -> some View {
        modifier(GridEventMonitorModifier(handlers: handlers))
    }
}

/// Grabs the hosting `NSWindow` so monitors can ignore other windows.
public struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    public init(onResolve: @escaping (NSWindow?) -> Void) { self.onResolve = onResolve }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
