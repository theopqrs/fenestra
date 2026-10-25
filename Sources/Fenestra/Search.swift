import Foundation

/// Filters the switcher's items as the user types: every word must appear in the app name, the window
/// or tab title, or the tab's site. Case and accents are ignored ("reglages" finds "Réglages Système").
enum Search {
    /// Tabs are many: only the best ones are shown.
    static let maxTabs = 8

    /// Windows, then tabs, then apps without windows — each group best match first, ties in their original
    /// (most recently used) order. The selection starts on the best match overall.
    static func results(for query: String, in items: [SwitcherItem]) -> (items: [SwitcherItem], selection: Int) {
        let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return (items, 0) }

        let scored = items.enumerated().compactMap { offset, item in
            score(item, words: words).map { (item: item, score: $0, offset: offset) }
        }
        func best(_ kind: (SwitcherItem) -> Bool) -> [(item: SwitcherItem, score: Int, offset: Int)] {
            scored.filter { kind($0.item) }.sorted { ($0.score, -$0.offset) > ($1.score, -$1.offset) }
        }
        let ordered = best(\.isWindow) + best(\.isTab).prefix(maxTabs) + best(\.isApp)
        let selection = ordered.indices.max { ordered[$0].score < ordered[$1].score } ?? 0
        return (ordered.map(\.item), selection)
    }

    /// nil when a word matches nothing. Matches at the start of the app name or of a word count more.
    private static func score(_ item: SwitcherItem, words: [String]) -> Int? {
        let app = normalized(item.appName)
        let title = item.isApp ? "" : normalized(item.title)
        let host = normalized(item.tab?.host ?? "")
        let titleWords = title.split { !$0.isLetter && !$0.isNumber }
        let hostParts = host.split(separator: ".")

        var total = 0
        for word in words {
            if app.hasPrefix(word) {
                total += 4
            } else if titleWords.contains(where: { $0.hasPrefix(word) }) || hostParts.contains(where: { $0.hasPrefix(word) }) {
                total += 3
            } else if app.contains(word) || title.contains(word) || host.contains(word) {
                total += 1
            } else {
                return nil
            }
        }
        return total
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
