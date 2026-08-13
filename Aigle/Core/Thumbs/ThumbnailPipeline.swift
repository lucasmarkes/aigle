import AppKit
import Foundation
import os.log

/// Buckets keep the cache small and reuse renders across zoom levels.
public enum ThumbnailSize: Int, CaseIterable, Sendable {
    case small = 160
    case medium = 320
    case large = 640
    case huge = 1280
    /// What the detail view asks for: a decode close to the original's own
    /// resolution, so viewing an image full-screen (or zoomed to 100%) shows the
    /// file you imported rather than an enlarged preview. Never upscales — a
    /// smaller original decodes at its native size.
    case full = 4096

    /// Grid cells never need more than `huge`; `full` is detail-view only.
    public static func bucket(for pointSize: CGFloat, scale: CGFloat = 2) -> ThumbnailSize {
        let pixels = pointSize * scale
        if pixels <= 160 { return .small }
        if pixels <= 320 { return .medium }
        if pixels <= 640 { return .large }
        return .huge
    }
}

/// Decodes and caches previews off the main thread: an LRU in memory on top of a
/// disk cache, feeding the grid only what it can see.
public actor ThumbnailPipeline {
    public static let shared = ThumbnailPipeline()

    private let log = Logger(subsystem: "cool.aigle.Aigle", category: "thumbs")
    private let memory = MemoryCache()
    private var inFlight: [String: Task<RenderedImage?, Never>] = [:]
    private var libraryLayout: LibraryLayout?

    public init() {}

    public func setLibraryLayout(_ layout: LibraryLayout?) {
        libraryLayout = layout
    }

    public func cachedSynchronously(_ item: Item, size: ThumbnailSize) -> RenderedImage? {
        memory.value(forKey: Self.key(item, size))
    }

    public func thumbnail(for item: Item, size: ThumbnailSize) async -> RenderedImage? {
        let key = Self.key(item, size)
        if let hit = memory.value(forKey: key) { return hit }
        if let running = inFlight[key] { return await running.value }

        let layout = libraryLayout
        let task = Task<RenderedImage?, Never>.detached(priority: .utility) {
            await Self.produce(item: item, size: size, layout: layout)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { memory.insert(result, forKey: key) }
        return result
    }

    public func prefetch(_ items: [Item], size: ThumbnailSize) {
        for item in items where memory.value(forKey: Self.key(item, size)) == nil {
            Task { _ = await thumbnail(for: item, size: size) }
        }
    }

    public func invalidate(_ item: Item) {
        for size in ThumbnailSize.allCases {
            memory.remove(forKey: Self.key(item, size))
        }
    }

    public func clearMemory() { memory.clear() }

    private static func key(_ item: Item, _ size: ThumbnailSize) -> String {
        "\(item.id)#\(item.mtime)@\(size.rawValue)"
    }

    // MARK: - Production

    private static func produce(item: Item, size: ThumbnailSize, layout: LibraryLayout?) async -> RenderedImage? {
        let maxPixel = size.rawValue

        // 1. Eagle already ships a `_thumbnail.png` for library items — but only
        //    use it when it genuinely covers the size being asked for. It used to
        //    be accepted for any request whose longest side was 320 or more,
        //    which meant the detail view was handed a ~512px preview and stretched
        //    it across the window: the original was fine on disk, it was simply
        //    never being decoded.
        //
        //    Grid tiers still take the sidecar even when it's a little smaller
        //    than the bucket — a preview scaled 1.25× in a cell is invisible, and
        //    decoding 50,000 originals to fill a grid is not.
        if case .library = item.origin, let layout {
            let sidecar = layout.thumbnailURL(for: item)
            let sidecarIsEnough = size.rawValue <= ThumbnailSize.large.rawValue
            if FileManager.default.fileExists(atPath: sidecar.path),
               let image = MediaProbe.downsample(sidecar, maxPixel: maxPixel),
               sidecarIsEnough || max(image.width, image.height) >= maxPixel {
                return image
            }
        }

        // 2. Disk cache for connected folders (and anything oversized).
        let cacheURL = diskCacheURL(item: item, size: size)
        if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path),
           let image = MediaProbe.downsample(cacheURL, maxPixel: maxPixel) {
            return image
        }

        // 3. Render from the original.
        guard let source = resolveFileURL(item: item, layout: layout) else { return nil }
        guard CoordinatedIO.ensureDownloaded(source) else { return nil }
        guard let rendered = await MediaProbe.render(url: source, kind: item.kind, maxPixel: maxPixel) else { return nil }

        if let cacheURL, let data = MediaProbe.jpegData(rendered) {
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL, options: .atomic)
        }
        return rendered
    }

    public static func resolveFileURL(item: Item, layout: LibraryLayout?) -> URL? {
        switch item.origin {
        case .library:
            guard let layout else { return nil }
            if item.kind == .link {
                let sidecar = layout.thumbnailURL(for: item)
                return FileManager.default.fileExists(atPath: sidecar.path) ? sidecar : nil
            }
            return layout.fileURL(for: item)
        case .connected:
            return ConnectedFolderIndex.fileURL(for: item)
        }
    }

    private static func diskCacheURL(item: Item, size: ThumbnailSize) -> URL? {
        guard case .connected = item.origin else { return nil }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "cool.aigle.Aigle/thumbs", directoryHint: .isDirectory)
            .appending(path: "\(item.id)-\(item.mtime)-\(size.rawValue).jpg")
    }
}

/// A small LRU on top of `NSCache` so decoded pixels don't grow without bound.
private final class MemoryCache: @unchecked Sendable {
    private final class Box {
        let image: RenderedImage
        init(_ image: RenderedImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    init() {
        cache.countLimit = 1200
        cache.totalCostLimit = 512 * 1024 * 1024
    }

    func value(forKey key: String) -> RenderedImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: RenderedImage, forKey key: String) {
        let cost = image.cgImage.bytesPerRow * image.cgImage.height
        cache.setObject(Box(image), forKey: key as NSString, cost: cost)
    }

    func remove(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func clear() { cache.removeAllObjects() }
}
