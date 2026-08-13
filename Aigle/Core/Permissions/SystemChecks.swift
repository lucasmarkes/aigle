import Foundation
import ObjectiveC
import os.log

/// Safari's extension APIs, reached on demand instead of linked.
///
/// Two reasons not to `import SafariServices`: a user who never opens the Safari
/// step shouldn't pay for the framework (and the private ones behind it) at every
/// launch, and linking it makes the Objective-C runtime's `realizeAllClasses()`
/// pass — which XCTest triggers when it injects the test bundle — crash in this
/// app's Enhanced Security / arm64e configuration.
private enum SafariBridge {
    private static let path = "/System/Library/Frameworks/SafariServices.framework/SafariServices"

    @discardableResult
    static func load() -> Bool { dlopen(path, RTLD_LAZY) != nil }

    /// Looks up a class method by name once the framework is in the process.
    static func classMethod(_ className: String, _ selectorName: String) -> (AnyClass, Selector, IMP)? {
        guard load(),
              let cls = NSClassFromString(className)
        else { return nil }
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        return (cls, selector, method_getImplementation(method))
    }

    /// Reads a `BOOL` property by its getter. Deliberately not `value(forKey:)`:
    /// KVC raises an Objective-C exception for an unknown key, which is not
    /// catchable in Swift, so a renamed property would take the app down.
    static func boolProperty(_ object: AnyObject, getter: String) -> Bool? {
        let selector = NSSelectorFromString(getter)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector)
        else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)
    }
}

/// Real probes for the things Aigle actually needs. Every check here touches the
/// system it claims to describe — nothing reports "granted" from a stored flag —
/// because the sandbox only tells the truth when you try the operation.
public enum SystemChecks {
    private static let log = Logger(subsystem: "cool.aigle.Aigle", category: "checks")

    // MARK: - Security-scoped access

    /// Holds security-scoped access to a picker-provided URL for the duration of
    /// `body`. URLs handed back by `fileImporter`/`NSOpenPanel` are scoped: writing
    /// through one without starting access fails with "You don't have permission
    /// to save the file …", even though the user just chose the folder.
    public static func withAccess<T>(to url: URL, _ body: (URL) throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    // MARK: - Writability

    public enum WriteProbe: Sendable, Equatable {
        case writable
        case notWritable(String)
    }

    /// Creates and removes a hidden probe file. This is the only honest way to
    /// know a sandboxed app may write somewhere — `isWritableFile` consults POSIX
    /// permissions and happily lies about sandbox and TCC denials.
    public static func probeWritable(_ directory: URL, holdingScope: Bool = true) -> WriteProbe {
        let attempt: () -> WriteProbe = {
            let probe = directory.appending(path: ".aigle-write-probe-\(UUID().uuidString.prefix(8))")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("ok".utf8).write(to: probe, options: .atomic)
                try? FileManager.default.removeItem(at: probe)
                return .writable
            } catch {
                return .notWritable(error.localizedDescription)
            }
        }
        return holdingScope ? withAccess(to: directory) { _ in attempt() } : attempt()
    }

    // MARK: - Bookmarks

    public enum BookmarkHealth: Sendable, Equatable {
        case healthy(path: String)
        case missing
        case unresolvable(String)
        case targetGone(path: String)
    }

    /// Verifies that the app can still reach a folder it was granted earlier —
    /// this is what decides whether the library reopens after a relaunch.
    public static func bookmarkHealth(key: String) -> BookmarkHealth {
        guard BookmarkStore.hasBookmark(key: key) else { return .missing }
        guard let access = BookmarkStore.resolve(key: key) else {
            return .unresolvable(String(localized: "The saved permission could not be resolved."))
        }
        defer { access.stop() }
        guard FileManager.default.fileExists(atPath: access.url.path) else {
            return .targetGone(path: access.url.path)
        }
        return .healthy(path: access.url.path)
    }

    // MARK: - iCloud Drive

