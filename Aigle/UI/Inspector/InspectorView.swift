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
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "sidebar.trailing",
                    description: Text("Select an item to see its details.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Single item

    private func single(_ item: Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ThumbnailView(item: item, size: .large, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        controller.toggleLike(ids: [item.id])
                    } label: {
                        Image(systemName: item.liked ? "heart.fill" : "heart")
                            .foregroundStyle(item.liked ? .pink : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.liked ? "Unlike" : "Like")
                    .disabled(item.connectedFolderID != nil)
                }

                TagField(item: item)

                InspectorFacts(item: item)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Note")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $annotationDraft)
                        .font(.callout)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
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
            .padding(16)
        }
        .task(id: item.id) {
            annotationItemID = nil
            annotationDraft = item.annotation
            annotationItemID = item.id
        }
    }

    private var multipleSelection: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("\(controller.selectedItemIDs.count) items selected")
                .font(.headline)
            HStack {
                Button("Like All") { controller.toggleLike(ids: controller.selectedItemIDs) }
                Button("Move to Trash", role: .destructive) {
                    controller.moveToTrash(ids: controller.selectedItemIDs)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }
}

private struct InspectorFacts: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .font(.callout)
    }

    private func fact(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !item.tags.isEmpty {
                FlowLayout(spacing: 6) {
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
                FlowLayout(spacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            controller.addTags([suggestion], ids: [item.id])
                            draft = ""
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 7)
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
        HStack(spacing: 3) {
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
        .padding(.horizontal, 7)
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
