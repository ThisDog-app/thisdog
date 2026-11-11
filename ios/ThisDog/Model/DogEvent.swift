import Foundation

/// Wie oft sich ein Termin wiederholt. Die Schlüssel sind dieselben wie in der Web-App und im Abgleich.
enum Repetition: String, Codable, CaseIterable, Sendable {
    case weekly, biweekly, monthly, quarterly, halfyearly, yearly

    var label: String {
        switch self {
        case .weekly: String(localized: "Jede Woche")
        case .biweekly: String(localized: "Alle zwei Wochen")
        case .monthly: String(localized: "Jeden Monat")
        case .quarterly: String(localized: "Alle drei Monate")
        case .halfyearly: String(localized: "Alle sechs Monate")
        case .yearly: String(localized: "Jedes Jahr")
        }
    }

    /// Der n-te Termin der Serie, immer vom Beginn aus gerechnet: So wandert der 31. nicht
    /// nach einem Februar dauerhaft auf den 28.
    func step(_ start: Day, _ n: Int) -> Day {
        switch self {
        case .weekly: start.adding(days: 7 * n)
        case .biweekly: start.adding(days: 14 * n)
        case .monthly: start.adding(months: n)
        case .quarterly: start.adding(months: 3 * n)
        case .halfyearly: start.adding(months: 6 * n)
        case .yearly: start.adding(years: n)
        }
    }
}

/// Ein eigener Termin, wie ihn die Web-App gespeichert hat und `api/sync.php` abgleicht
/// (Art „event“). Leere Zeichenketten statt `nil`, damit die Nutzlast gleich aussieht.
struct DogEvent: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    /// Erster Tag, „JJJJ-MM-TT“.
    var start: String
    /// Letzter Tag (einschließlich) bei mehrtägigen Terminen, sonst leer.
    var end: String = ""
    /// Uhrzeit „HH:mm“, leer für ganztägige Termine. Neu in der App; die Web-App kannte nur Tage.
    var time: String = ""
    /// Uhrzeit des Endes „HH:mm“ (am Tag `end`, sonst am ersten Tag); leer: eine Stunde nach Beginn bzw. ganztägig.
    var endTime: String = ""
    var notes: String = ""
    var kind: String = "personal"
    var repetition: String = ""
    var repeatUntil: String = ""
    /// Zeitpunkt der letzten Änderung in Millisekunden – entscheidet beim Abgleich.
    var u: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, title, start, end, time, endTime, notes, kind, repeatUntil, u
        case repetition = "repeat"
    }

    init(id: String = DogEvent.newID(), title: String, start: Day, end: Day? = nil, time: String = "",
         notes: String = "", repetition: Repetition? = nil, repeatUntil: Day? = nil) {
        self.id = id
        self.title = title
        self.start = start.iso
        self.end = end?.iso ?? ""
        self.time = time
        self.notes = notes
        self.repetition = repetition?.rawValue ?? ""
        self.repeatUntil = repeatUntil?.iso ?? ""
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        start = try c.decodeIfPresent(String.self, forKey: .start) ?? ""
        end = try c.decodeIfPresent(String.self, forKey: .end) ?? ""
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        endTime = try c.decodeIfPresent(String.self, forKey: .endTime) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "personal"
        repetition = try c.decodeIfPresent(String.self, forKey: .repetition) ?? ""
        repeatUntil = try c.decodeIfPresent(String.self, forKey: .repeatUntil) ?? ""
        u = try c.decodeIfPresent(Double.self, forKey: .u) ?? 0
    }

    var startDay: Day? { Day(iso: start) }
    var endDay: Day? { Day(iso: end) }
    var untilDay: Day? { Day(iso: repeatUntil) }
    var rule: Repetition? { Repetition(rawValue: repetition) }

    /// Kennung im Format der Web-App: `evt_<Zeit base36><5 Zeichen>`.
    static func newID() -> String {
        let t = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let r = String((0..<5).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return "evt_\(t)\(r)"
    }
}
