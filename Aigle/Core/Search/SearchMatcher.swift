import Foundation

/// Name + tag matching for the grid filter and the ⌘K palette.
///
/// Scoring favours prefix hits, then word-boundary hits, then subsequence
/// ("fuzzy") hits — so typing `bgl` finds `big-green-logo.png`.
public enum SearchMatcher {
    public static func matches(_ item: Item, query: String) -> Bool {
        score(item, query: query) != nil
    }

    public static func score(_ item: Item, query: String) -> Int? {
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !needle.isEmpty else { return 0 }

        var best: Int?
        if let nameScore = score(text: item.name, needle: needle) {
            best = nameScore
        }
        for tag in item.tags {
            if let tagScore = score(text: tag, needle: needle) {
                best = min(best ?? Int.max, tagScore + 5)
            }
        }
        if !item.ext.isEmpty, let extScore = score(text: item.ext, needle: needle) {
            best = min(best ?? Int.max, extScore + 40)
        }
        if !item.url.isEmpty, let urlScore = score(text: item.url, needle: needle) {
            best = min(best ?? Int.max, urlScore + 60)
        }
        if !item.annotation.isEmpty, let noteScore = score(text: item.annotation, needle: needle) {
            best = min(best ?? Int.max, noteScore + 80)
        }
        return best
    }

    /// Lower is better.
    static func score(text: String, needle: String) -> Int? {
        let haystack = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if haystack == needle { return 0 }
        if haystack.hasPrefix(needle) { return 1 }
        if let range = haystack.range(of: needle) {
            let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            // Word-boundary hits beat mid-word hits.
            let previous = haystack.index(before: range.lowerBound)
            let boundary = " -_./".contains(haystack[previous])
            return (boundary ? 2 : 10) + min(offset, 40)
        }
        return subsequenceScore(haystack: haystack, needle: needle)
    }

    static func subsequenceScore(haystack: String, needle: String) -> Int? {
        var gaps = 0
        var lastIndex: String.Index?
        var cursor = haystack.startIndex
        for character in needle {
            guard let found = haystack[cursor...].firstIndex(of: character) else { return nil }
            if let lastIndex {
                gaps += haystack.distance(from: lastIndex, to: found) - 1
            }
            lastIndex = found
            cursor = haystack.index(after: found)
        }
        return 100 + gaps
    }

    /// Ranked results across the library and every connected folder.
    public static func rank(_ items: [Item], query: String, limit: Int = 60) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return items
            .compactMap { item -> (Item, Int)? in
                guard let score = score(item, query: trimmed) else { return nil }
                return (item, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.btime > rhs.0.btime
            }
            .prefix(limit)
            .map(\.0)
    }
}
