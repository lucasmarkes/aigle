import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar item doubles as a drop target: drop files, images or links on it
/// and they land in the Inbox, even with the main window closed.
struct MenuBarPanel: View {
    @Environment(LibraryController.self) private var controller

    var body: some View {
        Group {
            if controller.isOpen {
                Text(controller.libraryName)
                Divider()
                Button("Open Aigle") { activate() }
                Button("Add Files…") { pickFiles() }
                Button("Paste from Clipboard") {
                    DropImporter.paste(into: nil, controller: controller)
                }
                Divider()
                Text("Inbox: \(controller.items(for: .smart(.inbox)).count) items")
            } else {
                Button("Open Aigle to choose a library") { activate() }
            }
            Divider()
            Button("Quit Aigle") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .task { MenuBarDropTarget.shared.install(controller: controller) }
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        controller.importToInbox(panel.urls)
    }
}

/// `MenuBarExtra` doesn't expose its status item, so we find the button and slip
/// a transparent dragging destination over it.
@MainActor
final class MenuBarDropTarget {
    static let shared = MenuBarDropTarget()

    private weak var controller: LibraryController?
    private var overlay: DropOverlayView?

    private init() {}

    func install(controller: LibraryController) {
        self.controller = controller
        overlay?.controller = controller
        guard overlay == nil else { return }
        guard let button = Self.findStatusButton() else { return }
        let overlay = DropOverlayView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.controller = controller
        button.addSubview(overlay)
        self.overlay = overlay
    }

    private static func findStatusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = search(window.contentView) { return button }
        }
        return nil
    }

    private static func search(_ view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let hit = search(subview) { return hit }
        }
        return nil
    }

    final class DropOverlayView: NSView {
        weak var controller: LibraryController?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        // Clicks must still open the menu; only drags are ours.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            controller?.isOpen == true ? .copy : []
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard let controller else { return false }
            let pasteboard = sender.draggingPasteboard

            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
                let files = urls.filter(\.isFileURL)
                if !files.isEmpty { controller.importToInbox(files) }
                for url in urls where !url.isFileURL {
                    if ItemKind.importableExtensions.contains(url.pathExtension.lowercased()) {
                        controller.importRemoteMedia(url, into: nil)
                    } else {
                        controller.importLink(url, into: nil)
                    }
                }
                return true
            }

            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                guard let data = pasteboard.data(forType: type) else { continue }
                controller.importImageData(
                    data,
                    name: "Dropped \(Date().formatted(date: .numeric, time: .standard))",
                    ext: type == .png ? "png" : "tiff",
                    into: nil
                )
                return true
            }
            return false
        }
    }
}
