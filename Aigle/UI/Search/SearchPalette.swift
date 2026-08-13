import SwiftUI

/// ⌘K — a command-palette search across the whole library *and* every connected
/// folder. Keyboard first: type, arrow, return.
struct SearchPalette: View {
    @Environment(LibraryController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    private var searchableItems: [Item] {
        controller.liveItems + controller.connectedItems.values.flatMap { $0 }
    }

    private var results: [Item] {
        SearchMatcher.rank(searchableItems, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search names and tags…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFieldFocused)
                    .onSubmit { open(results.indices.contains(highlighted) ? results[highlighted] : nil) }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "Start typing to search" : "No matches")
                        .foregroundStyle(.secondary)
                    if query.isEmpty {
                        Text("Aigle searches your library and every connected folder.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                SearchResultRow(item: item, isHighlighted: index == highlighted)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(item) }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 340)
                    .onChange(of: highlighted) { _, newValue in
                        guard results.indices.contains(newValue) else { return }
                        proxy.scrollTo(results[newValue].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 620)
        .background(.regularMaterial)
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func open(_ item: Item?) {
        guard let item else { return }
        if let folderID = item.connectedFolderID {
            controller.selection = .connectedFolder(folderID)
        } else if controller.selection != .smart(.all) {
            controller.selection = .smart(.all)
        }
        controller.selectedItemIDs = [item.id]
        controller.focusedItemID = item.id
        controller.openDetail(item.id)
        dismiss()
    }
}

private struct SearchResultRow: View {
    let item: Item
    let isHighlighted: Bool

    @Environment(LibraryController.self) private var controller

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(item: item, size: .small, contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(location)
                        .foregroundStyle(.secondary)
                    if !item.tags.isEmpty {
                        Text(item.tags.prefix(3).joined(separator: ", "))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer()
            if item.liked {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
            }
            Text(item.ext.uppercased())
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.22) : .clear)
        )
    }

    private var location: String {
        if let folderID = item.connectedFolderID {
            return controller.connectedFolders.first { $0.id == folderID }?.name
                ?? String(localized: "Connected folder")
        }
        let names = item.folders.compactMap { controller.collections.find($0)?.name }
        return names.first ?? String(localized: "Library")
    }
}
