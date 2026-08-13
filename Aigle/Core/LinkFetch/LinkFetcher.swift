import AppKit
import Foundation
import os.log

public struct LinkMetadata: Sendable {
    public var title: String
    public var previewPNG: Data?
    public var faviconURL: URL?

    public init(title: String, previewPNG: Data? = nil, faviconURL: URL? = nil) {
        self.title = title
        self.previewPNG = previewPNG
        self.faviconURL = faviconURL
    }
}

/// Fetches a page's title and best preview image so pasted or dropped URLs
/// become real-looking items in the grid.
public enum LinkFetcher {
    private static let log = Logger(subsystem: "cool.aigle.Aigle", category: "links")

    public static func fetch(_ url: URL) async -> LinkMetadata {
        var metadata = LinkMetadata(title: url.host() ?? url.absoluteString)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Aigle/1.0",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data.prefix(512 * 1024), encoding: .utf8)
                ?? String(data: data.prefix(512 * 1024), encoding: .isoLatin1)
        else { return metadata }

        if let title = firstMatch(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>") {
            metadata.title = decodeEntities(title.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let ogTitle = metaContent(in: html, property: "og:title"), !ogTitle.isEmpty {
            metadata.title = decodeEntities(ogTitle)
        }

        let candidates = [
            metaContent(in: html, property: "og:image"),
            metaContent(in: html, property: "twitter:image"),
            linkHref(in: html, rel: "apple-touch-icon"),
            linkHref(in: html, rel: "icon"),
        ].compactMap { $0 }

        for candidate in candidates {
            guard let imageURL = URL(string: candidate, relativeTo: url)?.absoluteURL else { continue }
            if let png = await downloadPreview(imageURL) {
                metadata.previewPNG = png
                metadata.faviconURL = imageURL
                break
            }
        }
        return metadata
    }

    private static func downloadPreview(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "aigle-link-\(UUID().uuidString)")
        try? data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let rendered = MediaProbe.downsample(temporary, maxPixel: 1024) else { return nil }
        return MediaProbe.pngData(rendered)
    }

    // MARK: - Tiny HTML scraping (no third-party dependencies)

    static func metaContent(in html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"']*)[\"']",
            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]*(?:property|name)=[\"']\(escaped)[\"']",
        ]
        for pattern in patterns {
            if let hit = firstMatch(in: html, pattern: pattern) { return decodeEntities(hit) }
        }
        return nil
    }

    static func linkHref(in html: String, rel: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: rel)
        let pattern = "<link[^>]+rel=[\"'][^\"']*\(escaped)[^\"']*[\"'][^>]*href=[\"']([^\"']*)[\"']"
        return firstMatch(in: html, pattern: pattern).map(decodeEntities)
    }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captured])
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
        let map = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
        ]
        for (entity, replacement) in map {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }
}
