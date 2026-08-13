import Foundation
import Testing

@testable import Aigle

@Suite("Search matching")
struct SearchMatcherTests {
    private func item(_ name: String, tags: [String] = [], ext: String = "png") -> Item {
        Item(name: name, ext: ext, tags: tags)
    }

    @Test("Exact and prefix matches outrank everything else")
    func ranking() {
        let candidates = [
            item("big-green-logo"),
            item("logo"),
            item("company logotype"),
        ]
        let ranked = SearchMatcher.rank(candidates, query: "logo")
        #expect(ranked.first?.name == "logo")
        #expect(ranked.count == 3)
    }

    @Test("Fuzzy subsequence matching finds initials")
    func fuzzy() {
        #expect(SearchMatcher.matches(item("big-green-logo"), query: "bgl"))
        #expect(!SearchMatcher.matches(item("big-green-logo"), query: "zzz"))
    }

    @Test("Tags are searchable")
    func tags() {
        let tagged = item("IMG_0042", tags: ["moodboard"])
        #expect(SearchMatcher.matches(tagged, query: "mood"))
    }

    @Test("Matching ignores case and diacritics")
    func folding() {
        #expect(SearchMatcher.matches(item("Café Façade"), query: "cafe"))
        #expect(SearchMatcher.matches(item("Café Façade"), query: "FACADE"))
    }

    @Test("An empty query matches nothing in the palette")
    func emptyQuery() {
        #expect(SearchMatcher.rank([item("a")], query: "   ").isEmpty)
    }
}

@Suite("Justified grid layout")
struct JustifiedLayoutTests {
    private func items(_ aspects: [CGFloat]) -> [Item] {
        aspects.enumerated().map { index, aspect in
            Item(
                id: "ID\(index)",
                name: "item\(index)",
                ext: "png",
                width: Int(aspect * 1000),
                height: 1000
            )
        }
    }

    @Test("Justified rows fill the container width exactly")
    func rowsFillWidth() {
        let layout = JustifiedLayoutEngine.compute(
            items: items([1.5, 1.0, 0.8, 1.2, 1.6, 0.9, 1.1, 1.4]),
            width: 900,
            targetHeight: 200,
            spacing: 8
        )
        #expect(!layout.rows.isEmpty)
        // Every row except the trailing partial one ends flush with the container.
        for row in layout.rows.dropLast() {
            let last = row.cells[row.cells.count - 1]
            #expect(abs(last.x + last.width - 900) < 0.5)
        }
    }

    @Test("Every item gets a frame for rubber-band hit testing")
    func framesCoverEveryItem() {
        let source = items([1.5, 1.0, 0.8, 1.2, 1.6])
        let layout = JustifiedLayoutEngine.compute(items: source, width: 600, targetHeight: 150, spacing: 6)
        #expect(layout.frames.count == source.count)
        #expect(layout.contentHeight > 0)
    }

    @Test("Extreme aspect ratios are clamped so one panorama can't wreck a row")
    func clampsAspect() {
        let panorama = Item(name: "pano", ext: "jpg", width: 10000, height: 200)
        #expect(JustifiedLayoutEngine.clampedAspect(panorama) == 4.0)
        let strip = Item(name: "strip", ext: "jpg", width: 100, height: 10000)
        #expect(JustifiedLayoutEngine.clampedAspect(strip) == 0.28)
        let unknown = Item(name: "unknown", ext: "jpg")
        #expect(JustifiedLayoutEngine.clampedAspect(unknown) == 1)
    }

    @Test("No items means no layout, not a crash")
    func emptyLayout() {
        let layout = JustifiedLayoutEngine.compute(items: [], width: 800, targetHeight: 200, spacing: 8)
        #expect(layout.rows.isEmpty)
        #expect(layout.contentHeight == 0)
    }
}

@Suite("Link metadata scraping")
struct LinkFetcherTests {
    static let html = """
    <!doctype html><html><head>
    <title>Fallback &amp; Title</title>
    <meta property="og:title" content="Real Title">
    <meta property="og:image" content="/preview.png">
    <link rel="apple-touch-icon" href="https://cdn.example.com/icon.png">
    </head><body></body></html>
    """

    @Test("og:title wins over <title>")
    func title() {
        #expect(LinkFetcher.metaContent(in: Self.html, property: "og:title") == "Real Title")
        #expect(LinkFetcher.firstMatch(in: Self.html, pattern: "<title[^>]*>([\\s\\S]*?)</title>") == "Fallback &amp; Title")
    }

    @Test("og:image and icon links are extracted")
    func images() {
        #expect(LinkFetcher.metaContent(in: Self.html, property: "og:image") == "/preview.png")
        #expect(LinkFetcher.linkHref(in: Self.html, rel: "apple-touch-icon") == "https://cdn.example.com/icon.png")
    }

    @Test("HTML entities are decoded")
    func entities() {
        #expect(LinkFetcher.decodeEntities("A &amp; B &mdash; C") == "A & B — C")
    }
}

@Suite("Identifiers and hashing")
struct IdentifierTests {
    @Test("Generated ids look like Eagle's")
    func generated() {
        let id = EagleID.generate()
        #expect(id.count == 13)
        #expect(id.allSatisfy { $0.isUppercase || $0.isNumber })
    }

    @Test("Path-derived ids are stable")
    func derived() {
        let a = EagleID.derived(from: "/Users/x/Pictures/one.png")
        let b = EagleID.derived(from: "/Users/x/Pictures/one.png")
        let c = EagleID.derived(from: "/Users/x/Pictures/two.png")
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 13)
    }

    @Test("Identical bytes hash identically")
    func contentHash() {
        let data = Data(repeating: 7, count: 4096)
        #expect(ContentHash.hash(of: data) == ContentHash.hash(of: data))
        #expect(ContentHash.hash(of: data) != ContentHash.hash(of: Data(repeating: 8, count: 4096)))
    }
}

@Suite("Kind inference")
struct ItemKindTests {
    @Test("Extensions map to the right renderer", arguments: [
        ("png", ItemKind.image),
        ("HEIC", .image),
        ("gif", .animatedImage),
        ("svg", .vector),
        ("pdf", .document),
        ("mp4", .video),
        ("mp3", .audio),
        ("zip", .other),
    ])
    func inference(ext: String, expected: ItemKind) {
        #expect(ItemKind.infer(ext: ext) == expected)
    }

    @Test("No extension plus a URL means a link item")
    func links() {
        #expect(ItemKind.infer(ext: "", url: "https://example.com") == .link)
        #expect(ItemKind.infer(ext: "") == .other)
    }
}
