import AppKit
import Observation
import SwiftUI

/// One thing Aigle needs, and whether it actually has it right now.
/// Main-actor UI state (its labels are `LocalizedStringKey`s); the `Status`
/// values that cross from the probes are the Sendable part.
public struct SetupCheck: Identifiable, Equatable {
    public enum Status: Sendable, Equatable {
        case idle
        case checking
        case pass(String)
        case warn(String)
        case fail(String)

        public var isPass: Bool { if case .pass = self { true } else { false } }
        public var isFail: Bool { if case .fail = self { true } else { false } }
        public var detail: String? {
            switch self {
            case .idle, .checking: nil
            case .pass(let text), .warn(let text), .fail(let text): text
            }
        }
    }

    /// Whether a failure should block finishing setup.
    public enum Weight: Sendable { case required, recommended, optional }

    public var id: SetupCheckKind
    public var title: LocalizedStringKey
    public var explanation: LocalizedStringKey
    public var symbol: String
    public var weight: Weight
    public var status: Status = .idle
}

public enum SetupCheckKind: String, CaseIterable, Identifiable, Sendable {
    case libraryOpen
    case libraryWritable
    case libraryReopens
    case librarySynced
    case quickAccess
    case extensionPort
    case safariExtension

    public var id: String { rawValue }
}

public enum SetupStage: String, CaseIterable, Identifiable, Sendable {
    case welcome, library, permissions, access, browser, ready

    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .welcome: "Welcome"
        case .library: "Library"
        case .permissions: "Permissions"
        case .access: "Quick access"
        case .browser: "Browsers"
        case .ready: "Ready"
        }
    }

    public var symbol: String {
        switch self {
        case .welcome: "sparkles"
        case .library: "books.vertical"
        case .permissions: "lock.shield"
        case .access: "folder.badge.person.crop"
        case .browser: "safari"
        case .ready: "checkmark.seal"
        }
    }
}

/// A folder Aigle offers to pre-authorise, so connecting it later is one click.
public struct QuickAccessFolder: Identifiable, Sendable, Equatable {
    public var id: String { url.standardizedFileURL.path }
    public var url: URL
    public var name: String
    public var symbol: String
    public var isGranted: Bool = false

    public var bookmarkKey: String { BookmarkStore.key(forFolderAt: url) }
}

/// Drives the setup assistant: which step we're on, what's been verified, and
/// what's still missing. State is persisted, so quitting halfway through and
/// relaunching drops you back on the same step — and a library that stops
/// resolving pulls the assistant back up on its own.
@MainActor
@Observable
public final class SetupModel {
    private enum Key {
        static let stage = "aigle.setup.stage"
        static let finished = "aigle.setup.finished"
        static let seenStages = "aigle.setup.seenStages"
    }

    public private(set) var stage: SetupStage {
        didSet { UserDefaults.standard.set(stage.rawValue, forKey: Key.stage) }
    }

    /// True once the user has been all the way through. Persisted, so setup never
    /// reappears uninvited.
    public private(set) var hasFinished: Bool {
        didSet { UserDefaults.standard.set(hasFinished, forKey: Key.finished) }
    }

    private var seenStages: Set<String> {
        didSet { UserDefaults.standard.set(Array(seenStages), forKey: Key.seenStages) }
    }

    /// Set when the user reopens setup from the Help menu after finishing.
    public var isReopened = false

    /// +1 when moving forward, -1 back — the content transition reads this so
    /// steps slide the way the user is travelling.
    public private(set) var direction = 1

    public private(set) var checks: [SetupCheck] = SetupModel.template
    public private(set) var quickAccess: [QuickAccessFolder] = []
    public private(set) var isRefreshing = false

    public init() {
        let defaults = UserDefaults.standard
        stage = SetupStage(rawValue: defaults.string(forKey: Key.stage) ?? "") ?? .welcome
        hasFinished = defaults.bool(forKey: Key.finished)
        seenStages = Set(defaults.stringArray(forKey: Key.seenStages) ?? [])
        quickAccess = Self.suggestedFolders()
    }

    // MARK: - Presentation

    /// The assistant takes over the window when setup hasn't been completed, when
    /// no library is open (there's nothing else to show), or when it's reopened
    /// deliberately.
    public func isActive(libraryOpen: Bool) -> Bool {
        isReopened || !hasFinished || !libraryOpen
    }

    public func reopen() {
        isReopened = true
        direction = 1
        stage = .welcome
    }

    public func finish() {
        hasFinished = true
        isReopened = false
        markSeen(.ready)
    }

    // MARK: - Navigation

    public var stages: [SetupStage] { SetupStage.allCases }

