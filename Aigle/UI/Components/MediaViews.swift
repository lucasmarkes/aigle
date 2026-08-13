import AVKit
import AppKit
import PDFKit
import SwiftUI
import WebKit

// MARK: - Animated images (GIF / APNG)

/// `NSImageView` already knows how to animate multi-frame images; wrapping it is
/// cheaper and smoother than driving frames from SwiftUI.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL
    var isPlaying: Bool = true
    var contentMode: ContentMode = .fit

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = contentMode == .fill ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        view.animates = isPlaying
        view.canDrawSubviewsIntoLayer = true
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            nsView.image = NSImage(contentsOf: url)
        }
        nsView.animates = isPlaying
        nsView.imageScaling = contentMode == .fill ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
    }
}

// MARK: - Video

/// A muted, looping `AVPlayerLayer` cell for in-grid autoplay.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var isPlaying: Bool

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.configure(url: url)
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        nsView.configure(url: url)
        nsView.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ nsView: PlayerHostView, coordinator: ()) {
        nsView.tearDown()
    }

    final class PlayerHostView: NSView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var playerLayer: AVPlayerLayer?
        private var currentURL: URL?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        func configure(url: URL) {
            guard currentURL != url else { return }
            tearDown()
            currentURL = url
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            let layer = AVPlayerLayer(player: queue)
            layer.videoGravity = .resizeAspect
            layer.frame = bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            self.layer?.addSublayer(layer)
            playerLayer = layer
            player = queue
        }

        func setPlaying(_ playing: Bool) {
            playing ? player?.play() : player?.pause()
        }

        func tearDown() {
            player?.pause()
            looper?.disableLooping()
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            looper = nil
            player = nil
            currentURL = nil
        }

        override func layout() {
            super.layout()
            playerLayer?.frame = bounds
        }
    }
}

// MARK: - PDF

struct PDFDetailView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - SVG

/// Full-fidelity vector rendering for the detail view. `NSImage` handles SVG for
/// thumbnails; WebKit keeps text and gradients crisp at any zoom.
struct SVGDetailView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        nsView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
    }
}
