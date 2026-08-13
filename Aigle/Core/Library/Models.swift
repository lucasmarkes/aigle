import Foundation

// MARK: - Identifiers

/// Eagle-style short identifier: 13 uppercase alphanumeric characters.
public enum EagleID {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    public static func generate() -> String {
        String((0..<13).map { _ in alphabet.randomElement()! })
    }

    /// Stable identifier derived from a file path — used for connected-folder items
    /// so their identity survives relaunches without any on-disk metadata.
    public static func derived(from path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        var value = hash
        var out = ""
        for _ in 0..<13 {
            out.append(alphabet[Int(value % UInt64(alphabet.count))])
            value /= UInt64(alphabet.count)
            if value == 0 { value = hash &* 31 &+ 7 }
        }
        return out
    }
}

// MARK: - Item

/// Where an item's bytes live.
public enum ItemOrigin: Hashable, Sendable {
    /// Stored inside the library at `images/<id>.info/`.
    case library
    /// Referenced in place inside a connected folder.
    case connected(folderID: String)
}

/// What kind of thing the item is. Drives thumbnailing and the detail view.
public enum ItemKind: String, Codable, Hashable, Sendable, CaseIterable {
    case image
    case animatedImage
    case vector      // svg
    case document    // pdf
    case video
    case audio
    case link
    case other

    public var isPlayable: Bool { self == .video || self == .audio }
    public var animates: Bool { self == .video || self == .animatedImage }
}

/// Aigle-specific fields. Namespaced so Eagle can still open the library.
public struct AigleExtras: Codable, Hashable, Sendable {
    public var liked: Bool = false
    /// Identity of the underlying bytes. Two items sharing a blob are virtual copies.
    public var blobID: String?
    /// Set on the *copy*: the item whose folder actually holds the file.
    public var virtualCopyOf: String?
    public var kind: ItemKind?

    public init(liked: Bool = false, blobID: String? = nil, virtualCopyOf: String? = nil, kind: ItemKind? = nil) {
        self.liked = liked
        self.blobID = blobID
        self.virtualCopyOf = virtualCopyOf
        self.kind = kind
    }
}

/// A single library (or connected-folder) entry.
///
/// The `Codable` conformance is the Eagle on-disk `metadata.json` schema; unknown
/// Eagle keys we don't model are preserved verbatim in ``passthrough`` so a
/// round-trip through Aigle never destroys data Eagle wrote.
public struct Item: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var ext: String
    public var size: Int
    /// Milliseconds since 1970, as Eagle writes them.
    public var btime: Int
    public var mtime: Int
    public var modificationTime: Int
    public var width: Int
    public var height: Int
    public var tags: [String]
    public var folders: [String]
    public var isDeleted: Bool
    public var url: String
    public var annotation: String
    public var star: Int
    public var noThumbnail: Bool
    public var palettes: [ItemPalette]
    public var aigle: AigleExtras
    /// Eagle keys we do not model, round-tripped untouched.
    public var passthrough: [String: JSONValue]

    /// Not serialised — resolved at load time.
    public var origin: ItemOrigin = .library

    public init(
        id: String = EagleID.generate(),
        name: String,
        ext: String,
        size: Int = 0,
        btime: Int = Item.now,
        mtime: Int = Item.now,
        modificationTime: Int = Item.now,
        width: Int = 0,
        height: Int = 0,
        tags: [String] = [],
        folders: [String] = [],
        isDeleted: Bool = false,
        url: String = "",
        annotation: String = "",
        star: Int = 0,
        noThumbnail: Bool = false,
        palettes: [ItemPalette] = [],
        aigle: AigleExtras = AigleExtras(),
        passthrough: [String: JSONValue] = [:],
        origin: ItemOrigin = .library
    ) {
        self.id = id
        self.name = name
        self.ext = ext
        self.size = size
        self.btime = btime
        self.mtime = mtime
        self.modificationTime = modificationTime
        self.width = width
        self.height = height
        self.tags = tags
        self.folders = folders
        self.isDeleted = isDeleted
        self.url = url
        self.annotation = annotation
        self.star = star
        self.noThumbnail = noThumbnail
        self.palettes = palettes
        self.aigle = aigle
        self.passthrough = passthrough
        self.origin = origin
    }

    public static var now: Int { Int(Date().timeIntervalSince1970 * 1000) }

    public var displayName: String { name }

    public var fileName: String { ext.isEmpty ? name : "\(name).\(ext)" }

    public var thumbnailFileName: String { ext.isEmpty ? "\(name)_thumbnail.png" : "\(name)_thumbnail.png" }

    public var dateAdded: Date { Date(timeIntervalSince1970: Double(btime) / 1000) }
    public var dateModified: Date { Date(timeIntervalSince1970: Double(mtime) / 1000) }

    public var liked: Bool {
        get { aigle.liked || star > 0 }
        set { aigle.liked = newValue }
    }

    public var isLink: Bool { kind == .link }

    public var kind: ItemKind {
        if let k = aigle.kind { return k }
        return ItemKind.infer(ext: ext, url: url)
    }

    public var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    /// Bytes identity for virtual copies: the "owning" item id.
    public var blobOwnerID: String { aigle.virtualCopyOf ?? id }

    public var connectedFolderID: String? {
        if case .connected(let id) = origin { return id }
        return nil
    }
}

public struct ItemPalette: Codable, Hashable, Sendable {
    public var color: [Int]
    public var ratio: Double
    public init(color: [Int], ratio: Double) {
        self.color = color
        self.ratio = ratio
    }
}