    public func markSeen(_ stage: SetupStage) { seenStages.insert(stage.rawValue) }
    public func hasSeen(_ stage: SetupStage) -> Bool { seenStages.contains(stage.rawValue) }

    public func go(to target: SetupStage) {
        guard target != stage else { return }
        let from = stages.firstIndex(of: stage) ?? 0
        let to = stages.firstIndex(of: target) ?? 0
        direction = to >= from ? 1 : -1
        markSeen(stage)
        stage = target
    }

    public func advance() {
        guard let index = stages.firstIndex(of: stage), index + 1 < stages.count else { return }
        go(to: stages[index + 1])
    }

    public func retreat() {
        guard let index = stages.firstIndex(of: stage), index > 0 else { return }
        go(to: stages[index - 1])
    }

    public var canRetreat: Bool { (stages.firstIndex(of: stage) ?? 0) > 0 }

    /// Nothing past the library step means anything without one, so closing the
    /// library — or relaunching after it moved — walks back rather than leaving
    /// the user on a step whose rail entry is disabled.
    public func enforceLibraryGate(libraryOpen: Bool) {
        guard !libraryOpen,
              let current = stages.firstIndex(of: stage),
              let gate = stages.firstIndex(of: .library),
              current > gate
        else { return }
        go(to: .library)
    }

    /// The library step is the only hard gate — everything after it is optional.
    public func canAdvance(libraryOpen: Bool) -> Bool {
        stage == .library ? libraryOpen : true
    }

    // MARK: - Checks

    public func check(_ kind: SetupCheckKind) -> SetupCheck? {
        checks.first { $0.id == kind }
    }

    public var blockingFailures: [SetupCheck] {
        checks.filter { $0.weight == .required && $0.status.isFail }
    }

    public var passedCount: Int { checks.filter(\.status.isPass).count }

    private func update(_ kind: SetupCheckKind, _ status: SetupCheck.Status) {
        guard let index = checks.firstIndex(where: { $0.id == kind }) else { return }
        checks[index].status = status
    }

    /// Re-runs every probe. Called when setup appears, when the app is brought
    /// back to the front (the user may have just changed something in System
    /// Settings or Safari), and from the Refresh button.
    public func refresh(controller: LibraryController, settings: AppSettings, server: ExtensionServer) async {
        isRefreshing = true
        defer { isRefreshing = false }

        for kind in SetupCheckKind.allCases where check(kind)?.status != .checking {
            update(kind, .checking)
        }

        refreshQuickAccess()
        refreshLibraryChecks(controller: controller)
        refreshPortCheck(settings: settings, server: server)
        refreshQuickAccessCheck()
        await refreshSafariCheck()
    }

    private func refreshLibraryChecks(controller: LibraryController) {
        guard let layout = controller.snapshot?.layout else {
            let message = String(localized: "No library open yet.")
            update(.libraryOpen, .fail(message))
            update(.libraryWritable, .idle)
            update(.libraryReopens, .idle)
            update(.librarySynced, .idle)
            return
        }

        let root = layout.root
        update(.libraryOpen, .pass(root.path))

        switch SystemChecks.probeWritable(root) {
        case .writable:
            update(.libraryWritable, .pass(String(localized: "Aigle can write to this folder.")))
        case .notWritable(let reason):
            update(.libraryWritable, .fail(reason))
        }

        switch SystemChecks.bookmarkHealth(key: BookmarkStore.key(forLibraryAt: root)) {
        case .healthy:
            update(.libraryReopens, .pass(String(localized: "Aigle will reopen this library on launch.")))
        case .missing:
            update(.libraryReopens, .warn(String(localized: "Permission wasn’t saved — reopen the library to fix.")))
        case .unresolvable(let reason):
            update(.libraryReopens, .fail(reason))
        case .targetGone(let path):
            update(.libraryReopens, .fail(String(localized: "The folder at \(path) is no longer there.")))
        }

        if let provider = SystemChecks.syncProvider(for: root) {
            update(.librarySynced, .pass(String(localized: "Stored in \(provider).")))
        } else {
            update(.librarySynced, .warn(String(localized: "Stored on this Mac only — that’s fine, but it won’t follow you.")))
        }
    }

    private func refreshPortCheck(settings: AppSettings, server: ExtensionServer) {
        let port = settings.extensionPort
        if case .running(let live) = server.state, Int(live) == port {
            update(.extensionPort, .pass(String(localized: "Listening on 127.0.0.1:\(String(port)).")))
            return
        }
        if case .failed(let reason) = server.state {
            update(.extensionPort, .fail(reason))
            return
        }
        if SystemChecks.isPortAvailable(port) {
            update(.extensionPort, settings.extensionServerEnabled
                ? .warn(String(localized: "Port \(String(port)) is free; the listener hasn’t started yet."))
                : .pass(String(localized: "Port \(String(port)) is free when you turn the Chrome bridge on.")))
        } else {
            update(.extensionPort, .warn(String(localized: "Port \(String(port)) is already taken — pick another in Settings.")))
        }
    }

