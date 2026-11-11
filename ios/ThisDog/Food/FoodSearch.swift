import Foundation

/// Ein Lebensmittel aus `foods.json`.
struct Food: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let status: String
    let category: String
    let reason: String
    let aliases: [String]?

    var id: String { name }

    enum Verdict: String { case ok, warn, bad }
    var verdict: Verdict { Verdict(rawValue: status) ?? .warn }

    var verdictLabel: String {
        switch verdict { case .ok: String(localized: "Erlaubt"); case .warn: String(localized: "Nur mit Vorsicht"); case .bad: String(localized: "Nicht geeignet") }
    }
}

/// Die Suche der Web-App (`js/search.js`), auf deutsche Eingaben zugeschnitten: Umlaute aufgelöst,
/// Plural- und Flexionsendungen gekappt („Trauben“ ≈ „Traube“), zusammengesetzte Wörter in beide
/// Richtungen („Weintrauben“ findet „Trauben“), Tippfehler bis zu einer Grenze.
struct FoodSearch: Sendable {
    struct Hit: Sendable { let food: Food; let score: Double; let matched: String }

    private struct Term: Sendable { let t: String; let weight: Double; let raw: String }
    private let entries: [(Food, [Term])]

    init(_ foods: [Food]) {
        entries = foods.map { f in
            var terms: [Term] = []
            // Jeder Begriff auch ohne Umlaut („kase“ für „Käse“): So tippt man auf dem Telefon oft,
            // und als Tippfehler gerechnet läge „Hase“ gleichauf.
            func add(_ raw: String, _ weight: Double) {
                terms.append(Term(t: Self.norm(raw), weight: weight, raw: raw))
                let loose = Self.loose(raw)
                if loose != Self.norm(raw) { terms.append(Term(t: loose, weight: weight, raw: raw)) }
            }
            add(f.name, 1)
            for a in f.aliases ?? [] { add(a, 0.92) }
            add(f.category, 0.45)
            return (f, terms.filter { !$0.t.isEmpty })
        }
    }

    func search(_ raw: String, limit: Int = 10, minScore: Double = 380) -> [Hit] {
        let q = Self.norm(raw)
        guard !q.isEmpty else { return [] }
        let qStem = Self.stem(q)
        let words = q.split(separator: " ").map(String.init).filter { $0.count > 1 }
        var out: [Hit] = []
        for (food, terms) in entries {
            var best = 0.0, matched = ""
            for term in terms {
                if let s = Self.score(q, qStem, term.t) {
                    let v = s * term.weight
                    if v > best { best = v; matched = term.raw }
                }
            }
            if best == 0, words.count > 1, words.allSatisfy({ w in terms.contains { $0.t.contains(w) } }) { best = 420 }
            if best >= minScore { out.append(Hit(food: food, score: best, matched: matched)) }
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.food.name.localizedCompare($1.food.name) == .orderedAscending }
        return Array(out.prefix(limit))
    }

    // MARK: Bausteine, wie in der Web-App

    static func norm(_ s: String) -> String {
        var v = s.lowercased()
            .replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "ß", with: "ss")
        v = v.folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
        v = String(v.map { "_-–—/.,;:()\"'`!?*".contains($0) ? " " : $0 })
        return v.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Wie `norm`, aber Umlaute ohne e: „Käse“ → „kase“.
    static func loose(_ s: String) -> String {
        norm(s.replacingOccurrences(of: "ä", with: "a").replacingOccurrences(of: "ö", with: "o").replacingOccurrences(of: "ü", with: "u")
            .replacingOccurrences(of: "Ä", with: "A").replacingOccurrences(of: "Ö", with: "O").replacingOccurrences(of: "Ü", with: "U"))
    }

    static let suffixes = ["ern", "nen", "en", "er", "es", "em", "e", "n", "s"]

    static func stem(_ w: String) -> String {
        guard w.count >= 5 else { return w }
        for s in suffixes where w.count - s.count >= 4 && w.hasSuffix(s) { return String(w.dropLast(s.count)) }
        return w
    }

    static func editDistance(_ a: String, _ b: String, limit: Int = 2) -> Int {
        let a = Array(a), b = Array(b)
        if a == b { return 0 }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(1, a.count) where !a.isEmpty {
            cur[0] = i
            var best = cur[0]
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                best = min(best, cur[j])
            }
            if best > limit { return limit + 1 }
            prev = cur
        }
        return prev[b.count]
    }

    static func score(_ q: String, _ qStem: String, _ term: String) -> Double? {
        if term == q { return 1000 }
        if term.hasPrefix(q) { return 880 - Double(min(60, term.count - q.count)) }
        if term.contains(" " + q) { return 760 }
        if let r = term.range(of: q), r.lowerBound > term.startIndex {
            let inside = term.distance(from: term.startIndex, to: r.lowerBound)
            return 690 - Double(min(40, inside * 2))
        }
        if q.count > term.count, term.count >= 4, q.contains(term) { return 640 }
        let tStem = stem(term)
        if qStem.count >= 3, tStem.count >= 3 {
            if tStem == qStem { return 820 }
            if tStem.hasPrefix(qStem) { return 720 }
            if qStem.count > tStem.count, qStem.contains(tStem) { return 610 }
        }
        if q.count >= 4 {
            let limit = q.count >= 8 ? 2 : 1
            let d = editDistance(q, term, limit: limit)
            if d <= limit { return 560 - Double(d) * 90 }
            let head = String(term.split(separator: " ").first ?? "")
            if head != term, head.count >= 4 {
                let dh = editDistance(q, head, limit: limit)
                if dh <= limit { return 500 - Double(dh) * 90 }
            }
        }
        return nil
    }
}

/// Ein Eintrag auf der Merkliste (Art „favorite“, Kennung = Name), wie in der Web-App.
struct FavoriteFood: Codable, Hashable, Sendable {
    var name: String
    var u: Double = 0
}

extension FavoriteFood: SyncedItem {
    static let kind = "favorite"
    var id: String { name }
}
