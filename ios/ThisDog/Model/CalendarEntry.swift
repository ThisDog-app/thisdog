import Foundation

/// Was im Kalender steht. Die Art bestimmt Farbe und Bezeichnung.
enum EntryKind: String, Sendable, CaseIterable {
    case personal, seasonal, warning, birthday, health

    var label: String {
        switch self {
        case .personal: String(localized: "Eigener Termin")
        case .seasonal: String(localized: "Saisonaler Hinweis")
        case .warning: String(localized: "Warnzeitraum")
        case .birthday: String(localized: "Geburtstag")
        case .health: String(localized: "Gesundheit")
        }
    }
}

/// Ein einzelnes Vorkommen im Kalender – ein eigener Termin, ein Teil einer Serie oder ein Hinweis.
struct CalendarEntry: Identifiable, Hashable, Sendable {
    /// Eindeutig je Vorkommen (Serien: Kennung + Nummer).
    let id: String
    /// Der gespeicherte Termin, zu dem das Vorkommen gehört; `nil` bei Hinweisen, die man nicht bearbeitet.
    let eventID: String?
    let title: String
    let start: Day
    /// Letzter Tag (einschließlich); gleich `start` bei eintägigen.
    let end: Day
    let time: String
    /// Uhrzeit des Endes, leer wenn keine.
    var endTime: String = ""
    let notes: String
    let kind: EntryKind
    let repetition: Repetition?
    let tipSlug: String

