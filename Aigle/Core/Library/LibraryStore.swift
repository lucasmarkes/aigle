import CryptoKit
import Foundation
import os.log

/// An immutable, `Sendable` view of the library that the UI renders from.
public struct LibrarySnapshot: Sendable {
    public var layout: LibraryLayout
    public var items: [Item]
    public var collections: [LibraryCollection]
    public var tags: [String]
    public var revision: Int

    public init(
        layout: LibraryLayout,
        items: [Item] = [],
        collections: [LibraryCollection] = [],
        tags: [String] = [],
        revision: Int = 0
    ) {
        self.layout = layout
        self.items = items
        self.collections = collections
        self.tags = tags
        self.revision = revision
    }

    public static func empty() -> LibrarySnapshot {
        LibrarySnapshot(layout: LibraryLayout(root: URL(fileURLWithPath: "/")))
    }
}

public struct ImportResult: Sendable {
    public var snapshot: LibrarySnapshot
    public var imported: [Item]
    public var skipped: Int
    public init(snapshot: LibrarySnapshot, imported: [Item], skipped: Int = 0) {
        self.snapshot = snapshot
        self.imported = imported
        self.skipped = skipped
    }
}

/// The single owner of the on-disk library and its in-memory index.
///
/// Every mutation writes through to disk (coordinated, so iCloud/Dropbox stay
/// consistent) and then publishes a fresh ``LibrarySnapshot``.
public actor LibraryStore {
    private let log = Logger(subsystem: "cool.aigle.Aigle", category: "store")

    public let layout: LibraryLayout
    private var metadata = LibraryMetadata()
    private var tagsFile = TagsFile()
    private var itemsByID: [String: Item] = [:]
    /// blob content hash → owning item id, for virtual-copy detection.
    private var blobIndex: [String: String] = [:]
    private var revision = 0
    private var indexSaveScheduled = false

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    // MARK: - Opening

    /// Creates a brand-new library folder at `root`.
    public static func create(at root: URL) throws -> LibraryStore {
        let layout = LibraryLayout(root: root)
        try layout.createSkeleton()
        return LibraryStore(layout: layout)
    }

    /// Loads library metadata and the item index. Uses the persisted index when
    /// present so launch → pixels is instant even for very large libraries.
    public func open() async throws -> LibrarySnapshot {
        guard LibraryLayout.isLibrary(layout.root) else {
            // A freshly created library may not have been populated yet.
            if FileManager.default.fileExists(atPath: layout.root.path) {
                try layout.createSkeleton()
            } else {
                throw EagleCodecError.notALibrary(layout.root)
            }
            return try await open()
        }

        if let data = try? CoordinatedIO.read(layout.metadataURL) {
            metadata = (try? EagleCodec.decodeLibraryMetadata(data)) ?? LibraryMetadata()
        }
        if let data = try? CoordinatedIO.read(layout.tagsURL) {
            tagsFile = (try? JSONDecoder().decode(TagsFile.self, from: data)) ?? TagsFile()
        }

        if let cached = loadPersistedIndex(), !cached.isEmpty {
            adopt(items: cached)
        } else {
            adopt(items: await scanItemsFromDisk())
            persistIndexNow()
        }
        revision += 1
        return snapshot()
    }

    /// Full directory scan; reconciles the in-memory index against the disk.
    /// Cheap enough to run in the background after a fast index-backed open.
    public func reconcile() async -> LibrarySnapshot {
        let scanned = await scanItemsFromDisk()
        guard !scanned.isEmpty || !itemsByID.isEmpty else { return snapshot() }
        adopt(items: scanned)
        persistIndexNow()
        revision += 1
        return snapshot()
    }

    private func adopt(items: [Item]) {
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        blobIndex = [:]
        for item in items {
            if let blob = item.aigle.blobID, blobIndex[blob] == nil {
                blobIndex[blob] = item.blobOwnerID
            }
        }
    }

    private func scanItemsFromDisk() async -> [Item] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: layout.imagesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let infoDirs = entries.filter { $0.pathExtension == "info" }
        let layout = self.layout
        return await withTaskGroup(of: [Item].self) { group in
            let chunkSize = max(1, infoDirs.count / max(1, ProcessInfo.processInfo.activeProcessorCount))
            for chunk in stride(from: 0, to: infoDirs.count, by: chunkSize) {
                let slice = Array(infoDirs[chunk..<min(chunk + chunkSize, infoDirs.count)])
                group.addTask {
                    slice.compactMap { dir in
                        let id = dir.deletingPathExtension().lastPathComponent
                        let metadataURL = dir.appending(path: "metadata.json")
                        guard let data = try? Data(contentsOf: metadataURL),
                              var item = try? EagleCodec.decodeItem(data)
                        else { return nil }
                        if item.id != id { item.id = id }
                        _ = layout
                        return item
                    }
                }
            }
            var all: [Item] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
    }

    // MARK: - Persisted index

    /// A compact, fixed-schema mirror of the library used only to make launch
    /// instant. `metadata.json` on disk stays authoritative; this is a cache
    /// with short keys and no generic dictionary decoding on the hot path.
    private struct IndexRecord: Codable {
        var i: String       // id
        var n: String       // name
        var e: String       // ext
        var s: Int          // size
        var b: Int          // btime
        var m: Int          // mtime
        var o: Int          // modificationTime
        var w: Int          // width
        var h: Int          // height
        var t: [String]?    // tags
        var f: [String]?    // folders
        var d: Bool?        // isDeleted
        var u: String?      // url
        var a: String?      // annotation
        var r: Int?         // star
        var nt: Bool?       // noThumbnail
        var lk: Bool?       // liked
        var bl: String?     // blobID
        var vc: String?     // virtualCopyOf
        var k: String?      // kind
        /// Eagle keys we don't model, carried through so an edit never drops them.
        var x: [String: JSONValue]?

        init(_ item: Item) {
            i = item.id
            n = item.name
            e = item.ext
            s = item.size
            b = item.btime
            m = item.mtime
            o = item.modificationTime
            w = item.width
            h = item.height
            t = item.tags.isEmpty ? nil : item.tags
            f = item.folders.isEmpty ? nil : item.folders
            d = item.isDeleted ? true : nil
            u = item.url.isEmpty ? nil : item.url
            a = item.annotation.isEmpty ? nil : item.annotation
            r = item.star == 0 ? nil : item.star
            nt = item.noThumbnail ? true : nil
            lk = item.aigle.liked ? true : nil
            bl = item.aigle.blobID
            vc = item.aigle.virtualCopyOf
            k = item.aigle.kind?.rawValue
            x = item.passthrough.isEmpty ? nil : item.passthrough
        }

        var item: Item {
            Item(
                id: i, name: n, ext: e, size: s, btime: b, mtime: m,
                modificationTime: o, width: w, height: h,
                tags: t ?? [], folders: f ?? [], isDeleted: d ?? false,
                url: u ?? "", annotation: a ?? "", star: r ?? 0,
                noThumbnail: nt ?? false,
                aigle: AigleExtras(
                    liked: lk ?? false,
                    blobID: bl,
                    virtualCopyOf: vc,
                    kind: k.flatMap(ItemKind.init(rawValue:))
                ),
                passthrough: x ?? [:]
            )
        }
    }

    private struct PersistedIndex: Codable {
        var version: Int
        var records: [IndexRecord]
    }

    private static let indexVersion = 2

    private func loadPersistedIndex() -> [Item]? {
        guard let data = try? Data(contentsOf: layout.indexURL),
              let index = try? JSONDecoder().decode(PersistedIndex.self, from: data),
              index.version == Self.indexVersion
        else { return nil }
        return index.records.map(\.item)
    }

    private func persistIndexNow() {
        let index = PersistedIndex(version: Self.indexVersion, records: itemsByID.values.map(IndexRecord.init))
        do {
            try FileManager.default.createDirectory(at: layout.aigleURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(index)
            try data.write(to: layout.indexURL, options: .atomic)
        } catch {
            log.error("Index save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Debounced index write — mutations call this rather than paying for a full
    /// index rewrite on every keystroke.
    private func scheduleIndexSave() {
        guard !indexSaveScheduled else { return }
        indexSaveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.flushIndex()
        }
    }

    private func flushIndex() {
        indexSaveScheduled = false
        persistIndexNow()
    }

    public func save() {
        persistIndexNow()
        writeLibraryMetadata()
    }

    // MARK: - Snapshot

    public func snapshot() -> LibrarySnapshot {
        LibrarySnapshot(
            layout: layout,
            items: Array(itemsByID.values),
            collections: metadata.folders,
            tags: allTags(),
            revision: revision
        )
    }

    private func allTags() -> [String] {
        var set = Set(tagsFile.historyTags)
        for item in itemsByID.values where !item.isDeleted {
            set.formUnion(item.tags)
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func bump() -> LibrarySnapshot {
        revision += 1
        scheduleIndexSave()
        return snapshot()
    }

    // MARK: - Writing

    private func writeItem(_ item: Item) {
        do {
            try CoordinatedIO.write(try EagleCodec.encodeItemData(item), to: layout.itemMetadataURL(item.id))
        } catch {
            log.error("Failed to write item \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeLibraryMetadata() {
        metadata.modificationTime = Item.now
        do {
            try CoordinatedIO.write(try EagleCodec.encodeLibraryMetadata(metadata), to: layout.metadataURL)
        } catch {
            log.error("Failed to write library metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeTags() {
        do {
            try CoordinatedIO.write(try JSONEncoder().encode(tagsFile), to: layout.tagsURL)
        } catch {
            log.error("Failed to write tags: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Import

    /// Copies files into the library. When `allowVirtualCopies` is on, re-adding
    /// bytes already present creates a second item pointing at the same blob
    /// rather than duplicating the file (or nagging the user).
    public func importFiles(
        _ urls: [URL],
        into collectionID: String?,
        allowVirtualCopies: Bool,
        // 1024 keeps the grid crisp at high zoom without touching originals.
        // The detail view decodes the original itself; this is a preview only.
        thumbnailMaxPixel: Int = 1024
    ) async -> ImportResult {
        var imported: [Item] = []
        var skipped = 0

        for url in expand(urls) {
            guard let item = await importOne(
                url,
                into: collectionID,
                allowVirtualCopies: allowVirtualCopies,
                thumbnailMaxPixel: thumbnailMaxPixel
            ) else {
                skipped += 1
                continue
            }
            imported.append(item)
        }
        if !imported.isEmpty {
            writeLibraryMetadata()
        }
        return ImportResult(snapshot: bump(), imported: imported, skipped: skipped)
    }

    /// Recursively expands dropped folders into importable files.
    private func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let child as URL in walker
                where ItemKind.importableExtensions.contains(child.pathExtension.lowercased()) {
                    out.append(child)
                }
            } else if ItemKind.importableExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    private func importOne(
        _ url: URL,
        into collectionID: String?,
        allowVirtualCopies: Bool,
        thumbnailMaxPixel: Int
    ) async -> Item? {
        CoordinatedIO.ensureDownloaded(url)
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        let kind = ItemKind.infer(ext: ext)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let blob = ContentHash.hash(of: url)

        var item = Item(
            name: name,
            ext: ext,
            size: size,
            folders: collectionID.map { [$0] } ?? [],
            aigle: AigleExtras(blobID: blob, kind: kind)
        )

        if allowVirtualCopies, let blob, let owner = blobIndex[blob], let ownerItem = itemsByID[owner] {
            // Virtual copy: reuse the owner's bytes, only new metadata on disk.
            item.aigle.virtualCopyOf = owner
            item.name = ownerItem.name
            item.ext = ownerItem.ext
            item.width = ownerItem.width
            item.height = ownerItem.height
            item.size = ownerItem.size
            writeItem(item)
            itemsByID[item.id] = item
            appendToCustomOrder(item.id, collectionID: collectionID)
            return item
        }

        let destinationDir = layout.itemDirectory(item.id)
        do {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            try CoordinatedIO.copy(from: url, to: destinationDir.appending(path: item.fileName))
        } catch {
            log.error("Import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destinationDir)
            return nil
        }

        let fileURL = destinationDir.appending(path: item.fileName)
        if let dimensions = await MediaProbe.dimensions(of: fileURL, kind: kind) {
            item.width = dimensions.width
            item.height = dimensions.height
        }
        if let preview = await MediaProbe.render(url: fileURL, kind: kind, maxPixel: thumbnailMaxPixel),
           let data = MediaProbe.pngData(preview) {
            try? data.write(to: layout.thumbnailURL(for: item), options: .atomic)
        } else {
            item.noThumbnail = true
        }

        writeItem(item)
        itemsByID[item.id] = item
        if let blob { blobIndex[blob] = item.id }
        appendToCustomOrder(item.id, collectionID: collectionID)
        return item
    }

    /// Adds an item created from raw data (⌘⇧S save-frame, dropped image data, …).
    public func importData(
        _ data: Data,
        name: String,
        ext: String,
        into collectionID: String?,
        // 1024 keeps the grid crisp at high zoom without touching originals.
        // The detail view decodes the original itself; this is a preview only.
        thumbnailMaxPixel: Int = 1024
    ) async -> ImportResult {
        var item = Item(
            name: name,
            ext: ext,
            size: data.count,
            folders: collectionID.map { [$0] } ?? [],
            aigle: AigleExtras(kind: ItemKind.infer(ext: ext))
        )
        let dir = layout.itemDirectory(item.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try CoordinatedIO.write(data, to: dir.appending(path: item.fileName))
        } catch {
            return ImportResult(snapshot: snapshot(), imported: [], skipped: 1)
        }
        let fileURL = dir.appending(path: item.fileName)
        if let dimensions = await MediaProbe.dimensions(of: fileURL, kind: item.kind) {
            item.width = dimensions.width
            item.height = dimensions.height
        }
        if let preview = await MediaProbe.render(url: fileURL, kind: item.kind, maxPixel: thumbnailMaxPixel),
           let png = MediaProbe.pngData(preview) {
            try? png.write(to: layout.thumbnailURL(for: item), options: .atomic)
        }
        item.aigle.blobID = ContentHash.hash(of: data)
        writeItem(item)
        itemsByID[item.id] = item
        if let blob = item.aigle.blobID { blobIndex[blob] = item.id }
        appendToCustomOrder(item.id, collectionID: collectionID)
        return ImportResult(snapshot: bump(), imported: [item])
    }

    /// Creates a link item from a URL plus fetched page metadata.
    public func importLink(
        _ link: URL,
        title: String,
        into collectionID: String?,
        previewPNG: Data?
    ) async -> ImportResult {
        var item = Item(
            name: title.isEmpty ? (link.host() ?? link.absoluteString) : title,
            ext: "",
            folders: collectionID.map { [$0] } ?? [],
            url: link.absoluteString,
            aigle: AigleExtras(kind: .link)
        )
        item.width = 1200
        item.height = 630
        let dir = layout.itemDirectory(item.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let previewPNG {
            try? previewPNG.write(to: dir.appending(path: "\(item.name)_thumbnail.png"), options: .atomic)
        } else {
            item.noThumbnail = true
        }
        writeItem(item)
        itemsByID[item.id] = item
        appendToCustomOrder(item.id, collectionID: collectionID)
        return ImportResult(snapshot: bump(), imported: [item])
    }

    // MARK: - Item mutations

    public func setLiked(_ liked: Bool, ids: Set<String>) -> LibrarySnapshot {
        for id in ids {
            guard var item = itemsByID[id] else { continue }
            item.aigle.liked = liked
            item.star = liked ? max(item.star, 1) : 0
            item.modificationTime = Item.now
            itemsByID[id] = item
            writeItem(item)
        }
        return bump()
    }

    public func rename(_ id: String, to newName: String) -> LibrarySnapshot {
        guard var item = itemsByID[id], !newName.isEmpty, newName != item.name else { return snapshot() }
        let oldFile = layout.fileURL(for: item)
        let oldThumb = layout.thumbnailURL(for: item)
        let isOwner = item.aigle.virtualCopyOf == nil
        item.name = newName
        item.modificationTime = Item.now
        if isOwner {
            try? FileManager.default.moveItem(at: oldFile, to: layout.fileURL(for: item))
            try? FileManager.default.moveItem(at: oldThumb, to: layout.thumbnailURL(for: item))
            // Virtual copies share the blob, so they must follow the rename.
            for (otherID, other) in itemsByID where other.aigle.virtualCopyOf == id {
                var copy = other
                copy.name = newName
                itemsByID[otherID] = copy
                writeItem(copy)
            }
        }
        itemsByID[id] = item
        writeItem(item)
        return bump()
    }

    public func setAnnotation(_ text: String, id: String) -> LibrarySnapshot {
        guard var item = itemsByID[id] else { return snapshot() }
        item.annotation = text
        item.modificationTime = Item.now
        itemsByID[id] = item
        writeItem(item)
        return bump()
    }

    public func setTags(_ tags: [String], ids: Set<String>) -> LibrarySnapshot {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for id in ids {
            guard var item = itemsByID[id] else { continue }
            item.tags = cleaned
            item.modificationTime = Item.now
            itemsByID[id] = item
            writeItem(item)
        }
        registerTagHistory(cleaned)
        return bump()
    }

    public func addTags(_ tags: [String], ids: Set<String>) -> LibrarySnapshot {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for id in ids {
            guard var item = itemsByID[id] else { continue }
            var set = item.tags
            for tag in cleaned where !set.contains(tag) { set.append(tag) }
            item.tags = set
            item.modificationTime = Item.now
            itemsByID[id] = item
            writeItem(item)
        }
        registerTagHistory(cleaned)
        return bump()
    }

    public func removeTag(_ tag: String, ids: Set<String>) -> LibrarySnapshot {
        for id in ids {
            guard var item = itemsByID[id] else { continue }
            item.tags.removeAll { $0 == tag }
            item.modificationTime = Item.now
            itemsByID[id] = item
            writeItem(item)
        }
        return bump()
    }

    private func registerTagHistory(_ tags: [String]) {
        var history = tagsFile.historyTags
        for tag in tags where !history.contains(tag) { history.append(tag) }
        tagsFile.historyTags = history
        tagsFile.recentTags = Array((tags + tagsFile.recentTags).prefix(24))
        writeTags()
    }

    // MARK: - Collections membership

    public func setCollections(_ collectionIDs: [String], ids: Set<String>) -> LibrarySnapshot {
        for id in ids {
            guard var item = itemsByID[id] else { continue }
            item.folders = collectionIDs
            item.modificationTime = Item.now
            itemsByID[id] = item
            writeItem(item)
        }
        return bump()
    }

    public func addToCollection(_ collectionID: String, ids: Set<String>) -> LibrarySnapshot {
        for id in ids {
            guard var item = itemsByID[id] else { continue }
            if !item.folders.contains(collectionID) { item.folders.append(collectionID) }
            item.modificationTime = Item.now
            itemsByID[id] = item
            writeItem(item)
            appendToCustomOrder(id, collectionID: collectionID)
        }
        writeLibraryMetadata()
        return bump()
    }

    public func removeFromCollection(_ collectionID: String, ids: Set<String>) -> LibrarySnapshot {
        for id in ids {
            guard var item = itemsByID[id] else { continue }
            item.folders.removeAll { $0 == collectionID }
            item.modificationTime = Item.now
            itemsByID[id] = item
            writeItem(item)
        }
        metadata.folders = metadata.folders.mutating(collectionID) { collection in
            collection.customOrder.removeAll { ids.contains($0) }
        }
        writeLibraryMetadata()
        return bump()
    }

    // MARK: - Trash

    public func moveToTrash(ids: Set<String>) -> LibrarySnapshot {
        for id in ids {
            guard var item = itemsByID[id] else { continue }
            item.isDeleted = true
            item.modificationTime = Item.now
            itemsByID[id] = item
            writeItem(item)
        }
        return bump()
    }

    public func restore(ids: Set<String>) -> LibrarySnapshot {
        for id in ids {
            guard var item = itemsByID[id] else { continue }
            item.isDeleted = false
            item.modificationTime = Item.now
            itemsByID[id] = item
            writeItem(item)
        }
        return bump()
    }

    public func emptyTrash() -> LibrarySnapshot {
        let doomed = itemsByID.values.filter(\.isDeleted)
        for item in doomed {
            deletePermanently(item)
        }
        writeLibraryMetadata()
        return bump()
    }

    public func deletePermanently(ids: Set<String>) -> LibrarySnapshot {
        for id in ids {
            guard let item = itemsByID[id] else { continue }
            deletePermanently(item)
        }
        writeLibraryMetadata()
        return bump()
    }

    private func deletePermanently(_ item: Item) {
        itemsByID.removeValue(forKey: item.id)
        // Only reclaim the blob when nothing else references it.
        let stillReferenced = itemsByID.values.contains { $0.blobOwnerID == item.blobOwnerID }
        if item.aigle.virtualCopyOf == nil && stillReferenced {
            // Promote one surviving virtual copy to owner rather than orphaning bytes.
            if let heirID = itemsByID.first(where: { $0.value.aigle.virtualCopyOf == item.id })?.key,
               var heir = itemsByID[heirID] {
                let source = layout.itemDirectory(item.id)
                let destination = layout.itemDirectory(heirID)
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(
                    at: source.appending(path: item.fileName),
                    to: destination.appending(path: heir.fileName)
                )
                try? FileManager.default.moveItem(
                    at: source.appending(path: item.thumbnailFileName),
                    to: destination.appending(path: heir.thumbnailFileName)
                )
                heir.aigle.virtualCopyOf = nil
                itemsByID[heirID] = heir
                writeItem(heir)
                for (otherID, other) in itemsByID where other.aigle.virtualCopyOf == item.id {
                    var copy = other
                    copy.aigle.virtualCopyOf = heirID
                    itemsByID[otherID] = copy
                    writeItem(copy)
                }
            }
        }
        try? CoordinatedIO.remove(layout.itemDirectory(item.id))
        if let blob = item.aigle.blobID, blobIndex[blob] == item.id {
            blobIndex[blob] = itemsByID.values.first { $0.aigle.blobID == blob }?.blobOwnerID
        }
        metadata.folders = metadata.folders.map { stripFromOrder($0, id: item.id) }
    }

    private func stripFromOrder(_ collection: LibraryCollection, id: String) -> LibraryCollection {
        var copy = collection
        copy.customOrder.removeAll { $0 == id }
        copy.children = copy.children.map { stripFromOrder($0, id: id) }
        return copy
    }

    // MARK: - Collection tree

    @discardableResult
    public func createCollection(named name: String, parent: String?) -> (LibrarySnapshot, String) {
        let collection = LibraryCollection(name: name)
        if let parent {
            metadata.folders = metadata.folders.mutating(parent) { $0.children.append(collection) }
        } else {
            metadata.folders.append(collection)
        }
        writeLibraryMetadata()
        return (bump(), collection.id)
    }

    public func renameCollection(_ id: String, to name: String) -> LibrarySnapshot {
        metadata.folders = metadata.folders.mutating(id) {
            $0.name = name
            $0.modificationTime = Item.now
        }
        writeLibraryMetadata()
        return bump()
    }

    public func deleteCollection(_ id: String) -> LibrarySnapshot {
        let doomed = metadata.folders.find(id)?.flattened.map(\.id) ?? [id]
        metadata.folders = metadata.folders.removing(id)
        for (itemID, item) in itemsByID where item.folders.contains(where: doomed.contains) {
            var copy = item
            copy.folders.removeAll(where: doomed.contains)
            itemsByID[itemID] = copy
            writeItem(copy)
        }
        writeLibraryMetadata()
        return bump()
    }

    /// Moves `id` to be a child of `newParent` (nil = top level) at `index`.
    public func moveCollection(_ id: String, toParent newParent: String?, at index: Int?) -> LibrarySnapshot {
        guard let moving = metadata.folders.find(id) else { return snapshot() }
        // Refuse to drop a collection into its own subtree.
        if let newParent, moving.contains(id: newParent) { return snapshot() }
        var tree = metadata.folders.removing(id)
        if let newParent {
            tree = tree.mutating(newParent) { parent in
                let clamped = min(max(index ?? parent.children.count, 0), parent.children.count)
                parent.children.insert(moving, at: clamped)
            }
        } else {
            let clamped = min(max(index ?? tree.count, 0), tree.count)
            tree.insert(moving, at: clamped)
        }
        metadata.folders = tree
        writeLibraryMetadata()
        return bump()
    }

    public func sortCollectionsAlphabetically() -> LibrarySnapshot {
        metadata.folders = metadata.folders.sortedAlphabetically()
        writeLibraryMetadata()
        return bump()
    }

    // MARK: - Custom order

    private func appendToCustomOrder(_ id: String, collectionID: String?) {
        guard let collectionID else { return }
        metadata.folders = metadata.folders.mutating(collectionID) { collection in
            if !collection.customOrder.contains(id) { collection.customOrder.insert(id, at: 0) }
        }
    }

    public func setCustomOrder(_ order: [String], collectionID: String) -> LibrarySnapshot {
        metadata.folders = metadata.folders.mutating(collectionID) { $0.customOrder = order }
        writeLibraryMetadata()
        return bump()
    }

    /// Custom order for the smart sections, kept in library-level passthrough so
    /// Eagle ignores it but it still travels with the library.
    public func setGlobalCustomOrder(_ order: [String], key: String) -> LibrarySnapshot {
        var orders = metadata.passthrough["aigleOrders"]?.objectValue ?? [:]
        orders[key] = .array(order.map(JSONValue.string))
        metadata.passthrough["aigleOrders"] = .object(orders)
        writeLibraryMetadata()
        return bump()
    }

    public func globalCustomOrder(key: String) -> [String] {
        metadata.passthrough["aigleOrders"]?.objectValue?[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    // MARK: - Lookup

    public func item(_ id: String) -> Item? { itemsByID[id] }

    public func fileURL(for id: String) -> URL? {
        itemsByID[id].map { layout.fileURL(for: $0) }
    }
}

// MARK: - Content hashing

public enum ContentHash {
    /// Cheap but reliable identity: size + SHA256 of the head and tail of the file.
    /// Avoids reading gigabytes to notice a re-drop of the same video.
    public static func hash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var hasher = SHA256()
        hasher.update(data: Data("\(size)".utf8))
        let window = 256 * 1024
        if let head = try? handle.read(upToCount: window) { hasher.update(data: head) }
        if size > window * 2 {
            try? handle.seek(toOffset: UInt64(max(0, size - window)))
            if let tail = try? handle.readToEnd() { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(of data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(data.count)".utf8))
        hasher.update(data: data.prefix(256 * 1024))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
