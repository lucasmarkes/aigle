import AVFoundation
import AppKit
import Observation
import SwiftUI

/// Playback state for the expanded view, driving both the transport controls and
/// the keyboard shortcuts (P play/pause, A/D step, M mute, ⌘⇧S save frame).
@MainActor
@Observable
public final class VideoPlaybackModel {
    public private(set) var duration: Double = 0
    public var currentTime: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isMuted = false
    public private(set) var frameDuration: Double = 1.0 / 30.0

    @ObservationIgnored public private(set) var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loadedURL: URL?

    public init() {}

    public func load(url: URL) async {
        guard loadedURL != url else { return }
        teardown()
        loadedURL = url
        let asset = AVURLAsset(url: url)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = isMuted
        self.player = player

        if let assetDuration = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(assetDuration)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.nominalFrameRate), rate > 0 {
            frameDuration = 1.0 / Double(rate)
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = CMTimeGetSeconds(time)
            }
        }
        player.play()
        isPlaying = true
    }

    public func togglePlayback() {
        guard let player else { return }
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    public func step(frames: Int) {
        guard let player else { return }
        player.pause()
        isPlaying = false
        let target = max(0, min(duration, currentTime + Double(frames) * frameDuration))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    public func seek(to seconds: Double) {
        guard let player else { return }
        let target = max(0, min(duration, seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    public func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}

struct VideoPane: View {
    let url: URL
    let model: VideoPlaybackModel

    var body: some View {
        PlayerLayerView(model: model)
            .task(id: url) { await model.load(url: url) }
            .onDisappear { model.pause() }
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let model: VideoPlaybackModel

    func makeNSView(context: Context) -> LayerHost {
        let view = LayerHost()
        view.attach(model.player)
        return view
    }

    func updateNSView(_ nsView: LayerHost, context: Context) {
        nsView.attach(model.player)
    }

    final class LayerHost: NSView {
        private var playerLayer: AVPlayerLayer?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        func attach(_ player: AVPlayer?) {
            guard playerLayer?.player !== player else { return }
            playerLayer?.removeFromSuperlayer()
            guard let player else {
                playerLayer = nil
                return
            }
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.frame = bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            self.layer?.addSublayer(layer)
            playerLayer = layer
        }

        override func layout() {
            super.layout()
            playerLayer?.frame = bounds
        }
    }
}

/// Transport bar: scrub, play/pause, frame step, mute, save frame.
struct VideoControls: View {
    let model: VideoPlaybackModel
    let onSaveFrame: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .help("Play / pause (P)")

            Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Previous frame (A)")
            Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Next frame (D)")

            Text(timecode(model.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                in: 0...max(model.duration, 0.01)
            )
            .controlSize(.small)

            Text(timecode(model.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button { model.toggleMute() } label: {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help("Mute (M)")

            Button(action: onSaveFrame) {
                Image(systemName: "camera.fill")
            }
            .help("Save this frame to Inbox (⌘⇧S)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: 640)
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
