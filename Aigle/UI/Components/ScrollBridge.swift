import AppKit
import SwiftUI

/// Hands the underlying `NSScrollView` to SwiftUI so we can pan it directly
/// (space-drag, middle-mouse drag) and keep content anchored under the cursor
/// while zooming — the way Photos and Figma behave.
@MainActor
public final class ScrollBridge {
    public weak var scrollView: NSScrollView?

    public init() {}

    public var visibleRect: CGRect { scrollView?.contentView.documentVisibleRect ?? .zero }
    public var contentSize: CGSize { scrollView?.documentView?.frame.size ?? .zero }

    public func scroll(by delta: CGSize) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        var origin = scrollView.contentView.bounds.origin
        origin.x += delta.width
        origin.y += delta.height
        let maxX = max(0, documentView.frame.width - scrollView.contentView.bounds.width)
        let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), maxY)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    public func scroll(toY y: CGFloat) {
        guard let scrollView else { return }
        var origin = scrollView.contentView.bounds.origin
        origin.y = max(0, y)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Keeps the content point under `anchorY` fixed while the content height changes.
    public func preserveAnchor(anchorY: CGFloat, oldContentHeight: CGFloat, newContentHeight: CGFloat) {
        guard oldContentHeight > 0, newContentHeight > 0, let scrollView else { return }
        let visible = scrollView.contentView.bounds
        let focus = visible.origin.y + anchorY
        let ratio = focus / oldContentHeight
        let target = ratio * newContentHeight - anchorY
        scroll(toY: target)
    }
}

/// Locates the enclosing `NSScrollView` without disturbing the hierarchy.
public struct ScrollViewFinder: NSViewRepresentable {
    let bridge: ScrollBridge

    public init(bridge: ScrollBridge) { self.bridge = bridge }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setFrameSize(.zero)
        DispatchQueue.main.async { attach(from: view) }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        if bridge.scrollView == nil {
            DispatchQueue.main.async { attach(from: nsView) }
        }
    }

    private func attach(from view: NSView) {
        var candidate: NSView? = view
        while let current = candidate {
            if let scrollView = current as? NSScrollView {
                bridge.scrollView = scrollView
                return
            }
            candidate = current.superview
        }
    }
}
