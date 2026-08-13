import Foundation
import os.log

/// All library reads and writes funnel through `NSFileCoordinator` so the
/// library folder is safe to keep in iCloud Drive or Dropbox.
public enum CoordinatedIO {
    private static let log = Logger(subsystem: "cool.aigle.Aigle", category: "io")

    public static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, any Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var coordinationError: NSError?
        var writeError: (any Error)?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { writeURL in
            do { try data.write(to: writeURL, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    public static func copy(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var coordinationError: NSError?
        var copyError: (any Error)?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: source, options: [.withoutChanges],
            writingItemAt: destination, options: [.forReplacing],
            error: &coordinationError
        ) { readURL, writeURL in
            do {
                if FileManager.default.fileExists(atPath: writeURL.path) {
                    try FileManager.default.removeItem(at: writeURL)
                }
                try FileManager.default.copyItem(at: readURL, to: writeURL)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    public static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinationError: NSError?
        var removeError: (any Error)?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordinationError) { deleteURL in
            do { try FileManager.default.removeItem(at: deleteURL) } catch { removeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
    }

    /// iCloud files can exist as `.icloud` placeholders. Kick off a download and
    /// report whether the bytes are available right now.
    @discardableResult
    public static func ensureDownloaded(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
            return FileManager.default.fileExists(atPath: url.path)
        }
        if values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded {
            return true
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return false
    }

    /// The user's iCloud Drive root, if the account is signed in.
    public static var iCloudDriveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
