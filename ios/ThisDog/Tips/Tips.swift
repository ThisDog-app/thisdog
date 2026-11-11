import Foundation
import SwiftUI
import UIKit

/// Ein Tipp aus `tips.json`.
struct Tip: Decodable, Identifiable, Hashable, Sendable {
    struct Media: Decodable, Hashable, Sendable { let src: String; let alt: String? }

    let id: Int
    let slug: String
    let title: String
    let category: String
    let tags: [String]?
    /// „puppy“, „adult“, „senior“
    let age: [String]?
    /// „spring“, „summer“, „autumn“, „winter“
    let season: [String]?
    let media: [Media]?
    let content: String
    let checklist: [String]?

    /// `img/tips/hitze-1.png` → `hitze-1` (die App kennt die Bilder als `hitze-1.webp`).
    var imageName: String? {
        guard let src = media?.first?.src else { return nil }
        return (src as NSString).lastPathComponent.components(separatedBy: ".").first
    }

    /// Mitgeliefert, sonst vom Server – ein neuer Tipp bringt sein Bild nicht in der App mit.
    var bundledImage: UIImage? {
        imageName.flatMap { Bundle.main.url(forResource: $0, withExtension: "webp") }.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    var remoteImage: URL? { imageName.map { URL(string: "https://thisdog.app/img/tips/w900/\($0).webp")! } }

    /// Lesezeit bei 200 Wörtern je Minute.
    var minutes: Int { max(1, Int((Double(content.split(whereSeparator: \.isWhitespace).count) / 200).rounded())) }
}

enum Season: String, CaseIterable {
    case spring, summer, autumn, winter

    static func of(_ d: Day) -> Season {
        switch d.month { case 12, 1, 2: .winter; case 3...5: .spring; case 6...8: .summer; default: .autumn }
    }

    var label: String {
        switch self { case .spring: String(localized: "Frühling"); case .summer: String(localized: "Sommer"); case .autumn: String(localized: "Herbst"); case .winter: String(localized: "Winter") }
    }
}

enum TipRanking {
    /// Wie in der Web-App: Jahreszeit +3, Lebensphase +1, ganzjährig +0,5.
    static func score(_ t: Tip, season: Season, stage: String?) -> Double {
        var s = 0.0
        if t.season?.contains(season.rawValue) == true { s += 3 }
        if let stage, t.age?.contains(stage) == true { s += 1 }
        if t.season?.count == 4 { s += 0.5 }
        return s
    }

    static func stageKey(_ label: String?) -> String? {
        switch label { case String(localized: "Welpe"): "puppy"; case String(localized: "Senior"): "senior"; case String(localized: "Erwachsen"): "adult"; default: nil }
    }
}

/// Die Häkchen der Checklisten – ein Datensatz für alle Tipps (Art „checks“), wie in der Web-App.
struct TipChecks: Hashable, Sendable {
    var bySlug: [String: [Bool]] = [:]
    var u: Double = 0
}

extension TipChecks: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        for k in c.allKeys {
            if k.stringValue == "u" { u = (try? c.decode(Double.self, forKey: k)) ?? 0 }
            else if let list = try? c.decode([Bool].self, forKey: k) { bySlug[k.stringValue] = list }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (slug, list) in bySlug { try c.encode(list, forKey: Key(stringValue: slug)) }
        try c.encode(u, forKey: Key(stringValue: "u"))
    }
}

extension TipChecks: SyncedItem {
    static let kind = "checks"
    var id: String { "checks" }
}

/// Der Text eines Tipps: Überschriften (###), Aufzählungen (*), Absätze; fett und Links im Satz.
enum TipText {
    enum Block: Hashable { case heading(String), bullet(String), paragraph(String) }

    static func blocks(_ md: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else {
                para.append(line)
            }
        }
        flush()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
