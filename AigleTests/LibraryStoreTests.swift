import AppKit
import Foundation
import Testing

@testable import Aigle

/// Builds a throwaway library plus some real image files on disk.
struct Fixture {
    let root: URL
    let scratch: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "aigle-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "Test.library", directoryHint: .isDirectory)
        scratch = base.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try LibraryLayout(root: root).createSkeleton()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// Writes a real PNG so dimension probing and thumbnailing have something to chew on.
    @discardableResult
    func makePNG(named name: String, width: Int, height: Int, tint: NSColor = .systemBlue) throws -> URL {
        let url = scratch.appending(path: "\(name).png")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        tint.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: url)
        return url
    }
}

@Suite("Library store", .serialized)
struct LibraryStoreTests {

    @Test("A new library has the Eagle folder skeleton")
    func skeleton() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let layout = LibraryLayout(root: fixture.root)
        #expect(LibraryLayout.isLibrary(fixture.root))
        #expect(FileManager.default.fileExists(atPath: layout.metadataURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.tagsURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.imagesURL.path))
    }

    @Test("Importing writes Eagle-shaped metadata and a thumbnail")
    func importWritesEagleLayout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makePNG(named: "swatch", width: 400, height: 200)

        let store = LibraryStore(layout: LibraryLayout(root: fixture.root))
        _ = try await store.open()
        let result = await store.importFiles([source], into: nil, allowVirtualCopies: true)

        let item = try #require(result.imported.first)
        #expect(item.name == "swatch")
        #expect(item.ext == "png")
        #expect(item.width == 400)
        #expect(item.height == 200)

        let layout = LibraryLayout(root: fixture.root)
        #expect(FileManager.default.fileExists(atPath: layout.itemMetadataURL(item.id).path))
        #expect(FileManager.default.fileExists(atPath: layout.fileURL(for: item).path))
        #expect(FileManager.default.fileExists(atPath: layout.thumbnailURL(for: item).path))

        // And it reads back as a valid Eagle item.
        let onDisk = try EagleCodec.decodeItem(try Data(contentsOf: layout.itemMetadataURL(item.id)))
        #expect(onDisk.id == item.id)
        #expect(onDisk.width == 400)
    }

    @Test("Re-importing the same bytes creates a virtual copy, not a duplicate file")
    func virtualCopies() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makePNG(named: "logo", width: 128, height: 128)

        let store = LibraryStore(layout: LibraryLayout(root: fixture.root))
        _ = try await store.open()
        let first = await store.importFiles([source], into: nil, allowVirtualCopies: true)
        let second = await store.importFiles([source], into: nil, allowVirtualCopies: true)

        let original = try #require(first.imported.first)
        let copy = try #require(second.imported.first)
        #expect(original.id != copy.id)
        #expect(copy.aigle.virtualCopyOf == original.id)

        let layout = LibraryLayout(root: fixture.root)
        // The copy's own directory holds metadata only — the bytes stay in the original.
        #expect(FileManager.default.fileExists(atPath: layout.itemMetadataURL(copy.id).path))
        #expect(!FileManager.default.fileExists(atPath: layout.itemDirectory(copy.id).appending(path: copy.fileName).path))
        #expect(layout.fileURL(for: copy) == layout.fileURL(for: original))
    }

    @Test("Disabling virtual copies stores the bytes twice")
    func duplicatesWhenVirtualCopiesOff() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makePNG(named: "dup", width: 64, height: 64)

        let store = LibraryStore(layout: LibraryLayout(root: fixture.root))
        _ = try await store.open()
        _ = await store.importFiles([source], into: nil, allowVirtualCopies: false)
        let second = await store.importFiles([source], into: nil, allowVirtualCopies: false)
        let copy = try #require(second.imported.first)
        #expect(copy.aigle.virtualCopyOf == nil)
        let layout = LibraryLayout(root: fixture.root)
        #expect(FileManager.default.fileExists(atPath: layout.itemDirectory(copy.id).appending(path: copy.fileName).path))
    }

    @Test("Trash is a soft delete that survives reopening")
    func trashRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makePNG(named: "doomed", width: 32, height: 32)

        let store = LibraryStore(layout: LibraryLayout(root: fixture.root))
        _ = try await store.open()
        let imported = try #require((await store.importFiles([source], into: nil, allowVirtualCopies: true)).imported.first)

        _ = await store.moveToTrash(ids: [imported.id])
        await store.save()

        let reopened = LibraryStore(layout: LibraryLayout(root: fixture.root))
        let snapshot = try await reopened.open()
        let restored = try #require(snapshot.items.first { $0.id == imported.id })
        #expect(restored.isDeleted)

        _ = await reopened.restore(ids: [imported.id])
        #expect(await reopened.item(imported.id)?.isDeleted == false)

        _ = await reopened.moveToTrash(ids: [imported.id])
        _ = await reopened.emptyTrash()
        #expect(await reopened.item(imported.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: LibraryLayout(root: fixture.root).itemDirectory(imported.id).path))
    }

    @Test("Collections nest, rename, and carry their items")
    func collections() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makePNG(named: "filed", width: 40, height: 60)

        let store = LibraryStore(layout: LibraryLayout(root: fixture.root))
        _ = try await store.open()
        let (_, parent) = await store.createCollection(named: "Brand", parent: nil)
        let (_, child) = await store.createCollection(named: "Logos", parent: parent)
        let item = try #require((await store.importFiles([source], into: child, allowVirtualCopies: true)).imported.first)

        var snapshot = await store.snapshot()
        #expect(snapshot.collections.find(parent)?.children.first?.id == child)
        #expect(snapshot.items.first { $0.id == item.id }?.folders == [child])

        snapshot = await store.renameCollection(child, to: "Marks")
        #expect(snapshot.collections.find(child)?.name == "Marks")

        snapshot = await store.deleteCollection(parent)
        #expect(snapshot.collections.find(child) == nil)
        #expect(snapshot.items.first { $0.id == item.id }?.folders.isEmpty == true)
    }

    @Test("Renaming moves the file and follows every virtual copy")
    func renamePropagates() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makePNG(named: "before", width: 20, height: 20)

        let store = LibraryStore(layout: LibraryLayout(root: fixture.root))
        _ = try await store.open()
        let original = try #require((await store.importFiles([source], into: nil, allowVirtualCopies: true)).imported.first)
        let copy = try #require((await store.importFiles([source], into: nil, allowVirtualCopies: true)).imported.first)

        _ = await store.rename(original.id, to: "after")
        let renamed = try #require(await store.item(original.id))
        let renamedCopy = try #require(await store.item(copy.id))
        #expect(renamed.name == "after")
        #expect(renamedCopy.name == "after")
        #expect(FileManager.default.fileExists(atPath: LibraryLayout(root: fixture.root).fileURL(for: renamed).path))
    }

    @Test("Tags are recorded on items and in tags.json")
    func tags() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makePNG(named: "tagged", width: 10, height: 10)

        let store = LibraryStore(layout: LibraryLayout(root: fixture.root))
        _ = try await store.open()
        let item = try #require((await store.importFiles([source], into: nil, allowVirtualCopies: true)).imported.first)

        let snapshot = await store.addTags(["blue", "swatch"], ids: [item.id])
        #expect(snapshot.tags.contains("blue"))
        #expect(await store.item(item.id)?.tags == ["blue", "swatch"])

        let tagsData = try Data(contentsOf: LibraryLayout(root: fixture.root).tagsURL)
        let tagsFile = try JSONDecoder().decode(TagsFile.self, from: tagsData)
        #expect(tagsFile.historyTags.contains("swatch"))
    }

    @Test("The persisted index makes reopening produce the same items")
    func persistedIndex() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for index in 0..<5 {
            _ = try fixture.makePNG(named: "img\(index)", width: 30 + index, height: 30)
        }
        let sources = try FileManager.default.contentsOfDirectory(at: fixture.scratch, includingPropertiesForKeys: nil)

        let store = LibraryStore(layout: LibraryLayout(root: fixture.root))
        _ = try await store.open()
        _ = await store.importFiles(sources, into: nil, allowVirtualCopies: false)
        await store.save()

        #expect(FileManager.default.fileExists(atPath: LibraryLayout(root: fixture.root).indexURL.path))

        let reopened = LibraryStore(layout: LibraryLayout(root: fixture.root))
        let snapshot = try await reopened.open()
        #expect(snapshot.items.count == 5)
    }

    @Test("Opening a folder that isn't a library fails cleanly")
    func rejectsNonLibrary() async throws {
        let stray = FileManager.default.temporaryDirectory.appending(path: "aigle-not-a-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stray) }
        let store = LibraryStore(layout: LibraryLayout(root: stray))
        await #expect(throws: EagleCodecError.self) {
            _ = try await store.open()
        }
    }
}
