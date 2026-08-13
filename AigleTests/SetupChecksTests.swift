import Foundation
import Testing

@testable import Aigle

@Suite("Permission probes")
struct SystemChecksTests {

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "aigle-checks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A writable folder probes as writable")
    func writableFolder() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(SystemChecks.probeWritable(directory) == .writable)
    }

    @Test("The probe leaves nothing behind")
    func probeCleansUp() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = SystemChecks.probeWritable(directory)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }

    /// The whole point of probing rather than trusting `isWritableFile`: a
    /// directory the process genuinely cannot write to has to come back as a
    /// failure, with the reason attached.
    @Test("A read-only folder probes as not writable")
    func readOnlyFolder() throws {
        let directory = try scratchDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        guard case .notWritable(let reason) = SystemChecks.probeWritable(directory) else {
            Issue.record("Expected a read-only directory to fail the write probe")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("An unknown bookmark reports as missing, not healthy")
    func missingBookmark() {
        #expect(SystemChecks.bookmarkHealth(key: "library:/nowhere-\(UUID().uuidString)") == .missing)
    }

    @Test("A free port is reported available, a taken one is not")
    func portProbe() throws {
        // Pick a high port, then hold it open and confirm the probe notices.
        let port = Int.random(in: 49_200...49_900)
        #expect(SystemChecks.isPortAvailable(port))

        let holder = socket(AF_INET, SOCK_STREAM, 0)
        try #require(holder >= 0)
        defer { close(holder) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)

        #expect(!SystemChecks.isPortAvailable(port))
    }

    @Test("Out-of-range ports are never reported available")
    func invalidPort() {
        #expect(!SystemChecks.isPortAvailable(0))
        #expect(!SystemChecks.isPortAvailable(70_000))
    }

    @Test("Sync providers are recognised from the path")
    func syncProviders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Aigle.library")
        #expect(SystemChecks.syncProvider(for: iCloud) == "iCloud Drive")

        let dropbox = home.appending(path: "Library/CloudStorage/Dropbox/Aigle.library")
        #expect(SystemChecks.syncProvider(for: dropbox) == "Dropbox")

        #expect(SystemChecks.syncProvider(for: URL(fileURLWithPath: "/Volumes/Slab/Aigle.library")) != nil)
        #expect(SystemChecks.syncProvider(for: home.appending(path: "Aigle.library")) == nil)
    }
}

@Suite("Library creation holds the parent's scope")
@MainActor
struct LibraryCreationTests {

    /// The regression this covers: creating a library used to write straight
    /// into the picked folder without holding its security scope, which the
    /// sandbox rejected with "You don't have permission to save the file…".
    @Test("Creating a library builds the skeleton and opens it")
    func createsAndOpens() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "aigle-create-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let controller = LibraryController()
        await controller.createLibrary(named: "Test Library", in: parent)

        #expect(controller.loadError == nil)
        #expect(controller.isOpen)

        let root = parent.appending(path: "Test Library.library")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "metadata.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "images").path))

        controller.closeLibrary()
    }

    @Test("A blank name still produces a usable library")
    func blankNameFallsBack() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "aigle-create-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let controller = LibraryController()
        await controller.createLibrary(named: "   ", in: parent)

        #expect(controller.isOpen)
        #expect(FileManager.default.fileExists(atPath: parent.appending(path: "Aigle.library").path))

        controller.closeLibrary()
    }

    @Test("Creating over an existing library reports it instead of clobbering it")
    func refusesToOverwrite() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "aigle-create-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let controller = LibraryController()
        await controller.createLibrary(named: "Twice", in: parent)
        controller.closeLibrary()

        let second = LibraryController()
        await second.createLibrary(named: "Twice", in: parent)
        #expect(second.loadError != nil)
        #expect(!second.isOpen)
    }
}

@Suite("Setup assistant state")
@MainActor
struct SetupModelTests {

    private func freshModel() -> SetupModel {
        for key in ["aigle.setup.stage", "aigle.setup.finished", "aigle.setup.seenStages"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return SetupModel()
    }

    @Test("Setup starts at the welcome step and walks forward")
    func advances() {
        let setup = freshModel()
        #expect(setup.stage == .welcome)
        setup.advance()
        #expect(setup.stage == .library)
        #expect(setup.direction == 1)
    }

    @Test("Going back reverses the transition direction")
    func retreats() {
        let setup = freshModel()
        setup.advance()
        setup.retreat()
        #expect(setup.stage == .welcome)
        #expect(setup.direction == -1)
        #expect(!setup.canRetreat)
    }

    /// "Persistent" means a quit halfway through resumes where it left off.
    @Test("The current step survives a relaunch")
    func persistsStage() {
        let setup = freshModel()
        setup.go(to: .permissions)

        let relaunched = SetupModel()
        #expect(relaunched.stage == .permissions)
        #expect(relaunched.hasSeen(.welcome) || relaunched.hasSeen(.library))
    }

    @Test("Finishing is remembered, and setup stops taking over the window")
    func persistsCompletion() {
        let setup = freshModel()
        #expect(setup.isActive(libraryOpen: true))
        setup.finish()

        let relaunched = SetupModel()
        #expect(relaunched.hasFinished)
        #expect(!relaunched.isActive(libraryOpen: true))
        // …but a library that no longer opens brings it straight back.
        #expect(relaunched.isActive(libraryOpen: false))
    }

    @Test("Reopening from the Help menu returns to the start")
    func reopen() {
        let setup = freshModel()
        setup.finish()
        setup.reopen()
        #expect(setup.stage == .welcome)
        #expect(setup.isActive(libraryOpen: true))
    }

    @Test("The library step is a gate; the rest are not")
    func libraryGate() {
        let setup = freshModel()
        setup.go(to: .library)
        #expect(!setup.canAdvance(libraryOpen: false))
        #expect(setup.canAdvance(libraryOpen: true))

        setup.go(to: .browser)
        #expect(setup.canAdvance(libraryOpen: false))
    }

    @Test("Losing the library walks back to the step that fixes it")
    func gateWalksBack() {
        let setup = freshModel()
        setup.go(to: .browser)
        setup.enforceLibraryGate(libraryOpen: true)
        #expect(setup.stage == .browser)

        setup.enforceLibraryGate(libraryOpen: false)
        #expect(setup.stage == .library)

        // Already at or before the gate: nothing moves.
        setup.go(to: .welcome)
        setup.enforceLibraryGate(libraryOpen: false)
        #expect(setup.stage == .welcome)
    }

    @Test("With no library open, the required checks fail rather than pass quietly")
    func failsWithoutLibrary() async {
        let setup = freshModel()
        await setup.refresh(
            controller: LibraryController(),
            settings: AppSettings.shared,
            server: ExtensionServer()
        )
        #expect(setup.check(.libraryOpen)?.status.isFail == true)
        #expect(!setup.blockingFailures.isEmpty)
    }
}
