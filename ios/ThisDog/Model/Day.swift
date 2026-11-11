import Foundation

/// Ein Kalendertag ohne Uhrzeit und Zeitzone – so, wie ihn die Daten speichern („2026-10-17“).
///
/// Termine des Hundes sind Tage, keine Zeitpunkte: Eine Impfung am 3. März bleibt am 3. März,
/// auch wenn das Telefon die Zeitzone wechselt. Deshalb kein `Date` im Modell.
struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Liest „JJJJ-MM-TT“; alles andere ergibt `nil`.
    init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= Day.daysIn(year: y, month: m)
        else { return nil }
        self.init(y, m, d)
    }

    init(date: Date, calendar: Calendar = .gregorianLocal) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(c.year!, c.month!, c.day!)
    }

    static var today: Day { Day(date: Date()) }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var description: String { iso }

    /// Mitternacht dieses Tages in der aktuellen Zeitzone.
    var date: Date {
        Calendar.gregorianLocal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    static func daysIn(year: Int, month: Int) -> Int {
        let cal = Calendar.gregorianLocal
        let first = cal.date(from: DateComponents(year: year, month: month, day: 1))!
        return cal.range(of: .day, in: .month, for: first)!.count
    }

    func adding(days n: Int) -> Day {
        Day(date: Calendar.gregorianLocal.date(byAdding: .day, value: n, to: date)!)
    }

    /// Monate weiter; der 31. fällt in kürzeren Monaten auf deren letzten Tag, nicht in den Folgemonat.
    func adding(months n: Int) -> Day {
        let total = (year * 12 + (month - 1)) + n
        let y = total / 12, m = total % 12 + 1
        return Day(y, m, min(day, Day.daysIn(year: y, month: m)))
    }

    func adding(years n: Int) -> Day {
        Day(year + n, month, min(day, Day.daysIn(year: year + n, month: month)))
    }

    /// Ganze Tage von hier bis `other` (positiv, wenn `other` später liegt).
    func days(until other: Day) -> Int {
        Calendar.gregorianLocal.dateComponents([.day], from: date, to: other.date).day!
    }

    var firstOfMonth: Day { Day(year, month, 1) }

    /// Wochentag mit Montag = 0 … Sonntag = 6.
    var weekdayFromMonday: Int {
        (Calendar.gregorianLocal.component(.weekday, from: date) + 5) % 7
    }
}

extension Calendar {
    /// Gregorianisch, Woche ab Montag, Zeitzone des Geräts.
    static var gregorianLocal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = .current
        c.locale = Locale(identifier: "de_DE")
        return c
    }
}
