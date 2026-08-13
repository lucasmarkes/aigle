import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Aigle

/// Imported files must keep every pixel they arrived with, and the detail view
/// must decode from the original rather than from the small `_thumbnail.png`
/// sidecar. The sidecar used to satisfy *any* request whose longest side was 320
/// or more, so opening an image full-screen showed a ~512px preview stretched
/// across the window while the untouched original sat on disk.
@Suite("Imported image quality")
@MainActor
struct ImageQualityTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "aigle-quality-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A PNG with enough detail that downscaling is measurable.
    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for x in stride(from: 0, to: width, by: 8) {
            NSColor(calibratedHue: Double(x) / Double(width), saturation: 1, brightness: 1, alpha: 1).setFill()
            NSRect(x: x, y: 0, width: 4, height: height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: url)
    }

    @Test("The imported file is byte-for-byte the original")
    func originalBytesArePreserved() async throws {
        let scratch = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appending(path: "Wide.png")
        try writePNG(width: 3000, height: 2000, to: source)
        let originalBytes = try Data(contentsOf: source)

        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let controller = LibraryController()
        await controller.createLibrary(named: "Quality", in: parent)
        try #require(controller.isOpen)
        defer { controller.closeLibrary() }

        await controller.importFiles([source], into: nil).value

        let item = try #require(controller.liveItems.first)
        #expect(item.width == 3000)
        #expect(item.height == 2000)

        let stored = try #require(controller.fileURL(for: item))
        #expect(try Data(contentsOf: stored) == originalBytes)
    }

    @Test("The detail view decodes near the original's resolution, not the preview")
    func detailUsesFullResolution() async throws {
        let scratch = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appending(path: "Wide.png")
        try writePNG(width: 3000, height: 2000, to: source)

        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let controller = LibraryController()
        await controller.createLibrary(named: "Quality", in: parent)
        try #require(controller.isOpen)
        defer { controller.closeLibrary() }

        await controller.importFiles([source], into: nil).value
        let item = try #require(controller.liveItems.first)
        await ThumbnailPipeline.shared.setLibraryLayout(controller.snapshot?.layout)

        let full = try #require(await ThumbnailPipeline.shared.thumbnail(for: item, size: .full))
        // Before the fix this came back at the sidecar's size (~512px).
        #expect(full.width == 3000)
        #expect(full.height == 2000)

        // The grid keeps using the cheap preview — no 3000px decodes per cell.
        let cell = try #require(await ThumbnailPipeline.shared.thumbnail(for: item, size: .small))
        #expect(cell.width <= ThumbnailSize.small.rawValue)
    }

    @Test("A small original is never upscaled")
    func smallOriginalsStayNative() async throws {
        let scratch = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appending(path: "Tiny.png")
        try writePNG(width: 240, height: 160, to: source)

        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let controller = LibraryController()
        await controller.createLibrary(named: "Tiny", in: parent)
        try #require(controller.isOpen)
        defer { controller.closeLibrary() }

        await controller.importFiles([source], into: nil).value
        let item = try #require(controller.liveItems.first)
        await ThumbnailPipeline.shared.setLibraryLayout(controller.snapshot?.layout)

        let full = try #require(await ThumbnailPipeline.shared.thumbnail(for: item, size: .full))
        #expect(full.width == 240)
        #expect(full.height == 160)
    }

    @Test("Grid buckets never reach the full-resolution tier")
    func gridNeverAsksForFull() {
        for points in [80.0, 200.0, 400.0, 900.0, 2000.0] {
            let bucket = ThumbnailSize.bucket(for: points)
            #expect(bucket != .full, "a \(points)pt cell should not decode at full size")
        }
    }
}
