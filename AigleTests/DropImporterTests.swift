import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Aigle

/// Regression cover for drops that carry no file URL at all.
///
/// Screen recorders and screenshot tools (CleanShot X among them) hand a drag
/// over as a *promise*: the provider advertises the clip's content type and
/// writes the bytes only when the receiver asks. Aigle used to test solely for
/// `public.file-url` and a handful of still-image data types, so a dropped
/// recording matched nothing and vanished without a word.
@Suite("Dropping promised files")
@MainActor
struct DropImporterTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "aigle-drop-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A provider that only fulfils a file when asked — the shape a recorder's
    /// drag arrives in.
    private func promiseProvider(named name: String, type: UTType, bytes: Data) throws -> (NSItemProvider, URL) {
        let directory = try temporaryDirectory()
        let source = directory.appending(path: name)
        try bytes.write(to: source)

        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(source, false, nil)
            return nil
        }
        return (provider, directory)
    }

    @Test("A promised movie is staged to a real file on disk")
    func promisedMovieIsStaged() async throws {
        let bytes = Data("pretend-quicktime-bytes".utf8)
        let (provider, source) = try promiseProvider(named: "Recording.mov", type: .quickTimeMovie, bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }

        // The old code path: this is what used to be the only check.
        #expect(await DropImporter.loadFileURL(provider) == nil)

        let staged = try #require(await DropImporter.loadPromisedFile(provider))
        defer { DropImporter.discardStaged([staged]) }

        #expect(staged.pathExtension.lowercased() == "mov")
        #expect(try Data(contentsOf: staged) == bytes)
    }

    @Test("A movie carried as raw data is written out under the right extension")
    func movieDataIsStaged() async throws {
        let bytes = Data("pretend-mp4-bytes".utf8)
        let provider = NSItemProvider()
        provider.suggestedName = "Screen Recording"
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.mpeg4Movie.identifier,
            visibility: .all
        ) { completion in
            completion(bytes, nil)
            return nil
        }

        let staged = try #require(await DropImporter.loadMediaData(provider))
        defer { DropImporter.discardStaged([staged]) }

        #expect(staged.pathExtension.lowercased() == "mp4")
        #expect(staged.deletingPathExtension().lastPathComponent == "Screen Recording")
        #expect(try Data(contentsOf: staged) == bytes)
    }

    @Test("Movies are accepted by the drop destination's type list")
    func movieTypesAreAccepted() {
        let accepted = DropImporter.acceptedTypes
        for type in [UTType.quickTimeMovie, .mpeg4Movie, .movie] {
            #expect(
                accepted.contains { type.conforms(to: $0) || type == $0 },
                "\(type.identifier) should be accepted"
            )
        }
    }

    @Test("Link drags are never mistaken for files to copy")
    func linksAreNotFiles() {
        let provider = NSItemProvider(object: URL(string: "https://example.com/page")! as NSURL)
        #expect(DropImporter.fileTypeIdentifiers(of: provider).isEmpty)
    }

    @Test("Staged files are cleaned up, folder and all")
    func stagingIsCleanedUp() throws {
        let staged = try #require(DropImporter.stage(Data("x".utf8), name: "Temp", ext: "png"))
        let folder = staged.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: staged.path))

        DropImporter.discardStaged([staged])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// End to end: a promised recording dropped on a real library becomes an item.
    @Test("Dropping a promised recording puts an item in the library")
    func promisedDropLandsInLibrary() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let controller = LibraryController()
        await controller.createLibrary(named: "Drops", in: parent)
        try #require(controller.isOpen)
        defer { controller.closeLibrary() }

        let bytes = Data("pretend-quicktime-bytes".utf8)
        let (provider, source) = try promiseProvider(named: "CleanShot.mov", type: .quickTimeMovie, bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }

        await DropImporter.ingest(providers: [provider], into: nil, controller: controller)

        let imported = controller.liveItems
        #expect(imported.count == 1)
        #expect(imported.first?.ext == "mov")
        #expect(imported.first?.name == "CleanShot")

        // Staging is temporary; the bytes must now live in the library itself.
        let stored = try #require(imported.first.flatMap(controller.fileURL(for:)))
        #expect(try Data(contentsOf: stored) == bytes)
        let stagingLeftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: DropImporter.stagingRoot.path
        )) ?? []
        #expect(stagingLeftovers.isEmpty)
    }

    @Test("A drop Aigle can't read says so instead of failing silently")
    func unreadableDropReportsBack() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let controller = LibraryController()
        await controller.createLibrary(named: "Quiet", in: parent)
        try #require(controller.isOpen)
        defer { controller.closeLibrary() }

        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: "com.example.unknown-format",
            visibility: .all
        ) { completion in
            completion(Data("?".utf8), nil)
            return nil
        }

        await DropImporter.ingest(providers: [provider], into: nil, controller: controller)

        #expect(controller.liveItems.isEmpty)
        #expect(controller.importStatus != nil)
    }
}
