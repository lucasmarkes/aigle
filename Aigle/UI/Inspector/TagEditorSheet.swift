import SwiftUI

/// ⌘T — tag the current selection from anywhere, including multi-select.
struct TagEditorSheet: View {
    @Environment(LibraryController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var pending: [String] = []
    @FocusState private var isFocused: Bool

    private var targets: Set<String> {
        controller.selectedItemIDs.isEmpty
            ? Set([controller.focusedItemID, controller.hoveredItemID].compactMap { $0 })
            : controller.selectedItemIDs
    }

    private var sharedTags: [String] {
        let sets = targets.compactMap { controller.item($0)?.tags }.map(Set.init)
        guard let first = sets.first else { return [] }
        return sets.dropFirst().reduce(first) { $0.intersection($1) }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(targets.count == 1 ? "Tags" : "Tag \(targets.count) items")
                .font(.headline)

            if !sharedTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(sharedTags, id: \.self) { tag in
                        TagChip(tag: tag) { controller.removeTag(tag, ids: targets) }
                    }
                }
            }

            if !pending.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(pending, id: \.self) { tag in
                        TagChip(tag: tag) { pending.removeAll { $0 == tag } }
                    }
                }
            }

            TextField("Add tags, separated by commas", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(stage)

            if !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            pending.append(suggestion)
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

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") {
                    stage()
                    if !pending.isEmpty { controller.addTags(pending, ids: targets) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(targets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFocused = true }
    }

    private var suggestions: [String] {
        let query = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return controller.allTags
            .filter { $0.lowercased().hasPrefix(query) && !pending.contains($0) && !sharedTags.contains($0) }
            .prefix(8)
            .map { $0 }
    }

    private func stage() {
        let tags = draft
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !pending.contains($0) }
        pending.append(contentsOf: tags)
        draft = ""
    }
}
