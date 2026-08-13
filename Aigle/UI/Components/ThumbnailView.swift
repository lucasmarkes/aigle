import SwiftUI

/// Async, cached thumbnail. Never blanks on reuse: the previously decoded image
/// stays visible until the next one is ready, then crossfades.
struct ThumbnailView: View {
    let item: Item
    let size: ThumbnailSize
    var contentMode: ContentMode = .fit

    @Environment(AppSettings.self) private var settings
    @State private var rendered: RenderedImage?
    @State private var loadedKey: String = ""

    private var key: String { "\(item.id)#\(item.mtime)@\(size.rawValue)" }

    var body: some View {
        ZStack {
            if let rendered {
                Image(decorative: rendered.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                ThumbnailPlaceholder(item: item)
            }
        }
        .animation(settings.motionReduced ? nil : .easeOut(duration: 0.18), value: loadedKey)
        .task(id: key) { await load() }
    }

    private func load() async {
        if let cached = await ThumbnailPipeline.shared.cachedSynchronously(item, size: size) {
            rendered = cached
            loadedKey = key
            return
        }
        let image = await ThumbnailPipeline.shared.thumbnail(for: item, size: size)
        guard !Task.isCancelled else { return }
        if let image {
            rendered = image
            loadedKey = key
        }
    }
}

/// Shown only until pixels arrive — a typed glyph rather than a grey box, so a
/// cold library still reads as content.
struct ThumbnailPlaceholder: View {
    let item: Item

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }

    private var symbol: String {
        switch item.kind {
        case .image: "photo"
        case .animatedImage: "photo.stack"
        case .vector: "scribble.variable"
        case .document: "doc.richtext"
        case .video: "film"
        case .audio: "waveform"
        case .link: "link"
        case .other: "doc"
        }
    }
}
