import Foundation

/// Reads and writes the Eagle on-disk JSON schema.
///
/// Every decoder keeps unrecognised keys in `passthrough`, and every encoder
/// writes them back out, so an Aigle round-trip is non-destructive for
/// libraries created by Eagle itself.
public enum EagleCodec {

    // MARK: - Shared plumbing

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder = JSONDecoder()

    public static func object(from data: Data) throws -> [String: JSONValue] {
        try decoder.decode([String: JSONValue].self, from: data)
    }

    public static func data(from object: [String: JSONValue]) throws -> Data {
        try encoder.encode(object)
    }

    // MARK: - Item

    /// Keys Aigle models explicitly; everything else lands in `passthrough`.
    static let itemKnownKeys: Set<String> = [
        "id", "name", "size", "btime", "mtime", "ext", "tags", "folders",
        "isDeleted", "url", "annotation", "modificationTime", "height", "width",
        "noThumbnail", "palettes", "star", "aigle",
    ]

    public static func decodeItem(_ data: Data) throws -> Item {
        let object = try object(from: data)
        return try decodeItem(object)
    }

    public static func decodeItem(_ object: [String: JSONValue]) throws -> Item {
        guard let id = object["id"]?.stringValue else {
            throw EagleCodecError.missingField("id")
        }
        var passthrough = object
        for key in itemKnownKeys { passthrough.removeValue(forKey: key) }

        var aigle = AigleExtras()
        if let raw = object["aigle"]?.objectValue {
            aigle.liked = raw["liked"]?.boolValue ?? false
            aigle.blobID = raw["blobID"]?.stringValue
            aigle.virtualCopyOf = raw["virtualCopyOf"]?.stringValue
            aigle.kind = raw["kind"]?.stringValue.flatMap(ItemKind.init(rawValue:))
        }

        let palettes: [ItemPalette] = (object["palettes"]?.arrayValue ?? []).compactMap { entry in
            guard let dict = entry.objectValue,
                  let color = dict["color"]?.arrayValue?.compactMap(\.intValue) else { return nil }
            return ItemPalette(color: color, ratio: dict["ratio"]?.doubleValue ?? 0)
        }

        let now = Item.now
        return Item(
            id: id,
            name: object["name"]?.stringValue ?? id,
            ext: object["ext"]?.stringValue ?? "",
            size: object["size"]?.intValue ?? 0,
            btime: object["btime"]?.intValue ?? now,
            mtime: object["mtime"]?.intValue ?? now,
            modificationTime: object["modificationTime"]?.intValue ?? now,
            width: object["width"]?.intValue ?? 0,
            height: object["height"]?.intValue ?? 0,
            tags: object["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            folders: object["folders"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            isDeleted: object["isDeleted"]?.boolValue ?? false,
            url: object["url"]?.stringValue ?? "",
            annotation: object["annotation"]?.stringValue ?? "",
            star: object["star"]?.intValue ?? 0,
            noThumbnail: object["noThumbnail"]?.boolValue ?? false,
            palettes: palettes,
            aigle: aigle,
            passthrough: passthrough
        )
    }

    public static func encodeItem(_ item: Item) -> [String: JSONValue] {
        var object = item.passthrough
        object["id"] = .string(item.id)
        object["name"] = .string(item.name)
        object["size"] = .int(item.size)
        object["btime"] = .int(item.btime)
        object["mtime"] = .int(item.mtime)
        object["ext"] = .string(item.ext)
        object["tags"] = .array(item.tags.map(JSONValue.string))
        object["folders"] = .array(item.folders.map(JSONValue.string))
        object["isDeleted"] = .bool(item.isDeleted)
        object["url"] = .string(item.url)
        object["annotation"] = .string(item.annotation)
        object["modificationTime"] = .int(item.modificationTime)
        object["height"] = .int(item.height)
        object["width"] = .int(item.width)
        object["noThumbnail"] = .bool(item.noThumbnail)
        object["star"] = .int(item.star)
        object["palettes"] = .array(item.palettes.map { palette in
            .object([
                "color": .array(palette.color.map(JSONValue.int)),
                "ratio": .double(palette.ratio),
            ])
        })

        var aigle: [String: JSONValue] = ["liked": .bool(item.aigle.liked)]
        if let blobID = item.aigle.blobID { aigle["blobID"] = .string(blobID) }
        if let copy = item.aigle.virtualCopyOf { aigle["virtualCopyOf"] = .string(copy) }
        // Only persist the kind when it was set explicitly — otherwise it is
        // inferred from the extension, and writing it would break round-tripping.
        if let kind = item.aigle.kind { aigle["kind"] = .string(kind.rawValue) }
        object["aigle"] = .object(aigle)
        return object
    }

    public static func encodeItemData(_ item: Item) throws -> Data {
        try data(from: encodeItem(item))
    }

    // MARK: - Collections

    static let collectionKnownKeys: Set<String> = [
        "id", "name", "description", "children", "modificationTime", "tags",
        "iconColor", "icon", "aigleOrder",
    ]

    public static func decodeCollection(_ object: [String: JSONValue]) -> LibraryCollection? {
        guard let id = object["id"]?.stringValue else { return nil }
        var passthrough = object
        for key in collectionKnownKeys { passthrough.removeValue(forKey: key) }
        let children = (object["children"]?.arrayValue ?? [])
            .compactMap { $0.objectValue }
            .compactMap(decodeCollection)
        return LibraryCollection(
            id: id,
            name: object["name"]?.stringValue ?? "Untitled",
            description: object["description"]?.stringValue ?? "",
            children: children,
            modificationTime: object["modificationTime"]?.intValue ?? Item.now,
            tags: object["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            iconColor: object["iconColor"]?.stringValue ?? "",
            icon: object["icon"]?.stringValue ?? "",
            customOrder: object["aigleOrder"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            passthrough: passthrough
        )
    }

    public static func encodeCollection(_ collection: LibraryCollection) -> [String: JSONValue] {
        var object = collection.passthrough
        object["id"] = .string(collection.id)
        object["name"] = .string(collection.name)
        object["description"] = .string(collection.description)
        object["children"] = .array(collection.children.map { .object(encodeCollection($0)) })
        object["modificationTime"] = .int(collection.modificationTime)
        object["tags"] = .array(collection.tags.map(JSONValue.string))
        object["iconColor"] = .string(collection.iconColor)
        object["icon"] = .string(collection.icon)
        if !collection.customOrder.isEmpty {
            object["aigleOrder"] = .array(collection.customOrder.map(JSONValue.string))
        } else {
            object.removeValue(forKey: "aigleOrder")
        }
        return object
    }

    // MARK: - Library metadata

    static let libraryKnownKeys: Set<String> = [
        "id", "folders", "smartFolders", "quickAccess", "tagsGroups",
        "modificationTime", "applicationVersion",
    ]

    public static func decodeLibraryMetadata(_ data: Data) throws -> LibraryMetadata {
        let object = try object(from: data)
        var passthrough = object
        for key in libraryKnownKeys { passthrough.removeValue(forKey: key) }
        return LibraryMetadata(
            id: object["id"]?.stringValue ?? EagleID.generate(),
            folders: (object["folders"]?.arrayValue ?? []).compactMap { $0.objectValue }.compactMap(decodeCollection),
            smartFolders: object["smartFolders"]?.arrayValue ?? [],
            quickAccess: object["quickAccess"]?.arrayValue ?? [],
            tagsGroups: object["tagsGroups"]?.arrayValue ?? [],
            modificationTime: object["modificationTime"]?.intValue ?? Item.now,
            applicationVersion: object["applicationVersion"]?.stringValue ?? "4.0.0",
            passthrough: passthrough
        )
    }

    public static func encodeLibraryMetadata(_ metadata: LibraryMetadata) throws -> Data {
        var object = metadata.passthrough
        object["id"] = .string(metadata.id)
        object["folders"] = .array(metadata.folders.map { .object(encodeCollection($0)) })
        object["smartFolders"] = .array(metadata.smartFolders)
        object["quickAccess"] = .array(metadata.quickAccess)
        object["tagsGroups"] = .array(metadata.tagsGroups)
        object["modificationTime"] = .int(metadata.modificationTime)
        object["applicationVersion"] = .string(metadata.applicationVersion)
        return try data(from: object)
    }
}

public enum EagleCodecError: LocalizedError {
    case missingField(String)
    case notALibrary(URL)

    public var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return String(localized: "Malformed item metadata: missing “\(field)”.")
        case .notALibrary(let url):
            return String(localized: "“\(url.lastPathComponent)” is not an Aigle or Eagle library.")
        }
    }
}