    private func refreshQuickAccessCheck() {
        let granted = quickAccess.filter(\.isGranted).count
        if granted == 0 {
            update(.quickAccess, .warn(String(localized: "No folders pre-authorised — you can still add them any time.")))
        } else {
            update(.quickAccess, .pass(String(localized: "\(String(granted)) folder(s) ready to connect.")))
        }
    }

    private func refreshSafariCheck() async {
        switch await SystemChecks.safariExtensionState() {
        case .enabled:
            update(.safariExtension, .pass(String(localized: "Enabled in Safari.")))
        case .disabled:
            update(.safariExtension, .warn(String(localized: "Built in, but switched off in Safari’s settings.")))
        case .unavailable(let reason):
            let hint = SystemChecks.isRunningFromApplications
                ? reason
                : String(localized: "Move Aigle to /Applications so Safari can see the extension.")
            update(.safariExtension, .warn(hint))
        }
    }

    // MARK: - Quick access folders

    private static func suggestedFolders() -> [QuickAccessFolder] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(String, String, String)] = [
            ("Downloads", "Downloads", "arrow.down.circle"),
            ("Desktop", "Desktop", "menubar.dock.rectangle"),
            ("Pictures", "Pictures", "photo.on.rectangle"),
            ("Documents", "Documents", "doc"),
            ("Movies", "Movies", "film"),
        ]
        return candidates.compactMap { component, name, symbol in
            let url = home.appending(path: component, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return QuickAccessFolder(url: url, name: name, symbol: symbol)
        }
    }

    public func refreshQuickAccess() {
        for index in quickAccess.indices {
            let key = quickAccess[index].bookmarkKey
            if case .healthy = SystemChecks.bookmarkHealth(key: key) {
                quickAccess[index].isGranted = true
            } else {
                quickAccess[index].isGranted = false
            }
        }
    }

    /// Records the grant the user just made in the open panel. The URL is scoped,
    /// so the bookmark has to be taken while access is held.
    public func grantQuickAccess(to url: URL) {
        let key = BookmarkStore.key(forFolderAt: url)
        _ = SystemChecks.withAccess(to: url) { scoped in
            BookmarkStore.store(scoped, key: key)
        }
        if let index = quickAccess.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            quickAccess[index].isGranted = BookmarkStore.hasBookmark(key: key)
        } else {
            var folder = QuickAccessFolder(
                url: url,
                name: url.lastPathComponent,
                symbol: "folder"
            )
            folder.isGranted = BookmarkStore.hasBookmark(key: key)
            quickAccess.append(folder)
        }
        refreshQuickAccessCheck()
    }

    public func revokeQuickAccess(_ folder: QuickAccessFolder) {
        BookmarkStore.remove(key: folder.bookmarkKey)
        refreshQuickAccess()
        refreshQuickAccessCheck()
    }

    // MARK: - Template

    private static var template: [SetupCheck] {
        [
            SetupCheck(
                id: .libraryOpen,
                title: "Library chosen",
                explanation: "Aigle keeps everything in one plain folder you pick.",
                symbol: "books.vertical",
                weight: .required
            ),
            SetupCheck(
                id: .libraryWritable,
                title: "Write permission",
                explanation: "Verified by actually writing a file — the sandbox only admits the truth when you try.",
                symbol: "square.and.pencil",
                weight: .required
            ),
            SetupCheck(
                id: .libraryReopens,
                title: "Permission remembered",
                explanation: "A security-scoped bookmark, so the library reopens by itself next launch.",
                symbol: "bookmark",
                weight: .required
            ),
            SetupCheck(
                id: .librarySynced,
                title: "Storage location",
                explanation: "iCloud Drive, Dropbox, or an external drive means the library follows you.",
                symbol: "icloud",
                weight: .optional
            ),
            SetupCheck(
                id: .quickAccess,
                title: "Folder access",
                explanation: "Pre-authorise the folders you collect from so connecting them is one click.",
                symbol: "folder.badge.person.crop",
                weight: .optional
            ),
            SetupCheck(
                id: .extensionPort,
                title: "Local port",
                explanation: "The Chrome bridge listens on 127.0.0.1 only, and never leaves this Mac.",
                symbol: "network",
                weight: .optional
            ),
            SetupCheck(
                id: .safariExtension,
                title: "Safari extension",
                explanation: "Built into Aigle — no separate install, just switch it on.",
                symbol: "safari",
                weight: .recommended
            ),
        ]
    }
}