extension ItemKind {
    public static func infer(ext: String, url: String = "") -> ItemKind {
        switch ext.lowercased() {
        case "": return url.isEmpty ? .other : .link
        case "gif", "apng": return .animatedImage
        case "svg": return .vector
        case "pdf": return .document
        case "png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif", "jfif", "ico":
            return .image
        case "mp4", "mov", "m4v", "webm", "avi", "mkv", "mpg", "mpeg":
            return .video
        case "mp3", "wav", "aac", "m4a", "flac", "aiff":
            return .audio
        case "url", "link":
            return .link
        default:
            return .other
        }
    }

    /// File extensions Aigle will import when a folder is dropped or connected.
    public static let importableExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif", "jfif", "ico",
        "svg", "pdf",
        "mp4", "mov", "m4v", "webm", "avi", "mkv",
        "mp3", "wav", "aac", "m4a", "flac", "aiff",
    ]
}

// MARK: - Collection (Eagle "folder")

public struct LibraryCollection: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var children: [LibraryCollection]
    public var modificationTime: Int
    public var tags: [String]
    public var iconColor: String
    public var icon: String
    /// Aigle: explicit item order when the collection sorts by ``SortOrder/custom``.
    public var customOrder: [String]
    public var passthrough: [String: JSONValue]

    public init(
        id: String = EagleID.generate(),
        name: String,
        description: String = "",
        children: [LibraryCollection] = [],
        modificationTime: Int = Item.now,
        tags: [String] = [],
        iconColor: String = "",
        icon: String = "",
        customOrder: [String] = [],
        passthrough: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.children = children
        self.modificationTime = modificationTime
        self.tags = tags
        self.iconColor = iconColor
        self.icon = icon
        self.customOrder = customOrder
        self.passthrough = passthrough
    }
}

extension LibraryCollection {
    /// Depth-first flattening, parents before children.
    public var flattened: [LibraryCollection] {
        [self] + children.flatMap(\.flattened)
    }

    public func contains(id target: String) -> Bool {
        if id == target { return true }
        return children.contains { $0.contains(id: target) }
    }
}

extension Array where Element == LibraryCollection {
    public var flattened: [LibraryCollection] { flatMap(\.flattened) }

    public func find(_ id: String) -> LibraryCollection? {
        for c in self {
            if c.id == id { return c }
            if let hit = c.children.find(id) { return hit }
        }
        return nil
    }

    /// Applies `transform` to the collection with `id`, in place, anywhere in the tree.
    public func mutating(_ id: String, _ transform: (inout LibraryCollection) -> Void) -> [LibraryCollection] {
        map { collection in
            var copy = collection
            if copy.id == id {
                transform(&copy)
            } else {
                copy.children = copy.children.mutating(id, transform)
            }
            return copy
        }
    }

    public func removing(_ id: String) -> [LibraryCollection] {
        compactMap { collection in
            guard collection.id != id else { return nil }
            var copy = collection
            copy.children = copy.children.removing(id)
            return copy
        }
    }

    public func sortedAlphabetically() -> [LibraryCollection] {
        map { collection in
            var copy = collection
            copy.children = copy.children.sortedAlphabetically()
            return copy
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Library-level metadata

public struct LibraryMetadata: Sendable {
    public var id: String
    public var folders: [LibraryCollection]
    public var smartFolders: [JSONValue]
    public var quickAccess: [JSONValue]
    public var tagsGroups: [JSONValue]
    public var modificationTime: Int
    public var applicationVersion: String
    public var passthrough: [String: JSONValue]

    public init(
        id: String = EagleID.generate(),
        folders: [LibraryCollection] = [],
        smartFolders: [JSONValue] = [],
        quickAccess: [JSONValue] = [],
        tagsGroups: [JSONValue] = [],
        modificationTime: Int = Item.now,
        applicationVersion: String = "4.0.0",
        passthrough: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.folders = folders
        self.smartFolders = smartFolders
        self.quickAccess = quickAccess
        self.tagsGroups = tagsGroups
        self.modificationTime = modificationTime
        self.applicationVersion = applicationVersion
        self.passthrough = passthrough
    }
}

public struct TagsFile: Codable, Sendable, Hashable {
    public var historyTags: [String]
    public var starredTags: [String]
    public var recentTags: [String]

    public init(historyTags: [String] = [], starredTags: [String] = [], recentTags: [String] = []) {
        self.historyTags = historyTags
        self.starredTags = starredTags
        self.recentTags = recentTags
    }
}

// MARK: - Sorting

public enum SortField: String, CaseIterable, Codable, Sendable {
    case dateAdded
    case dateModified
    case name
    case size
    case custom
}

public struct SortOrder: Hashable, Codable, Sendable {
    public var field: SortField
    public var ascending: Bool

    public init(field: SortField = .dateAdded, ascending: Bool = false) {
        self.field = field
        self.ascending = ascending
    }

    public static let newestFirst = SortOrder(field: .dateAdded, ascending: false)
    public static let custom = SortOrder(field: .custom, ascending: true)
}

// MARK: - Sidebar selection

public enum SmartSection: String, Hashable, Codable, Sendable, CaseIterable {
    case all
    case inbox
    case likes
    case trash
}

public enum SidebarSelection: Hashable, Codable, Sendable {
    case smart(SmartSection)
    case collection(String)
    case connectedFolder(String)
    case tag(String)

    public var collectionID: String? {
        if case .collection(let id) = self { return id }
        return nil
    }
}
