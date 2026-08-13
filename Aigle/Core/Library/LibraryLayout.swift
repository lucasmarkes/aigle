import Foundation

/// Knows where everything lives inside a `<Name>.library` folder.
public struct LibraryLayout: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static let fileExtension = "library"

    public var name: String { root.deletingPathExtension().lastPathComponent }

    public var metadataURL: URL { root.appending(path: "metadata.json") }
    public var tagsURL: URL { root.appending(path: "tags.json") }
    public var mtimeURL: URL { root.appending(path: "mtime.json") }
    public var imagesURL: URL { root.appending(path: "images", directoryHint: .isDirectory) }

    /// Aigle-private sidecar directory (index cache, thumbnails for links, …).
    public var aigleURL: URL { root.appending(path: ".aigle", directoryHint: .isDirectory) }
    public var indexURL: URL { aigleURL.appending(path: "index.json") }
    public var settingsURL: URL { aigleURL.appending(path: "settings.json") }
    public var thumbCacheURL: URL { aigleURL.appending(path: "thumbs", directoryHint: .isDirectory) }

    public func itemDirectory(_ id: String) -> URL {
        imagesURL.appending(path: "\(id).info", directoryHint: .isDirectory)
    }

    public func itemMetadataURL(_ id: String) -> URL {
        itemDirectory(id).appending(path: "metadata.json")
    }

    /// The original file. Virtual copies point at the owning item's directory.
    public func fileURL(for item: Item) -> URL {
        itemDirectory(item.blobOwnerID).appending(path: item.fileName)
    }

    public func thumbnailURL(for item: Item) -> URL {
        itemDirectory(item.blobOwnerID).appending(path: item.thumbnailFileName)
    }

    /// True when the folder looks like an Eagle/Aigle library.
    public static func isLibrary(_ url: URL) -> Bool {
        let fm = FileManager.default
        let metadata = url.appending(path: "metadata.json")
        let images = url.appending(path: "images")
        var isDirectory: ObjCBool = false
        let hasImages = fm.fileExists(atPath: images.path, isDirectory: &isDirectory) && isDirectory.boolValue
        return fm.fileExists(atPath: metadata.path) && hasImages
    }

    /// Creates the folder skeleton for a brand-new library.
    public func createSkeleton() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: aigleURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbCacheURL, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var cache = thumbCacheURL
        try? cache.setResourceValues(excluded)

        if !fm.fileExists(atPath: metadataURL.path) {
            try CoordinatedIO.write(try EagleCodec.encodeLibraryMetadata(LibraryMetadata()), to: metadataURL)
        }
        if !fm.fileExists(atPath: tagsURL.path) {
            try CoordinatedIO.write(try JSONEncoder().encode(TagsFile()), to: tagsURL)
        }
        if !fm.fileExists(atPath: mtimeURL.path) {
            try CoordinatedIO.write(Data("{}".utf8), to: mtimeURL)
        }
    }
}
