import AVFoundation
import AppKit
import SwiftUI

/// The expanded view. An in-window overlay (not a navigation push) so the shared
/// geometry with the grid cell actually matches.
struct DetailOverlay: View {
    let namespace: Namespace.ID

    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(CommandBus.self) private var bus

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinchStart: CGFloat?
    @State private var video = VideoPlaybackModel()
    @FocusState private var isFocused: Bool

    private var item: Item? { controller.detailItem }
    private var reduceMotion: Bool { settings.motionReduced }

    var body: some View {
        ZStack {
            scrim

            if let item {
                content(item)
                    .matchedGeometryEffect(id: item.id, in: namespace)
                    .padding(reduceMotion ? 0 : 28)
            }

            chrome
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .gesture(pinch)
        .gridEventMonitors(
            GridEventHandlers(
                onCommandScroll: { delta, _ in zoom(by: 1 + delta * 0.005) },
                onPan: { delta in offset = CGSize(width: offset.width - delta.width, height: offset.height + delta.height) },
                onSpaceKey: { close() }
            )
        )
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(characters: .init(charactersIn: "pP")) { _ in
            video.togglePlayback()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "mM")) { _ in
            video.toggleMute()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "aA")) { press in
            guard !press.modifiers.contains(.command) else { return .ignored }
            video.step(frames: -1)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "dD")) { _ in
            video.step(frames: 1)
            return .handled
        }
        .onChange(of: bus.saveFrameTicks) { _, _ in saveCurrentFrame() }
        .onChange(of: controller.detailItemID) { _, _ in resetZoom() }
        .transition(.opacity)
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.86), value: controller.detailItemID)
    }

    // MARK: - Pieces

    private var scrim: some View {
        Rectangle()
            .fill(.black.opacity(0.82))
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
            .onTapGesture { close() }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(_ item: Item) -> some View {
        Group {
            switch item.kind {
            case .video, .audio:
                if let url = controller.fileURL(for: item) {
                    VideoPane(url: url, model: video)
                } else {
                    missing
                }
            case .document:
                if let url = controller.fileURL(for: item) {
                    PDFDetailView(url: url)
                } else {
                    missing
                }
            case .vector:
                if let url = controller.fileURL(for: item) {
                    SVGDetailView(url: url)
                } else {
                    missing
                }
            case .animatedImage:
                if let url = controller.fileURL(for: item) {
                    AnimatedImageView(url: url, isPlaying: true, contentMode: .fit)
                } else {
                    missing
                }
            case .link:
                LinkDetailCard(item: item)
            case .image, .other:
                DetailImageView(item: item)
            }
        }
        .scaleEffect(scale)
        .offset(offset)
        .gesture(dragToPan)
        .onTapGesture(count: 2) { toggleActualSize() }
        .clipped()
    }

    private var missing: some View {
        ContentUnavailableView(
            "File not available",
            systemImage: "exclamationmark.triangle",
            description: Text("The original file couldn’t be found. If it lives in iCloud it may still be downloading.")
        )
    }

    @ViewBuilder
    private var chrome: some View {
        VStack {
            HStack(alignment: .top) {
                if let item {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.headline)
                        Text(detailSubtitle(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Spacer()
                HStack(spacing: 6) {
                    if let item {
                        Button {
                            controller.toggleLike(ids: [item.id])
                        } label: {
                            Image(systemName: item.liked ? "heart.fill" : "heart")
                        }
                        .help("Like (⌥-click in the grid)")
                    }
                    Button { close() } label: { Image(systemName: "xmark") }
                        .help("Close (Esc)")
                }
                .buttonStyle(.borderless)
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            if let item, item.kind.isPlayable {
                VideoControls(model: video) { saveCurrentFrame() }
                    .padding(.bottom, 8)
            }
        }
        .padding(16)
        .allowsHitTesting(true)
    }

    private func detailSubtitle(_ item: Item) -> String {
        var parts: [String] = [item.kind.displayName]
        if item.width > 0 { parts.append("\(item.width) × \(item.height)") }
        if item.size > 0 { parts.append(item.size.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Zoom & pan

    private var pinch: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchStart == nil { pinchStart = scale }
                guard let start = pinchStart else { return }
                scale = min(max(start * value.magnification, 0.4), 12)
            }
            .onEnded { _ in
                pinchStart = nil
                // Pinch-in past the threshold dismisses, Photos style.
                if scale < 0.72 {
                    close()
                } else if scale < 1 {
                    withAnimation(.snappy) { resetZoom() }
                }
            }
    }

    private var dragToPan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: offset.width + value.translation.width * 0.06,
                    height: offset.height + value.translation.height * 0.06
                )
            }
    }

    private func zoom(by factor: CGFloat) {
        scale = min(max(scale * factor, 0.4), 12)
    }

    private func toggleActualSize() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            if scale > 1.05 {
                resetZoom()
            } else {
                scale = 2.5
            }
        }
    }

    private func resetZoom() {
        scale = 1
        offset = .zero
    }

    // MARK: - Actions

    private func close() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.4, dampingFraction: 0.88)) {
            controller.closeDetail()
        }
        video.pause()
        resetZoom()
    }

    private func step(_ offset: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            controller.stepDetail(by: offset)
        }
    }

    private func saveCurrentFrame() {
        guard let item, item.kind == .video, let url = controller.fileURL(for: item) else { return }
        let seconds = video.currentTime
        Task.detached(priority: .userInitiated) {
            guard let frame = await MediaProbe.exactVideoFrame(url, at: seconds),
                  let png = MediaProbe.pngData(frame)
            else { return }
            let stamp = String(format: "%.2f", seconds)
            await MainActor.run {
                controller.importImageData(png, name: "\(item.name) @\(stamp)s", ext: "png", into: nil)
            }
        }
    }
}

/// Keeps the previous frame on screen until the next image is decoded, so
/// arrow-key flipping never flashes white.
private struct DetailImageView: View {
    let item: Item

    @Environment(AppSettings.self) private var settings
    @State private var displayed: RenderedImage?
    @State private var displayedID: String = ""

    var body: some View {
        ZStack {
            if let displayed {
                Image(decorative: displayed.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .id(displayedID)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .animation(settings.motionReduced ? nil : .easeOut(duration: 0.14), value: displayedID)
        .task(id: item.id) { await load() }
    }

    private func load() async {
        // Show whatever the grid already decoded instantly — biggest first — so
        // flipping through never blanks, then upgrade to the real thing.
        if displayed == nil || displayedID != item.id {
            for size in [ThumbnailSize.huge, .large, .medium] {
                guard let quick = await ThumbnailPipeline.shared.cachedSynchronously(item, size: size) else { continue }
                displayed = quick
                displayedID = item.id
                break
            }
        }
        // `.full` decodes near the original's own resolution rather than a
        // preview, which is what makes the detail view look like the file you
        // imported instead of a blown-up thumbnail.
        guard let full = await ThumbnailPipeline.shared.thumbnail(for: item, size: .full) else { return }
        guard !Task.isCancelled else { return }
        displayed = full
        displayedID = item.id
    }
}

private struct LinkDetailCard: View {
    let item: Item

    var body: some View {
        VStack(spacing: 16) {
            ThumbnailView(item: item, size: .huge, contentMode: .fit)
                .frame(maxWidth: 720, maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.name)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let url = URL(string: item.url) {
                Link(destination: url) {
                    Label(url.absoluteString, systemImage: "safari")
                        .lineLimit(1)
                }
            }
        }
        .padding(28)
    }
}
