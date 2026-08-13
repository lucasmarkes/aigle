import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(CommandBus.self) private var bus

    @Namespace private var detailNamespace
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var isImportingFiles = false
    @State private var isConnectingFolder = false
    @State private var confirmEmptyTrash = false

    var body: some View {
        @Bindable var controller = controller
        @Bindable var bus = bus

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(confirmEmptyTrash: $confirmEmptyTrash)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            ZStack {
                GridView(namespace: detailNamespace)
                    .toolbar { toolbarContent }
                    .navigationTitle(titleText)
                    .navigationSubtitle(subtitleText)

                if controller.isDetailPresented {
                    DetailOverlay(namespace: detailNamespace)
                        .zIndex(2)
                }

                if let status = controller.importStatus {
                    ImportToast(message: status)
                        .zIndex(3)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: controller.importStatus)
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
            }
        }
        .searchable(text: $controller.searchText, placement: .toolbar, prompt: Text("Filter this view"))
        .sheet(isPresented: $bus.isSearchPresented) {
            SearchPalette()
        }
        .sheet(isPresented: $bus.isTagEditorPresented) {
            TagEditorSheet()
        }
        .sheet(item: renameBinding) { target in
            RenameSheet(item: target)
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.image, .movie, .pdf, .svg, .folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            controller.importFiles(urls)
        }
        .fileImporter(
            isPresented: $isConnectingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await controller.connectFolder(at: url) }
        }
        .confirmationDialog(
            "Empty the Trash?",
            isPresented: $confirmEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) { controller.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items in the Trash will be deleted from disk. This can’t be undone.")
        }
        .onChange(of: bus.importPickerTicks) { _, _ in isImportingFiles = true }
        .onChange(of: bus.connectFolderTicks) { _, _ in isConnectingFolder = true }
        .onPasteCommand(of: DropImporter.acceptedTypes) { providers in
            _ = DropImporter.handleDrop(
                providers: providers,
                into: controller.selection.collectionID,
                controller: controller
            )
        }
    }

    private var renameBinding: Binding<Item?> {
        Binding(
            get: { controller.renamingItemID.flatMap(controller.item) },
            set: { controller.renamingItemID = $0?.id }
        )
    }

    // MARK: - Titles

    private var titleText: String {
        switch controller.selection {
        case .smart(let section):
            switch section {
            case .all: String(localized: "All Items")
            case .inbox: String(localized: "Inbox")
            case .likes: String(localized: "Likes")
            case .trash: String(localized: "Trash")
            }
        case .collection(let id):
            controller.collections.find(id)?.name ?? String(localized: "Collection")
        case .connectedFolder(let id):
            controller.connectedFolders.first { $0.id == id }?.name ?? String(localized: "Folder")
        case .tag(let tag):
            "#\(tag)"
        }
    }

    private var subtitleText: String {
        let count = controller.visibleItems.count
        return count == 1
            ? String(localized: "1 item")
            : String(localized: "\(count) items")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                bus.isSearchPresented = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search everything (⌘K)")
        }

        ToolbarItem {
            Menu {
                SortMenu()
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }

        ToolbarItem {
            Button {
                isImportingFiles = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import files…")
        }

        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
    }
}

/// Sort menu — date added / modified, name, size, and custom drag order.
struct SortMenu: View {
    @Environment(LibraryController.self) private var controller

    var body: some View {
        let current = controller.currentSortOrder
        Picker("Sort by", selection: fieldBinding) {
            Text("Date Added").tag(SortField.dateAdded)
            Text("Date Modified").tag(SortField.dateModified)
            Text("Name").tag(SortField.name)
            Text("File Size").tag(SortField.size)
            Divider()
            Text("Custom Order").tag(SortField.custom)
        }
        .pickerStyle(.inline)

        if current.field != .custom {
            Divider()
            Picker("Direction", selection: directionBinding) {
                Text(current.field == .name ? "A → Z" : "Newest First").tag(false)
                Text(current.field == .name ? "Z → A" : "Oldest First").tag(true)
            }
            .pickerStyle(.inline)
        }
    }

    private var fieldBinding: Binding<SortField> {
        Binding(
            get: { controller.currentSortOrder.field },
            set: { controller.currentSortOrder = SortOrder(field: $0, ascending: $0 == .name) }
        )
    }

    private var directionBinding: Binding<Bool> {
        Binding(
            get: { controller.currentSortOrder.ascending },
            set: { controller.currentSortOrder = SortOrder(field: controller.currentSortOrder.field, ascending: $0) }
        )
    }
}

/// Inline rename, shown as a small sheet so it works from the grid and inspector.
struct RenameSheet: View {
    let item: Item

    @Environment(LibraryController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = item.name }
    }

    private func commit() {
        controller.rename(item.id, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}

/// Brief confirmation that a drop or import landed — or didn't. A drop that
/// silently does nothing reads as a broken app, so imports always say something.
private struct ImportToast: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
