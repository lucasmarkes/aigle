import Foundation
import os.log

/// A folder referenced in place — Aigle never copies its files.
public struct ConnectedFolder: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var path: String

    public init(url: URL) {
        let standardized = url.standardizedFileURL
        self.id = EagleID.derived(from: standardized.path)
        self.name = standardized.lastPathComponent
        self.path = standardized.path
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var bookmarkKey: String { "folder:" + path }
}

/// Scans and caches connected folders so they open instantly — no grey
/// placeholders on launch, previews prepared in the background.
public actor ConnectedFolderIndex {
    private let log = Logger(subsystem: "cool.aigle.Aigle", category: "folders")
    private var cache: [String: [Item]] = [:]

    public init() {}

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appending(path: "cool.aigle.Aigle/folders", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cacheURL(_ folder: ConnectedFolder) -> URL {
        Self.cacheDirectory.appending(path: "\(folder.id).json")
    }

    /// Returns the last-known contents immediately, if any.
    public func cached(_ folder: ConnectedFolder) -> [Item] {
        if let hit = cache[folder.id] { return hit }
        guard let data = try? Data(contentsOf: cacheURL(folder)),
              let raw = try? JSONDecoder().decode([[String: JSONValue]].self, from: data)
        else { return [] }
        var items = raw.compactMap { try? EagleCodec.decodeItem($0) }
        for index in items.indices { items[index].origin = .connected(folderID: folder.id) }
        cache[folder.id] = items
        return items
    }

    /// Walks the folder and rebuilds its index.
    public func scan(_ folder: ConnectedFolder) async -> [Item] {
        var items: [Item] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        let candidates = Self.walk(folder.url, keys: keys)
        guard !candidates.isEmpty else { return cached(folder) }
        let previous = Dictionary(cached(folder).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for url in candidates {
            let ext = url.pathExtension.lowercased()
            let values = try? url.resourceValues(forKeys: Set(keys))
            let id = EagleID.derived(from: url.path)
            let modified = values?.contentModificationDate ?? .distantPast
            let mtime = Int(modified.timeIntervalSince1970 * 1000)

            if let known = previous[id], known.mtime == mtime, known.width > 0 {
                items.append(known)
                continue
            }

            let kind = ItemKind.infer(ext: ext)
            var item = Item(
                id: id,
                name: url.deletingPathExtension().lastPathComponent,
                ext: ext,
                size: values?.fileSize ?? 0,
                btime: Int((values?.creationDate ?? modified).timeIntervalSince1970 * 1000),
                mtime: mtime,
                modificationTime: mtime,
                url: url.absoluteString,
                aigle: AigleExtras(kind: kind),
                origin: .connected(folderID: folder.id)
            )
            if let dimensions = await MediaProbe.dimensions(of: url, kind: kind) {
                item.width = dimensions.width
                item.height = dimensions.height
            }
            items.append(item)
        }

        cache[folder.id] = items
        persist(items, for: folder)
        return items
    }

    /// Synchronous directory walk — `FileManager`'s enumerator can't be iterated
    /// from an async context, so we gather candidates first.
    private nonisolated static func walk(_ root: URL, keys: [URLResourceKey]) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            guard ItemKind.importableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            out.append(url)
        }
        return out
    }

    private func persist(_ items: [Item], for folder: ConnectedFolder) {
        let raw = items.map(EagleCodec.encodeItem)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: cacheURL(folder), options: .atomic)
    }

    public func forget(_ folder: ConnectedFolder) {
        cache.removeValue(forKey: folder.id)
        try? FileManager.default.removeItem(at: cacheURL(folder))
    }

    /// Resolves a connected item back to its real file on disk.
    public nonisolated static func fileURL(for item: Item) -> URL? {
        guard case .connected = item.origin, let url = URL(string: item.url) else { return nil }
        return url
    }
}

/// Persistence for the connected-folder list itself.
public enum ConnectedFolderStore {
    private static let key = "aigle.connectedFolders"

    public static func load() -> [ConnectedFolder] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let folders = try? JSONDecoder().decode([ConnectedFolder].self, from: data)
        else { return [] }
        return folders
    }

    public static func save(_ folders: [ConnectedFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
