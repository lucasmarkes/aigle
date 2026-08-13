import Foundation
import os.log

/// Persists security-scoped bookmarks so the sandboxed app can reopen the user's
/// library (and connected folders) on the next launch — wherever they live:
/// internal disk, external drive, Dropbox, or iCloud Drive.
public struct SecurityScopedAccess: Sendable {
    public let url: URL
    private let didStart: Bool

    init(url: URL, didStart: Bool) {
        self.url = url
        self.didStart = didStart
    }

    public func stop() {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}

public enum BookmarkStore {
    private static let log = Logger(subsystem: "cool.aigle.Aigle", category: "bookmarks")
    private static let defaultsKey = "cool.aigle.bookmarks"

    private static var table: [String: Data] {
        get { (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Creates and stores a bookmark for `url` under `key`.
    @discardableResult
    public static func store(_ url: URL, key: String) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var current = table
            current[key] = data
            table = current
            return true
        } catch {
            log.error("Failed to bookmark \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func remove(key: String) {
        var current = table
        current.removeValue(forKey: key)
        table = current
    }

    public static func hasBookmark(key: String) -> Bool { table[key] != nil }

    public static var keys: [String] { Array(table.keys) }

    /// Resolves a stored bookmark and begins security-scoped access.
    /// The caller owns the returned access token and must `stop()` it.
    public static func resolve(key: String) -> SecurityScopedAccess? {
        guard let data = table[key] else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let started = url.startAccessingSecurityScopedResource()
            if stale { store(url, key: key) }
            return SecurityScopedAccess(url: url, didStart: started)
        } catch {
            log.error("Failed to resolve bookmark \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Resolves without starting access — for showing a path in the UI.
    public static func peek(key: String) -> URL? {
        guard let data = table[key] else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    public static func key(forLibraryAt url: URL) -> String { "library:" + url.standardizedFileURL.path }
    public static func key(forFolderAt url: URL) -> String { "folder:" + url.standardizedFileURL.path }
}
