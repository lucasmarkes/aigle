import Foundation
import Testing

@testable import Aigle

/// The 50 000-item pass from the plan.
///
/// It builds a real on-disk library — one `images/<id>.info/metadata.json` per
/// item, exactly as Eagle writes them — then measures the four things a user
/// actually feels: launch, full reconcile, laying out the grid, and search.
///
/// Skipped by default because building the fixture takes a while. Run it with:
///
///     AIGLE_PERF=1 xcodebuild -project Aigle.xcodeproj -scheme Aigle test \
///       -only-testing:AigleTests/PerformanceSuite
@Suite("PerformanceSuite", .enabled(if: ProcessInfo.processInfo.environment["AIGLE_PERF"] != nil), .serialized)
struct PerformanceSuite {
    static let itemCount = 50_000

    static func buildFixture(at root: URL) throws {
        let layout = LibraryLayout(root: root)
        try layout.createSkeleton()

        let words = ["sunset", "logo", "poster", "screenshot", "texture", "portrait", "icon", "mockup", "chart", "sketch"]
        let extensions = ["png", "jpg", "gif", "svg", "pdf", "mp4"]
        let encoder = JSONEncoder()
        let fm = FileManager.default

        // Deterministic-ish spread so aspect ratios and names vary realistically.
        for index in 0..<itemCount {
            let id = String(format: "PERF%09d", index)
            let word = words[index % words.count]
            let ext = extensions[index % extensions.count]
            let width = 400 + (index * 37) % 2400
            let height = 300 + (index * 53) % 1800
            var item = Item(
                id: id,
                name: "\(word)-\(index)",
                ext: ext,
                size: 10_000 + index,
                btime: 1_700_000_000_000 + index * 1000,
                mtime: 1_700_000_000_000 + index * 1000,
                modificationTime: 1_700_000_000_000 + index * 1000,
                width: width,
                height: height,
                tags: index % 7 == 0 ? [word, "batch\(index % 20)"] : [],
                aigle: AigleExtras(liked: index % 23 == 0, kind: ItemKind.infer(ext: ext))
            )
            item.noThumbnail = true

            let dir = layout.itemDirectory(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder.encode(EagleCodec.encodeItem(item))
            try data.write(to: dir.appending(path: "metadata.json"), options: .atomic)
        }
    }

    static func measure(_ label: String, _ body: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await body()
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        print("⏱  \(label): \(String(format: "%.3f", seconds))s")
        return seconds
    }

    @Test("50K items: launch, reconcile, layout and search stay snappy")
    func fiftyThousandItems() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "aigle-perf/Perf.library", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        _ = try await Self.measure("build fixture (\(Self.itemCount) items)") {
            try Self.buildFixture(at: root)
        }

        // Cold open: no index yet, so this is the full directory scan.
        let store = LibraryStore(layout: LibraryLayout(root: root))
        var snapshot = LibrarySnapshot.empty()
        let coldOpen = try await Self.measure("cold open (full scan + index write)") {
            snapshot = try await store.open()
        }
        #expect(snapshot.items.count == Self.itemCount)

        // Warm open: the persisted index is what makes launch → pixels instant.
        let warm = LibraryStore(layout: LibraryLayout(root: root))
        var warmSnapshot = LibrarySnapshot.empty()
        let warmOpen = try await Self.measure("warm open (persisted index)") {
            warmSnapshot = try await warm.open()
        }
        #expect(warmSnapshot.items.count == Self.itemCount)
        #expect(warmOpen < coldOpen)
        #expect(warmOpen < 3.0, "launching into a 50K library should not take seconds")

        // Laying out the grid happens on every scroll tick and zoom step.
        let items = warmSnapshot.items.sorted { $0.btime > $1.btime }
        var layout = JustifiedLayout.empty
        let layoutTime = await Self.measure("justified layout of 50K items") {
            layout = JustifiedLayoutEngine.compute(items: items, width: 1400, targetHeight: 220, spacing: 8)
        }
        #expect(layout.frames.count == Self.itemCount)
        #expect(layoutTime < 1.0)

        // ⌘K has to feel like typing, not like waiting.
        var hits: [Item] = []
        let searchTime = await Self.measure("⌘K search over 50K items") {
            hits = SearchMatcher.rank(items, query: "poster")
        }
        #expect(!hits.isEmpty)
        #expect(searchTime < 1.0)

        // Filtering a smart section is what the sidebar does on every click.
        let likesTime = await Self.measure("filter Likes") {
            _ = items.filter(\.liked)
        }
        #expect(likesTime < 0.2)
    }
}
