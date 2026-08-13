import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Library, Collections and Folders — with counts, drag-in, nesting and reorder.
struct SidebarView: View {
    @Binding var confirmEmptyTrash: Bool

    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(CommandBus.self) private var bus

    @State private var newCollectionParent: String??
    @State private var renamingCollection: LibraryCollection?

    /// Respects the "confirm before emptying" preference.
    private func emptyTrash() {
        if settings.confirmBeforeDelete {
            confirmEmptyTrash = true
        } else {
            controller.emptyTrash()
        }
    }

    var body: some View {
        @Bindable var controller = controller

        List(selection: $controller.selection) {
            Section("Library") {
                ForEach(SmartSection.allCases, id: \.self) { section in
                    SmartRow(section: section, count: controller.items(for: .smart(section)).count)
                        .tag(SidebarSelection.smart(section))
                        .contextMenu {
                            if section == .trash {
                                Button("Empty Trash…", role: .destructive) { emptyTrash() }
                                    .disabled(controller.items(for: .smart(.trash)).isEmpty)
                            }
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard section != .trash else { return false }
                            controller.importFiles(urls, into: nil)
                            return true
                        }
                }
            }

            Section {
                ForEach(controller.collections) { collection in
                    CollectionRow(collection: collection, depth: 0)
                }
            } header: {
                HStack {
                    Text("Collections")
                    Spacer()
                    Button {
                        newCollectionParent = .some(nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("New collection")
                }
                .contextMenu {
                    Button("Sort Collections Alphabetically") {
                        controller.sortCollectionsAlphabetically()
                    }
                }
                // Dropping a collection on the header promotes it to the top level.
                .dropDestination(for: String.self) { _, _ in
                    guard let moving = controller.draggingCollectionID else { return false }
                    controller.moveCollection(moving, toParent: nil, at: 0)
                    controller.draggingCollectionID = nil
                    return true
                }
            }

            Section {
                ForEach(controller.connectedFolders) { folder in
                    FolderRow(folder: folder)
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button {
                        bus.connectFolder()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Connect a folder")
                }
            }

            if !controller.allTags.isEmpty {
                Section("Tags") {
                    ForEach(controller.allTags.prefix(40), id: \.self) { tag in
                        Label(tag, systemImage: "tag")
                            .tag(SidebarSelection.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
        .onChange(of: bus.newCollectionTicks) { _, _ in newCollectionParent = .some(nil) }
        .sheet(item: newCollectionBinding) { request in
            NewCollectionSheet(parent: request.parent)
        }
        .sheet(item: $renamingCollection) { collection in
            RenameCollectionSheet(collection: collection)
        }
        .environment(\.renameCollection) { renamingCollection = $0 }
        .environment(\.addSubcollection) { newCollectionParent = .some($0) }
    }

    private struct NewCollectionRequest: Identifiable {
        let parent: String?
        var id: String { parent ?? "__root__" }
    }

    private var newCollectionBinding: Binding<NewCollectionRequest?> {
        Binding(
            get: { newCollectionParent.map { NewCollectionRequest(parent: $0) } },
            set: { newValue in newCollectionParent = newValue.map { .some($0.parent) } ?? nil }
        )
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.tertiary)
            Text(controller.libraryName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .contextMenu {
            Button("Reveal Library in Finder") {
                if let root = controller.snapshot?.layout.root {
                    NSWorkspace.shared.activateFileViewerSelecting([root])
                }
            }
            Button("Close Library") { controller.closeLibrary() }
        }
    }
}

// MARK: - Rows

private struct SmartRow: View {
    let section: SmartSection
    let count: Int

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    private var title: LocalizedStringKey {
        switch section {
        case .all: "All Items"
        case .inbox: "Inbox"
        case .likes: "Likes"
        case .trash: "Trash"
        }
    }

    private var symbol: String {
        switch section {
        case .all: "square.grid.2x2"
        case .inbox: "tray"
        case .likes: "heart"
        case .trash: "trash"
        }
    }
}

private struct CollectionRow: View {
    let collection: LibraryCollection
    let depth: Int

    @Environment(LibraryController.self) private var controller
    @Environment(\.renameCollection) private var renameCollection
    @Environment(\.addSubcollection) private var addSubcollection
    @State private var isTargeted = false

    private var isExpanded: Bool { controller.expandedCollections.contains(collection.id) }

    var body: some View {
        Group {
            row
            if isExpanded {
                ForEach(collection.children) { child in
                    CollectionRow(collection: child, depth: depth + 1)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            if collection.children.isEmpty {
                Color.clear.frame(width: 12)
            } else {
                Button {
                    toggleExpansion()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            }
            Label(collection.name, systemImage: isExpanded ? "folder.fill" : "folder")
            Spacer()
            Text(count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .tag(SidebarSelection.collection(collection.id))
        .background(isTargeted ? Color.accentColor.opacity(0.18) : .clear)
        .contextMenu {
            Button("New Subcollection…") { addSubcollection(collection.id) }
            Button("Rename…") { renameCollection(collection) }
            Divider()
            Button("Sort Collections Alphabetically") { controller.sortCollectionsAlphabetically() }
            Divider()
            Button("Delete", role: .destructive) { controller.deleteCollection(collection.id) }
        }
        .onDrag {
            controller.draggingCollectionID = collection.id
            let provider = NSItemProvider()
            let payload = Data(collection.id.utf8)
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.aigleCollection.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(payload, nil)
                return nil
            }
            return provider
        }
        .onDrop(
            of: DropImporter.acceptedTypes + [.aigleItems, .aigleCollection],
            isTargeted: $isTargeted
        ) { providers in
            handleDrop(providers)
        }
    }

    private var count: Int {
        controller.items(for: .collection(collection.id)).count
    }

    private func toggleExpansion() {
        if isExpanded {
            controller.expandedCollections.remove(collection.id)
        } else {
            controller.expandedCollections.insert(collection.id)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Dropping a collection onto another nests it inside.
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.aigleCollection.identifier) }) {
            guard let moving = controller.draggingCollectionID, moving != collection.id else { return false }
            controller.moveCollection(moving, toParent: collection.id, at: nil)
            controller.expandedCollections.insert(collection.id)
            controller.draggingCollectionID = nil
            return true
        }
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.aigleItems.identifier) }) {
            let moving = controller.draggingItemIDs
            guard !moving.isEmpty else { return false }
            controller.addToCollection(collection.id, ids: moving)
            return true
        }
        return DropImporter.handleDrop(providers: providers, into: collection.id, controller: controller)
    }
}

private struct FolderRow: View {
    let folder: ConnectedFolder

    @Environment(LibraryController.self) private var controller

    var body: some View {
        Label {
            HStack {
                Text(folder.name)
                Spacer()
                Text(controller.connectedItems[folder.id]?.count ?? 0, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: "folder.badge.gearshape")
        }
        .tag(SidebarSelection.connectedFolder(folder.id))
        .help(folder.path)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder.url])
            }
            Button("Rescan") { Task { await controller.refreshConnectedFolders() } }
            Divider()
            Button("Disconnect", role: .destructive) { controller.disconnectFolder(folder) }
        }
    }
}

// MARK: - Sheets

private struct NewCollectionSheet: View {
    let parent: String?

    @Environment(LibraryController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(parent == nil ? "New Collection" : "New Subcollection")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await controller.createCollection(named: trimmed, parent: parent) }
        dismiss()
    }
}

private struct RenameCollectionSheet: View {
    let collection: LibraryCollection

    @Environment(LibraryController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Collection")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { name = collection.name }
    }

    private func commit() {
        controller.renameCollection(collection.id, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}

// MARK: - Environment plumbing

extension EnvironmentValues {
    @Entry var renameCollection: (LibraryCollection) -> Void = { _ in }
    @Entry var addSubcollection: (String) -> Void = { _ in }
}
