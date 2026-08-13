import SwiftUI

/// Details for the current selection: preview, name, tags, dimensions, note, like.
struct InspectorView: View {
    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings

    @State private var annotationDraft = ""
    @State private var annotationItemID: String?

    private var item: Item? { controller.inspectorItem }

    var body: some View {
        Group {
            if controller.selectedItemIDs.count > 1 {
                multipleSelection
            } else if let item {
                single(item)
            } else {
                // A full-size ContentUnavailableView here shouted at the user from
                // a 280pt panel; the empty inspector should recede instead.
                //
                // Anchored to the top like the other two states rather than
                // centred in the panel: centred, it slid up the moment you
                // selected anything, so the panel appeared to twitch on every
                // click.
                Text("Select an item to see its details.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(Metrics.l)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Single item

    private func single(_ item: Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.xl) {
                ThumbnailView(item: item, size: .large, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .background(.quaternary.opacity(0.3), in: cardShape())
                    .clipShape(cardShape())
                    .overlay { cardShape().strokeBorder(.hairline) }

                HStack(alignment: .firstTextBaseline, spacing: Metrics.s) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: Metrics.xs)
                    LikeButton(item: item)
                }

                InspectorSection("Tags") {
                    TagField(item: item)
                }

                InspectorSection("Details") {
                    InspectorFacts(item: item)
                }

                InspectorSection("Note") {
                    TextEditor(text: $annotationDraft)
                        .font(.callout)
                        .frame(minHeight: 72)
                        .scrollContentBackground(.hidden)
                        .padding(Metrics.s)
                        .background(.quaternary.opacity(0.4), in: cardShape(Metrics.radiusSmall))
                        .overlay { cardShape(Metrics.radiusSmall).strokeBorder(.hairline) }
                        .disabled(item.connectedFolderID != nil)
                        .onChange(of: annotationDraft) { _, newValue in
                            guard annotationItemID == item.id else { return }
                            controller.setAnnotation(newValue, id: item.id)
                        }
                }

                if !item.url.isEmpty, let url = URL(string: item.url), !url.isFileURL {
                    Link(destination: url) {
                        Label(url.host() ?? item.url, systemImage: "link")
                            .lineLimit(1)
                    }
                    .font(.callout)
                }
            }
            .padding(Metrics.l)
        }
        .task(id: item.id) {
            annotationItemID = nil
            annotationDraft = item.annotation
            annotationItemID = item.id
        }
    }

    private var multipleSelection: some View {
        VStack(spacing: Metrics.l) {
            SelectionStack(items: controller.selectedItems.prefix(3).map { $0 })
            Text("\(controller.selectedItemIDs.count) items selected")
                .font(.headline)
            // The frame goes on each label, not on the stack: on the stack it
            // only widens the container and leaves two buttons sized to their
            // own text, which is what made them ragged.
            VStack(spacing: Metrics.s) {
                Button {
                    controller.toggleLike(ids: controller.selectedItemIDs)
                } label: {
                    Text("Like All").frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    controller.moveToTrash(ids: controller.selectedItemIDs)
                } label: {
                    Text("Move to Trash").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        // Same inset as the single-item view, so the thumbnail and the
        // selection stack start on the same line.
        .padding(Metrics.l)
    }
}

/// Fanned thumbnails of what's selected — more legible at a glance than a
/// generic "stack of squares" symbol.
private struct SelectionStack: View {
    let items: [Item]

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated().reversed()), id: \.element.id) { index, item in
                ThumbnailView(item: item, size: .small, contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(cardShape(Metrics.radiusSmall))
                    .overlay { cardShape(Metrics.radiusSmall).strokeBorder(.hairline) }
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .rotationEffect(.degrees(Double(index - 1) * 7))
                    .offset(x: CGFloat(index - 1) * 10)
                    .zIndex(Double(items.count - index))
            }
        }
        .frame(height: 76)
    }
}

/// A like toggle that pops when it turns on.
private struct LikeButton: View {
    let item: Item

    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Button {
            controller.toggleLike(ids: [item.id])
        } label: {
            Image(systemName: item.liked ? "heart.fill" : "heart")
                .font(.system(size: 14))
                .foregroundStyle(item.liked ? .pink : .secondary)
                .scaleEffect(item.liked ? 1.1 : 1)
                .animation(settings.motionReduced ? nil : .bouncy(duration: 0.3), value: item.liked)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.liked ? "Unlike" : "Like")
        .disabled(item.connectedFolderID != nil)
    }
}

/// Label + content, so every inspector block shares one header treatment.
private struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)
            content
        }
    }
}

private struct InspectorFacts: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.xs) {
            fact("Kind", value: item.kind.displayName)
            if item.width > 0 && item.height > 0 {
                fact("Dimensions", value: "\(item.width) × \(item.height)")
            }
            if item.size > 0 {
                fact("Size", value: item.size.formatted(.byteCount(style: .file)))
            }
            fact("Added", value: item.dateAdded.formatted(date: .abbreviated, time: .shortened))
            if !item.ext.isEmpty {
                fact("Format", value: item.ext.uppercased())
            }
            if item.aigle.virtualCopyOf != nil {
                fact("Copy", value: String(localized: "Virtual copy"))
            }
        }
        .font(.subheadline)
    }

    private func fact(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.s) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: Metrics.s)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

extension ItemKind {
    var displayName: String {
        switch self {
        case .image: String(localized: "Image")
        case .animatedImage: String(localized: "Animated image")
        case .vector: String(localized: "Vector")
        case .document: String(localized: "Document")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .link: String(localized: "Link")
        case .other: String(localized: "File")
        }
    }
}

/// Token-style tag editing with autocomplete from the library's tag history.
struct TagField: View {
    let item: Item

    @Environment(LibraryController.self) private var controller
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            if !item.tags.isEmpty {
                FlowLayout(spacing: Metrics.xs) {
                    ForEach(item.tags, id: \.self) { tag in
                        TagChip(tag: tag) {
                            controller.removeTag(tag, ids: [item.id])
                        }
                    }
                }
            }

            TextField("Add a tag", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .disabled(item.connectedFolderID != nil)

            if !suggestions.isEmpty {
                FlowLayout(spacing: Metrics.xs) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            controller.addTags([suggestion], ids: [item.id])
                            draft = ""
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, Metrics.s)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                }
            }
        }
    }

    private var suggestions: [String] {
        let query = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return controller.allTags
            .filter { $0.lowercased().hasPrefix(query) && !item.tags.contains($0) }
            .prefix(6)
            .map { $0 }
    }

    private func commit() {
        let tags = draft.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !tags.isEmpty else { return }
        controller.addTags(tags, ids: [item.id])
        draft = ""
    }
}

struct TagChip: View {
    let tag: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: Metrics.xs) {
            Text(tag)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, Metrics.s)
        .padding(.vertical, 3)
        .background(.tint.opacity(0.18), in: Capsule())
    }
}

/// Wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
