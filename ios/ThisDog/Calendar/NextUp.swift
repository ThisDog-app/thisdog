import SwiftUI

/// Was als Nächstes ansteht: „Noch 2 Tage“ und der Termin, am selben Tag in Stunden und Minuten.
struct NextUp: View {
    let entry: CalendarEntry
    /// Die Restzeit ist das Wichtigste auf der ganzen Seite, die Größe richtet sich nach dem Gerät.
    var size: CGFloat = 44
    /// Platz rechts neben der Restzeit für Knöpfe; alles darunter hat die volle Breite.
    var reservedTrailing: CGFloat = 0

    var body: some View {
        TimelineView(.everyMinute) { context in
            let line = Self.remaining(to: entry, now: context.date)
            VStack(alignment: .leading, spacing: 4) {
                Text(line)
                    .font(.display(size, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText(countsDown: true))
                    .padding(.trailing, reservedTrailing)
                Text(entry.title)
                    .font(.display(size * 0.56, weight: .medium, relativeTo: .title3))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(TimeLeash.dateLine(entry))
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.snappy, value: line)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(line), \(entry.plainTitle), \(TimeLeash.dateLine(entry))")
        }
    }

    /// „Noch 2 Tage“ am Stück, damit jede Sprache Zahl und Wort so stellen und beugen kann, wie sie es braucht.
    static func remaining(to e: CalendarEntry, now: Date) -> String {
        let today = Day(date: now)
        if let (h, m) = SystemCalendar.clock(e.time), e.start == today {
            let at = Calendar.gregorianLocal.date(bySettingHour: h, minute: m, second: 0, of: today.date)!
            let mins = max(0, Int(at.timeIntervalSince(now) / 60))
            if mins == 1 { return String(localized: "Noch 1 Minute") }
            if mins < 60 { return String(localized: "Noch \(mins) Minuten") }
            let hours = Int((Double(mins) / 60).rounded())
            return hours == 1 ? String(localized: "Noch 1 Stunde") : String(localized: "Noch \(hours) Stunden")
        }
        let n = today.days(until: e.start)
        if n == 1 { return String(localized: "Noch 1 Tag") }
        if n < 14 { return String(localized: "Noch \(n) Tage") }
        if n < 63 { return n / 7 == 1 ? String(localized: "Noch 1 Woche") : String(localized: "Noch \(n / 7) Wochen") }
        return String(localized: "Noch \(n / 30) Monate")
    }

    /// Worauf gezählt wird: der nächste eigene oder Gesundheitstermin, der noch nicht begonnen hat.
    /// Ganztägiges von heute steht schon auf der Leine; heute zählt nur, was eine Uhrzeit hat und noch kommt.
    static func pick(from entries: [CalendarEntry], now: Date = Date()) -> CalendarEntry? {
        upcoming(from: entries, limit: 1, now: now).first
    }

    /// Die nächsten Termine, frühester zuerst.
    static func upcoming(from entries: [CalendarEntry], limit: Int, now: Date = Date()) -> [CalendarEntry] {
        let today = Day(date: now)
        return Array(entries
            .filter { [.personal, .health].contains($0.kind) && !$0.isPeriod }
            .filter { e in
                if e.start > today { return true }
                guard e.start == today, let (h, m) = SystemCalendar.clock(e.time) else { return false }
                let at = Calendar.gregorianLocal.date(bySettingHour: h, minute: m, second: 0, of: today.date)!
                return at > now
            }
            .sorted { ($0.start, $0.time) < ($1.start, $1.time) }
            .prefix(limit))
    }
}