    var isEditable: Bool { eventID != nil }
    var spanDays: Int { start.days(until: end) + 1 }
    /// Der Titel ohne Emoji: Die Oberfläche zeigt Art und Farbe selbst.
    var plainTitle: String {
        String(String.UnicodeScalarView(title.unicodeScalars.filter { !$0.properties.isEmojiPresentation && $0.value != 0xFE0F }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Ab dieser Länge ist ein Eintrag ein Zeitraum (Zecken-Saison) und steht nicht als Punkt an jedem Tag.
    static let longSpan = 7
    var isPeriod: Bool { spanDays > CalendarEntry.longSpan }

    func covers(_ day: Day) -> Bool { start <= day && day <= end }

    /// „10:00–11:30 Uhr“ an einem Tag, „18:00 Uhr“ ohne Ende; über mehrere Tage nur der Beginn (das Ende steht in `untilText`).
    var timeText: String? {
        guard let (h, m) = SystemCalendar.clock(time) else { return nil }
        let from = String(format: "%d:%02d", h, m)
        if spanDays == 1, let (eh, em) = SystemCalendar.clock(endTime) { return String(localized: "\(from)–\(String(format: "%d:%02d", eh, em)) Uhr") }
        return String(localized: "\(from) Uhr")
    }

    /// „bis So 16.11.“, mit Uhrzeit „bis So 16.11., 12:00“ – nur bei mehreren Tagen.
    var untilText: String? {
        guard spanDays > 1 else { return nil }
        let day = "\(Day.weekdayShort[end.weekdayFromMonday]) \(end.shortText)"
        if let (h, m) = SystemCalendar.clock(endTime) { return String(localized: "bis \(day), \(String(format: "%d:%02d", h, m))") }
        return String(localized: "bis \(day)")
    }
}

/// Löst Termine in Vorkommen auf und sammelt alles, was der Kalender zeigt.
enum CalendarBuilder {
    /// Aufgelöst wird ein Fenster um heute; eine Serie ohne Ende hätte sonst kein Ende.
    static let monthsBack = 12
    static let monthsAhead = 24
    static let maxOccurrences = 300

    /// Wie in der Web-App: Das erste Vorkommen bleibt immer, damit der Beginn einer Serie sichtbar ist,
    /// auch wenn er länger zurückliegt.
    static func occurrences(of ev: DogEvent, today: Day = .today) -> [CalendarEntry] {
        guard let start = ev.startDay else { return [] }
        let span = ev.endDay.map { max(0, start.days(until: $0)) } ?? 0
        let kind: EntryKind = .personal

        func entry(_ s: Day, _ n: Int) -> CalendarEntry {
            CalendarEntry(id: n == 0 && ev.rule == nil ? ev.id : "\(ev.id)#\(n)", eventID: ev.id,
                          title: ev.title, start: s, end: s.adding(days: span), time: ev.time, endTime: ev.time.isEmpty ? "" : ev.endTime,
                          notes: ev.notes, kind: kind, repetition: ev.rule, tipSlug: "")
        }

        guard let rule = ev.rule else { return [entry(start, 0)] }

        let from = today.firstOfMonth.adding(months: -monthsBack)
        let lastMonth = today.firstOfMonth.adding(months: monthsAhead)
        let to = Day(lastMonth.year, lastMonth.month, Day.daysIn(year: lastMonth.year, month: lastMonth.month))
        let until = ev.untilDay

        var out: [CalendarEntry] = []
        // Eine lange laufende Serie (wöchentlich seit Jahren) erreichte das Fenster sonst nie innerhalb von
        // `maxOccurrences` Schritten: Gezählt wird ab dem ersten Vorkommen im Fenster, die Nummern bleiben dieselben.
        let first = firstStep(rule, start: start, reaching: from)
        if first > 0 {
            if let until, start > until { return [] }
            out.append(entry(start, 0))
        }
        for n in first..<(first + maxOccurrences) {
            let d = rule.step(start, n)
            if d > to { break }
            if let until, d > until { break }
            if n == 0 || d >= from { out.append(entry(d, n)) }
        }
        return out
    }

    /// Die kleinste Nummer, deren Vorkommen nicht vor `from` liegt (die Schritte wachsen mit der Nummer).
    static func firstStep(_ rule: Repetition, start: Day, reaching from: Day) -> Int {
        guard rule.step(start, 0) < from else { return 0 }
        var lo = 0, hi = 1
        // Weiter als 1 << 20 Schritte (20.000 Jahre wöchentlich) sucht niemand.
        while rule.step(start, hi) < from, hi < 1 << 20 { lo = hi; hi *= 2 }
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if rule.step(start, mid) < from { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// Geburtstag (dieses und nächstes Jahr) und Fälligkeiten aus den Gesundheitsdaten, wie in der Web-App.
    static func dogEntries(profile: DogProfile, dues: [HealthDue], today: Day = .today) -> [CalendarEntry] {
        var out: [CalendarEntry] = []
        if let b = profile.birthDay, !profile.name.isEmpty {
            for year in [today.year, today.year + 1] where year > b.year {
                let d = Day(year, b.month, min(b.day, Day.daysIn(year: year, month: b.month)))
                out.append(CalendarEntry(id: "bday_\(year)", eventID: nil, title: String(localized: "\(profile.name) wird \(year - b.year)"),
                                         start: d, end: d, time: "", notes: "", kind: .birthday, repetition: nil, tipSlug: ""))
            }
        }
        for due in dues {
            let title = due.kind == String(localized: "Medikament endet") ? String(localized: "\(due.title) endet") : String(localized: "\(due.kind) fällig: \(due.title)")
            out.append(CalendarEntry(id: due.id, eventID: nil, title: title, start: due.due, end: due.due, time: "",
                                     notes: "", kind: .health, repetition: nil, tipSlug: ""))
        }
        return out
    }

    static func all(events: [DogEvent], seasonal: [SeasonalHint], today: Day = .today) -> [CalendarEntry] {
        var out = events.flatMap { occurrences(of: $0, today: today) }
        out += seasonal.compactMap(\.entry)
        return out.sorted { ($0.start, $0.time, $0.title) < ($1.start, $1.time, $1.title) }
    }
}

/// Ein Hinweis aus `public_events.json` (Zecken-Saison, Silvester …). Dort zählt „end“ noch
/// ausschließlich, wie es FullCalendar verlangte.
struct SeasonalHint: Decodable, Sendable {
    let title: String
    let start: String
    let end: String?
    let notes: String?
    let classNames: [String]?
    let tipSlug: String?

    var entry: CalendarEntry? {
        guard let s = Day(iso: start) else { return nil }
        let e = end.flatMap { Day(iso: $0)?.adding(days: -1) } ?? s
        let warning = classNames?.contains("fc-event-warning") ?? false
        return CalendarEntry(id: "pub_\(title)_\(start)", eventID: nil, title: title, start: s, end: max(s, e),
                             time: "", notes: notes ?? "", kind: warning ? .warning : .seasonal,
                             repetition: nil, tipSlug: tipSlug ?? "")
    }
}
