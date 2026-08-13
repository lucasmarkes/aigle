import AppKit
import Observation
import SwiftUI
import os.log

/// The main-actor face of the library: what's open, what's selected, what the
/// grid should show. All mutations are forwarded to the ``LibraryStore`` actor
/// and come back as a fresh snapshot.
@MainActor
@Observable
public final class LibraryController {
    private let log = Logger(subsystem: "cool.aigle.Aigle", category: "controller")

    // MARK: Library state

    public private(set) var snapshot: LibrarySnapshot?
    public private(set) var store: LibraryStore?
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public var libraryName: String { snapshot?.layout.name ?? "" }
    public var isOpen: Bool { store != nil }

    @ObservationIgnored private var access: SecurityScopedAccess?
    @ObservationIgnored private var folderAccess: [String: SecurityScopedAccess] = [:]
    @ObservationIgnored private var libraryWatcher: FSEventsWatcher?
    @ObservationIgnored private var folderWatcher: FSEventsWatcher?
    @ObservationIgnored private let folderIndex = ConnectedFolderIndex()

    // MARK: Browsing state

    public var selection: SidebarSelection = .smart(.all) {
        didSet {
            guard selection != oldValue else { return }
            selectedItemIDs = []
            focusedItemID = nil
        }
    }
    public var selectedItemIDs: Set<String> = []
    public var focusedItemID: String?
    /// Drives Space-to-Quick-Look on hover, Atlas style.
    public var hoveredItemID: String?
    public var searchText: String = ""
    public var connectedFolders: [ConnectedFolder] = []
    public private(set) var connectedItems: [String: [Item]] = [:]
    public var expandedCollections: Set<String> = []
    /// Non-nil while an inline rename field is open in the grid or inspector.
    public var renamingItemID: String?

    /// Grid cell target width in points; driven by the zoom slider / pinch / ⌘-scroll.
    public var zoom: Double = 220

    // MARK: Detail overlay

    public var detailItemID: String?
    public var isDetailPresented: Bool { detailItemID != nil }
    public var draggingItemIDs: Set<String> = []
    /// Set while a sidebar collection is being dragged.
    public var draggingCollectionID: String?

    public func openDetail(_ id: String) {
        detailItemID = id
        focusedItemID = id
        if !selectedItemIDs.contains(id) { selectedItemIDs = [id] }
    }

    public func closeDetail() {
        detailItemID = nil
    }

    /// Arrow-key flipping inside the detail overlay.
    public func stepDetail(by offset: Int) {
        let ordered = visibleItems
        guard let current = detailItemID,
              let index = ordered.firstIndex(where: { $0.id == current })
        else { return }
        let next = index + offset
        guard ordered.indices.contains(next) else { return }
        let id = ordered[next].id
        detailItemID = id
        focusedItemID = id
        selectedItemIDs = [id]
    }

    public var detailItem: Item? { detailItemID.flatMap(item) }

    // MARK: Sorting

    @ObservationIgnored private var sortOrders: [String: SortOrder] = [:]

    public init() {
        connectedFolders = ConnectedFolderStore.load()
        sortOrders = Self.loadSortOrders()
        zoom = AppSettings.shared.defaultZoom
    }

    // MARK: - Opening & creating

    public func restoreLastLibrary() async {
        let path = AppSettings.shared.lastLibraryPath
        guard !path.isEmpty else { return }
        let key = BookmarkStore.key(forLibraryAt: URL(fileURLWithPath: path))
        guard let access = BookmarkStore.resolve(key: key) else { return }
        await adopt(access: access)
    }

    public func openLibrary(at url: URL) async {
        let key = BookmarkStore.key(forLibraryAt: url)
        // The URL comes from a file picker, so it carries a security scope that
        // has to be held while the bookmark is taken.
        SystemChecks.withAccess(to: url) { scoped in
            BookmarkStore.store(scoped, key: key)
        }
        guard let access = BookmarkStore.resolve(key: key) else {
            loadError = String(localized: "Aigle couldn’t get permission to open that folder.")
            return
        }
        await adopt(access: access)
    }