    public enum ICloudStatus: Sendable, Equatable {
        case available(URL)
        case driveOff
        case signedOut
    }

    public static func iCloudStatus() -> ICloudStatus {
        let signedIn = FileManager.default.ubiquityIdentityToken != nil
        if let url = CoordinatedIO.iCloudDriveURL { return .available(url) }
        return signedIn ? .driveOff : .signedOut
    }

    /// True when `url` lives inside iCloud Drive, Dropbox, or another folder that
    /// syncs — used to tell the user their library follows them between Macs.
    public static func syncProvider(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if path.contains("/Library/Mobile Documents/com~apple~CloudDocs") { return "iCloud Drive" }
        if path.contains("/Library/CloudStorage/Dropbox") || path.contains("/Dropbox/") { return "Dropbox" }
        if path.contains("/Library/CloudStorage/GoogleDrive") { return "Google Drive" }
        if path.contains("/Library/CloudStorage/OneDrive") { return "OneDrive" }
        if path.hasPrefix("/Volumes/") { return String(localized: "an external drive") }
        return nil
    }

    // MARK: - Local port

    /// Binds 127.0.0.1:`port` for a moment to see whether the browser-extension
    /// listener would be able to claim it.
    public static func isPortAvailable(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    // MARK: - Safari extension

    public enum SafariExtensionState: Sendable, Equatable {
        case enabled
        case disabled
        case unavailable(String)
    }

    public static let safariExtensionID = "cool.aigle.Aigle.Safari"

    /// Asks Safari whether the embedded extension is switched on. Safari only
    /// knows about extensions inside an app it has seen in /Applications, so an
    /// "unavailable" answer usually means "run the app from /Applications first".
    public static func safariExtensionState() async -> SafariExtensionState {
        typealias Handler = @convention(block) (AnyObject?, NSError?) -> Void
        typealias Call = @convention(c) (AnyClass, Selector, NSString, Handler) -> Void

        guard let (cls, selector, imp) = SafariBridge.classMethod(
            "SFSafariExtensionManager",
            "getStateOfSafariExtensionWithIdentifier:completionHandler:"
        ) else {
            return .unavailable(String(localized: "Safari extension support isn’t available on this Mac."))
        }

        let identifier = safariExtensionID
        return await withCheckedContinuation { (continuation: CheckedContinuation<SafariExtensionState, Never>) in
            let handler: Handler = { state, error in
                // `SFSafariExtensionState.enabled` is declared `getter=isEnabled`.
                let enabledValue = state.flatMap { SafariBridge.boolProperty($0, getter: "isEnabled") }
                if let enabled = enabledValue {
                    continuation.resume(returning: enabled ? .enabled : .disabled)
                } else {
                    let message = error?.localizedDescription
                        ?? String(localized: "Safari hasn’t registered the extension yet.")
                    continuation.resume(returning: .unavailable(message))
                }
            }
            let call = unsafeBitCast(imp, to: Call.self)
            call(cls, selector, identifier as NSString, handler)
        }
    }

    public static func openSafariExtensionPreferences() {
        typealias Handler = @convention(block) (NSError?) -> Void
        typealias Call = @convention(c) (AnyClass, Selector, NSString, Handler) -> Void

        guard let (cls, selector, imp) = SafariBridge.classMethod(
            "SFSafariApplication",
            "showPreferencesForExtensionWithIdentifier:completionHandler:"
        ) else {
            log.error("SafariServices unavailable; cannot open extension preferences")
            return
        }

        let handler: Handler = { error in
            if let error {
                log.error("Safari preferences failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let call = unsafeBitCast(imp, to: Call.self)
        call(cls, selector, safariExtensionID as NSString, handler)
    }

    // MARK: - Install location

    /// Safari extensions and Launch Services both behave differently when the app
    /// runs from a build folder rather than /Applications.
    public static var isRunningFromApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.contains("/Applications/")
    }
}
