import AppKit
import SwiftUI

/// One thumbnail in the justified grid.
struct GridCell: View {
    let item: Item
    let size: CGSize
    let isSelected: Bool
    let isFocused: Bool
    let namespace: Namespace.ID
    let isDetailSource: Bool

    @Environment(AppSettings.self) private var settings
    @Environment(LibraryController.self) private var controller
    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: settings.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            // While the detail overlay owns this item, its hero view lives there;
            // removing it here is what lets matchedGeometryEffect animate.
            if !isDetailSource {
                media
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    }
                    .overlay(alignment: .bottomLeading) { nameLabel }
                    .overlay(alignment: .bottomTrailing) { badges }
                    .overlay { selectionRing }
                    .matchedGeometryEffect(id: item.id, in: namespace)
            } else {
                shape.fill(.quaternary.opacity(0.35))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .scaleEffect(isHovering && !isSelected ? 1.012 : 1)
        .animation(settings.motionReduced ? nil : .snappy(duration: 0.16), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering { controller.hoveredItemID = item.id }
            else if controller.hoveredItemID == item.id { controller.hoveredItemID = nil }
        }
        .help(item.name)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isImage] : .isImage)
    }

    @ViewBuilder
    private var media: some View {
        let fit: ContentMode = settings.thumbnailFit == .fill ? .fill : .fit
        let bucket = ThumbnailSize.bucket(for: max(size.width, size.height))

        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            if settings.autoplayInGrid, item.kind == .video, let url = controller.fileURL(for: item) {
                LoopingVideoView(url: url, isPlaying: true)
            } else if settings.autoplayInGrid, item.kind == .animatedImage, let url = controller.fileURL(for: item) {
                AnimatedImageView(url: url, isPlaying: true, contentMode: fit)
            } else if item.kind == .link {
                LinkCellContent(item: item, size: bucket)
            } else {
                ThumbnailView(item: item, size: bucket, contentMode: fit)
            }
        }
    }

    @ViewBuilder
    private var nameLabel: some View {
        if settings.showFileNames, size.height > 64 {
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(maxWidth: size.width * 0.75, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if item.aigle.virtualCopyOf != nil {
                CellBadge(symbol: "square.on.square")
            }
            if item.kind == .video || item.kind == .animatedImage {
                CellBadge(symbol: item.kind == .video ? "play.fill" : "photo.stack.fill")
            }
            if settings.showLikeBadges, item.liked {
                CellBadge(symbol: "heart.fill", tint: .pink)
            }
        }
        .padding(6)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var selectionRing: some View {
        let tint = settings.selectionTint.color
        shape
            .strokeBorder(tint, lineWidth: isSelected ? 3 : 0)
            .overlay {
                if isFocused && !isSelected {
                    shape.strokeBorder(tint.opacity(0.55), lineWidth: 2)
                }
            }
            .animation(settings.motionReduced ? nil : .snappy(duration: 0.14), value: isSelected)
    }
}

private struct CellBadge: View {
    let symbol: String
    var tint: Color = .white

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(4)
            .background(.black.opacity(0.45), in: Circle())
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
}

/// Link items show their fetched preview with a hostname chip.
private struct LinkCellContent: View {
    let item: Item
    let size: ThumbnailSize

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ThumbnailView(item: item, size: size, contentMode: .fill)
            HStack(spacing: 4) {
                Image(systemName: "link")
                Text(host)
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
        }
    }

    private var host: String {
        URL(string: item.url)?.host() ?? item.url
    }
}