    /// Creates `<name>.library` inside a folder the user picked. The whole
    /// creation runs inside the parent's security scope: without it the sandbox
    /// refuses the write with "You don't have permission to save the file…",
    /// even though the user chose that folder a moment earlier.
    public func createLibrary(named name: String, in parent: URL) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = trimmed.isEmpty ? "Aigle" : trimmed
        let url = parent.appending(path: "\(leaf).library", directoryHint: .isDirectory)
        let key = BookmarkStore.key(forLibraryAt: url)

        let outcome: Result<Void, any Error> = SystemChecks.withAccess(to: parent) { _ in
            do {
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw LibraryError.alreadyExists(leaf)
                }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try LibraryLayout(root: url).createSkeleton()
                // Bookmarking has to happen here too — the new folder inherits its
                // reachability from the parent scope we're still holding.
                BookmarkStore.store(url, key: key)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        if case .failure(let error) = outcome {
            loadError = error.localizedDescription
            return
        }

        guard let access = BookmarkStore.resolve(key: key) else {
            loadError = String(localized: "Aigle created the library but couldn’t keep permission to it.")
            return
        }
        await adopt(access: access)
    }

    public enum LibraryError: LocalizedError {
        case alreadyExists(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyExists(let name):
                String(localized: "“\(name).library” already exists here. Pick another name, or open it instead.")
            }
        }
    }

    private func adopt(access newAccess: SecurityScopedAccess) async {
        isLoading = true
        loadError = nil
        self.access?.stop()
        self.access = newAccess

        let layout = LibraryLayout(root: newAccess.url)
        let store = LibraryStore(layout: layout)
        do {
            let snapshot = try await store.open()
            self.store = store
            self.snapshot = snapshot
            AppSettings.shared.lastLibraryPath = layout.root.path
            await ThumbnailPipeline.shared.setLibraryLayout(layout)
            startWatchingLibrary(layout)
            await refreshConnectedFolders()
            // Reconcile against the disk in the background — the UI is already live.
            Task { [weak self] in
                let reconciled = await store.reconcile()
                await MainActor.run { self?.snapshot = reconciled }
            }
        } catch {
            loadError = error.localizedDescription
            newAccess.stop()
            self.access = nil
        }
        isLoading = false
    }

    public func closeLibrary() {
        libraryWatcher?.stop()
        libraryWatcher = nil
        Task { [store] in await store?.save() }
        store = nil
        snapshot = nil
        access?.stop()
        access = nil
        AppSettings.shared.lastLibraryPath = ""
    }

    private func startWatchingLibrary(_ layout: LibraryLayout) {
        libraryWatcher?.stop()
        libraryWatcher = FSEventsWatcher(paths: [layout.imagesURL]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleLibraryReconcile() }
        }
    }

    @ObservationIgnored private var reconcileTask: Task<Void, Never>?

    private func scheduleLibraryReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            let fresh = await store.reconcile()
            guard !Task.isCancelled else { return }
            self.snapshot = fresh
        }
    }

    // MARK: - Connected folders

    public func clearLoadError() { loadError = nil }

    public func connectFolder(at url: URL) async {
        let folder = ConnectedFolder(url: url)
        SystemChecks.withAccess(to: url) { scoped in
            BookmarkStore.store(scoped, key: folder.bookmarkKey)
        }
        guard !connectedFolders.contains(where: { $0.id == folder.id }) else { return }
        connectedFolders.append(folder)
        ConnectedFolderStore.save(connectedFolders)
        await refreshConnectedFolders()
    }

    public func disconnectFolder(_ folder: ConnectedFolder) {
        connectedFolders.removeAll { $0.id == folder.id }
        ConnectedFolderStore.save(connectedFolders)
        connectedItems.removeValue(forKey: folder.id)
        folderAccess.removeValue(forKey: folder.id)?.stop()
        BookmarkStore.remove(key: folder.bookmarkKey)
        Task { [folderIndex] in await folderIndex.forget(folder) }
        if selection == .connectedFolder(folder.id) { selection = .smart(.all) }
        restartFolderWatcher()
    }

    public func refreshConnectedFolders() async {
        for folder in connectedFolders {
            if folderAccess[folder.id] == nil, let access = BookmarkStore.resolve(key: folder.bookmarkKey) {
                folderAccess[folder.id] = access
            }
            // Cached contents first so the sidebar never shows an empty folder.
            let cached = await folderIndex.cached(folder)
            if !cached.isEmpty { connectedItems[folder.id] = cached }
        }
        restartFolderWatcher()

        for folder in connectedFolders {
            let scanned = await folderIndex.scan(folder)
            connectedItems[folder.id] = scanned
            // Warm previews in the background so opening the folder is instant.
            let head = Array(scanned.prefix(300))
            Task.detached(priority: .background) {
                await ThumbnailPipeline.shared.prefetch(head, size: .medium)
            }
        }
    }

    private func restartFolderWatcher() {
        folderWatcher?.stop()
        let urls = connectedFolders.map(\.url)
        guard !urls.isEmpty else { folderWatcher = nil; return }
        folderWatcher = FSEventsWatcher(paths: urls) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleFolderRescan() }
        }
    }

    @ObservationIgnored private var folderRescanTask: Task<Void, Never>?

    private func scheduleFolderRescan() {
        folderRescanTask?.cancel()
        folderRescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            for folder in self.connectedFolders {
                let scanned = await self.folderIndex.scan(folder)
                guard !Task.isCancelled else { return }
                self.connectedItems[folder.id] = scanned
            }
        }
    }

    // MARK: - Derived data

    public var collections: [LibraryCollection] { snapshot?.collections ?? [] }
    public var allTags: [String] { snapshot?.tags ?? [] }

    public var liveItems: [Item] { (snapshot?.items ?? []).filter { !$0.isDeleted } }

    public func items(for selection: SidebarSelection) -> [Item] {
        switch selection {
        case .smart(.all):
            return liveItems
        case .smart(.inbox):
            return liveItems.filter { $0.folders.isEmpty }
        case .smart(.likes):
            return liveItems.filter(\.liked)
        case .smart(.trash):
            return (snapshot?.items ?? []).filter(\.isDeleted)
        case .collection(let id):
            let descendants = Set(collections.find(id)?.flattened.map(\.id) ?? [id])
            return liveItems.filter { !$0.folders.filter(descendants.contains).isEmpty }
        case .connectedFolder(let id):
            return connectedItems[id] ?? []
        case .tag(let tag):
            return liveItems.filter { $0.tags.contains(tag) }
        }
    }

    /// What the grid renders: filtered by the sidebar selection and the search
    /// field, then sorted by the per-selection sort order.
    public var visibleItems: [Item] {
        var items = items(for: selection)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter { SearchMatcher.matches($0, query: query) }
        }
        return sorted(items, by: currentSortOrder)
    }

    public func sorted(_ items: [Item], by order: SortOrder) -> [Item] {
        switch order.field {
        case .custom:
            let explicit = customOrder
            guard !explicit.isEmpty else { return items }
            let rank = Dictionary(uniqueKeysWithValues: explicit.enumerated().map { ($0.element, $0.offset) })
            return items.sorted { a, b in
                let ra = rank[a.id] ?? Int.max
                let rb = rank[b.id] ?? Int.max
                if ra != rb { return ra < rb }
                return a.btime > b.btime
            }
        case .dateAdded:
            return items.sorted { order.ascending ? $0.btime < $1.btime : $0.btime > $1.btime }
        case .dateModified:
            return items.sorted { order.ascending ? $0.mtime < $1.mtime : $0.mtime > $1.mtime }
        case .name:
            return items.sorted {
                let result = $0.name.localizedStandardCompare($1.name)
                return order.ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case .size:
            return items.sorted { order.ascending ? $0.size < $1.size : $0.size > $1.size }
        }
    }

    // MARK: - Sort order persistence

    private static let sortDefaultsKey = "aigle.sortOrders"

    private static func loadSortOrders() -> [String: SortOrder] {
        guard let data = UserDefaults.standard.data(forKey: sortDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: SortOrder].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistSortOrders() {
        guard let data = try? JSONEncoder().encode(sortOrders) else { return }
        UserDefaults.standard.set(data, forKey: Self.sortDefaultsKey)
    }

    public var sortKey: String {
        switch selection {
        case .smart(let section): "smart:\(section.rawValue)"
        case .collection(let id): "collection:\(id)"
        case .connectedFolder(let id): "folder:\(id)"
        case .tag(let tag): "tag:\(tag)"
        }
    }

    public var currentSortOrder: SortOrder {
        get { sortOrders[sortKey] ?? .newestFirst }
        set {
            sortOrders[sortKey] = newValue
            persistSortOrders()
        }
    }

    public var customOrder: [String] {
        get {
            if let id = selection.collectionID {
                return collections.find(id)?.customOrder ?? []
            }
            return cachedGlobalOrder[sortKey] ?? []
        }
    }

    @ObservationIgnored private var cachedGlobalOrder: [String: [String]] = [:]

    public func loadGlobalOrderIfNeeded() async {
        guard selection.collectionID == nil, let store else { return }
        let key = sortKey
        guard cachedGlobalOrder[key] == nil else { return }
        cachedGlobalOrder[key] = await store.globalCustomOrder(key: key)
    }

    public func setCustomOrder(_ order: [String]) async {
        guard let store else { return }
        if let id = selection.collectionID {
            snapshot = await store.setCustomOrder(order, collectionID: id)
        } else {
            cachedGlobalOrder[sortKey] = order
            snapshot = await store.setGlobalCustomOrder(order, key: sortKey)
        }
    }

    // MARK: - Item helpers

    public func item(_ id: String) -> Item? {
        if let hit = snapshot?.items.first(where: { $0.id == id }) { return hit }
        for items in connectedItems.values {
            if let hit = items.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    public func fileURL(for item: Item) -> URL? {
        ThumbnailPipeline.resolveFileURL(item: item, layout: snapshot?.layout)
    }

    public var selectedItems: [Item] { selectedItemIDs.compactMap(item) }

    public var inspectorItem: Item? {
        if let focusedItemID, let hit = item(focusedItemID) { return hit }
        return selectedItems.first
    }

    // MARK: - Mutations

    private func apply(_ operation: @escaping @Sendable (LibraryStore) async -> LibrarySnapshot) {
        guard let store else { return }
        Task { [weak self] in
            let fresh = await operation(store)
            self?.snapshot = fresh
        }
    }

    public func toggleLike(ids: Set<String>) {
        let libraryIDs = ids.filter { item($0)?.connectedFolderID == nil }
        guard !libraryIDs.isEmpty else { return }
        let shouldLike = !libraryIDs.allSatisfy { item($0)?.liked == true }
        apply { await $0.setLiked(shouldLike, ids: libraryIDs) }
    }

    public func rename(_ id: String, to name: String) {
        apply { await $0.rename(id, to: name) }
    }

    public func setAnnotation(_ text: String, id: String) {
        apply { await $0.setAnnotation(text, id: id) }
    }

    public func addTags(_ tags: [String], ids: Set<String>) {
        apply { await $0.addTags(tags, ids: ids) }
    }

    public func setTags(_ tags: [String], ids: Set<String>) {
        apply { await $0.setTags(tags, ids: ids) }
    }

    public func removeTag(_ tag: String, ids: Set<String>) {
        apply { await $0.removeTag(tag, ids: ids) }
    }

    public func moveToTrash(ids: Set<String>) {
        let libraryIDs = ids.filter { item($0)?.connectedFolderID == nil }
        guard !libraryIDs.isEmpty else { return }
        apply { await $0.moveToTrash(ids: libraryIDs) }
        selectedItemIDs.subtract(libraryIDs)
    }

    public func restore(ids: Set<String>) {
        apply { await $0.restore(ids: ids) }
    }

    public func deletePermanently(ids: Set<String>) {
        apply { await $0.deletePermanently(ids: ids) }
        selectedItemIDs.subtract(ids)
    }

    public func emptyTrash() {
        apply { await $0.emptyTrash() }
    }

    public func addToCollection(_ collectionID: String, ids: Set<String>) {
        let libraryIDs = ids.filter { item($0)?.connectedFolderID == nil }
        guard !libraryIDs.isEmpty else { return }
        apply { await $0.addToCollection(collectionID, ids: libraryIDs) }
    }

    public func removeFromCollection(_ collectionID: String, ids: Set<String>) {
        apply { await $0.removeFromCollection(collectionID, ids: ids) }
    }

    @discardableResult
    public func createCollection(named name: String, parent: String?) async -> String? {
        guard let store else { return nil }
        let (fresh, id) = await store.createCollection(named: name, parent: parent)
        snapshot = fresh
        if let parent { expandedCollections.insert(parent) }
        return id
    }

    public func renameCollection(_ id: String, to name: String) {
        apply { await $0.renameCollection(id, to: name) }
    }

    public func deleteCollection(_ id: String) {
        if selection == .collection(id) { selection = .smart(.all) }
        apply { await $0.deleteCollection(id) }
    }

    public func moveCollection(_ id: String, toParent parent: String?, at index: Int?) {
        apply { await $0.moveCollection(id, toParent: parent, at: index) }
    }

    public func sortCollectionsAlphabetically() {
        apply { await $0.sortCollectionsAlphabetically() }
    }

    // MARK: - Import

    public private(set) var isImporting = false
    public private(set) var importProgress: String?
    /// Transient feedback for the grid. A drop that quietly imports nothing is
    /// indistinguishable from a broken app, so every import says what happened.
    public private(set) var importStatus: String?

    @ObservationIgnored private var statusClearTask: Task<Void, Never>?

    public func showStatus(_ message: String) {
        importStatus = message
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.importStatus = nil
        }
    }

    /// Returns the running import so callers can await it — the drop importer
    /// stages promised files into a temp folder and must not delete them until
    /// the copy into the library has finished.
    @discardableResult
    public func importFiles(_ urls: [URL], into collectionID: String? = nil) -> Task<Void, Never> {
        guard let store else { return Task {} }
        let target = collectionID ?? selection.collectionID
        let allowVirtual = AppSettings.shared.virtualCopiesEnabled
        isImporting = true
        importProgress = String(localized: "Importing…")
        let task = Task { [weak self] in
            let result = await store.importFiles(urls, into: target, allowVirtualCopies: allowVirtual)
            guard let self else { return }
            self.snapshot = result.snapshot
            self.isImporting = false
            self.importProgress = nil
            if result.imported.isEmpty {
                self.showStatus(String(localized: "Nothing importable in that drop."))
            } else {
                self.selectedItemIDs = Set(result.imported.map(\.id))
                self.showStatus(String(localized: "Imported \(String(result.imported.count)) item(s)."))
            }
        }
        return task
    }

    public func importImageData(_ data: Data, name: String, ext: String, into collectionID: String? = nil) {
        guard let store else { return }
        let target = collectionID ?? selection.collectionID
        Task { [weak self] in
            let result = await store.importData(data, name: name, ext: ext, into: target)
            self?.snapshot = result.snapshot
        }
    }

    public func importLink(_ url: URL, into collectionID: String? = nil) {
        guard let store else { return }
        let target = collectionID ?? selection.collectionID
        Task { [weak self] in
            let metadata = await LinkFetcher.fetch(url)
            let result = await store.importLink(
                url,
                title: metadata.title,
                into: target,
                previewPNG: metadata.previewPNG
            )
            self?.snapshot = result.snapshot
        }
    }

    /// Downloads a remote image/video (browser drag, extension save) and imports it.
    public func importRemoteMedia(_ url: URL, into collectionID: String? = nil) {
        guard let store else { return }
        let target = collectionID ?? selection.collectionID
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), !data.isEmpty else {
                self?.importLink(url, into: collectionID)
                return
            }
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
            let name = url.deletingPathExtension().lastPathComponent
            let result = await store.importData(
                data,
                name: name.isEmpty ? "Saved image" : name,
                ext: ext,
                into: target
            )
            self?.snapshot = result.snapshot
        }
    }

    /// Menu-bar drops and browser-extension saves land in the Inbox.
    public func importToInbox(_ urls: [URL]) {
        importFiles(urls, into: nil)
    }

    // MARK: - Finder integration

    public func revealInFinder(ids: Set<String>) {
        let urls = ids.compactMap { item($0) }.compactMap(fileURL(for:))
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    public func openExternally(ids: Set<String>) {
        for id in ids {
            guard let item = item(id) else { continue }
            if item.kind == .link, let url = URL(string: item.url) {
                NSWorkspace.shared.open(url)
            } else if let url = fileURL(for: item) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Copies the selection out to a user-chosen folder (drag-out to Finder also
    /// uses the same file URLs directly).
    public func exportItems(_ ids: Set<String>, to destination: URL) {
        for id in ids {
            guard let item = item(id), let source = fileURL(for: item) else { continue }
            let target = destination.appending(path: item.fileName)
            try? CoordinatedIO.copy(from: source, to: target)
        }
    }
}
