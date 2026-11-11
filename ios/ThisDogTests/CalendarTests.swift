import Foundation
import Testing
@testable import ThisDog

@Suite("Wiederholungen")
struct RepetitionTests {
    @Test("Der 31. fällt in kürzeren Monaten auf deren letzten Tag und kehrt danach zurück")
    func monthEnd() {
        let start = Day(2026, 1, 31)
        #expect(Repetition.monthly.step(start, 1) == Day(2026, 2, 28))
        #expect(Repetition.monthly.step(start, 2) == Day(2026, 3, 31))
        #expect(Repetition.monthly.step(start, 3) == Day(2026, 4, 30))
    }

    @Test("Der 29. Februar wird in Nicht-Schaltjahren zum 28.")
    func leapDay() {
        #expect(Repetition.yearly.step(Day(2028, 2, 29), 1) == Day(2029, 2, 28))
        #expect(Repetition.yearly.step(Day(2028, 2, 29), 4) == Day(2032, 2, 29))
    }

    @Test("Alle zwei Wochen und alle drei Monate")
    func intervals() {
        #expect(Repetition.biweekly.step(Day(2026, 10, 17), 1) == Day(2026, 10, 31))
        #expect(Repetition.quarterly.step(Day(2026, 11, 30), 1) == Day(2027, 2, 28))
    }

    @Test("Eine Serie endet am Tag „bis“ einschließlich")
    func until() {
        let ev = DogEvent(title: "Krallen", start: Day(2026, 10, 1), repetition: .weekly, repeatUntil: Day(2026, 10, 15))
        let days = CalendarBuilder.occurrences(of: ev, today: Day(2026, 10, 17)).map(\.start)
        #expect(days == [Day(2026, 10, 1), Day(2026, 10, 8), Day(2026, 10, 15)])
    }

    @Test("Das erste Vorkommen bleibt, auch wenn es vor dem Fenster liegt")
    func firstStays() {
        let ev = DogEvent(title: "Entwurmung", start: Day(2020, 1, 10), repetition: .quarterly)
        let list = CalendarBuilder.occurrences(of: ev, today: Day(2026, 10, 17))
        #expect(list.first?.start == Day(2020, 1, 10))
        #expect(list.dropFirst().allSatisfy { $0.start >= Day(2025, 10, 1) })
    }

    @Test("Mehrtägige Termine behalten ihre Länge in jeder Wiederholung")
    func spanKept() {
        let ev = DogEvent(title: "Läufigkeit", start: Day(2026, 3, 1), end: Day(2026, 3, 21), repetition: .halfyearly)
        let second = CalendarBuilder.occurrences(of: ev, today: Day(2026, 10, 17))[1]
        #expect(second.start == Day(2026, 9, 1))
        #expect(second.end == Day(2026, 9, 21))
    }
}

@Suite("Datenformat")
struct FormatTests {
    @Test("Ein Termin der Web-App wird gelesen und mit denselben Schlüsseln geschrieben")
    func webFormat() throws {
        let json = #"{"id":"evt_abc","title":"Tierarzt","start":"2026-10-20","end":"","notes":"","kind":"personal","repeat":"monthly","repeatUntil":"","u":1760000000000}"#
        let ev = try JSONDecoder().decode(DogEvent.self, from: Data(json.utf8))
        #expect(ev.rule == .monthly)
        #expect(ev.time == "")
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ev)) as! [String: Any]
        #expect(back["repeat"] as? String == "monthly")
        #expect(back["repetition"] == nil)
    }

    @Test("Saisonhinweise: „end“ zählt in der Datei ausschließlich")
    func seasonalEnd() throws {
        let json = #"[{"title":"Zecken","start":"2026-03-01","end":"2026-11-01","classNames":["fc-event-warning"]}]"#
        let hint = try JSONDecoder().decode([SeasonalHint].self, from: Data(json.utf8))[0]
        let e = try #require(hint.entry)
        #expect(e.end == Day(2026, 10, 31))
        #expect(e.kind == .warning)
        #expect(e.isPeriod)
    }
}

@Suite("Inhalte vom Server")
struct ContentTests {
    @Test("Kaputte oder leere Dateien ersetzen die vorhandenen nicht")
    @MainActor func rejectsBroken() {
        #expect(!ContentStore.isReadable(Data("<html>Fehler</html>".utf8), as: .publicEvents))
        #expect(!ContentStore.isReadable(Data("[]".utf8), as: .publicEvents))
        #expect(!ContentStore.isReadable(Data("{}".utf8), as: .foods))
        #expect(ContentStore.isReadable(Data(#"[{"title":"A","start":"2026-01-01"}]"#.utf8), as: .publicEvents))
    }

    @Test("Die mitgelieferten Dateien sind lesbar")
    @MainActor func bundledReadable() throws {
        let store = ContentStore()
        for file in ContentStore.File.allCases {
            let url = try #require(Bundle(for: BundleToken.self).url(forResource: file.rawValue, withExtension: "json")
                ?? Bundle.main.url(forResource: file.rawValue, withExtension: "json"))
            #expect(ContentStore.isReadable(try Data(contentsOf: url), as: file), "\(file.rawValue)")
        }
        _ = store
    }
}

@Suite("Erinnerungen")
struct ReminderTests {
    @Test("Ganztägig um 8 Uhr am Tag, mit Uhrzeit eine Stunde vorher, Vergangenes entfällt")
    @MainActor func times() {
        let now = Calendar.gregorianLocal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        let events = [
            DogEvent(title: "Heute früh", start: Day(2026, 10, 17)),
            DogEvent(title: "Morgen", start: Day(2026, 10, 18)),
            DogEvent(title: "Tierarzt", start: Day(2026, 10, 18), time: "10:30"),
        ]
        let list = Reminders.upcoming(events, now: now)
        let c = list.map { Calendar.gregorianLocal.dateComponents([.day, .hour, .minute], from: $0.0) }
        #expect(list.map(\.1.title) == ["Morgen", "Tierarzt"])
        #expect(c[0].day == 18 && c[0].hour == 8)
        #expect(c[1].day == 18 && c[1].hour == 9 && c[1].minute == 30)
    }
}

private final class BundleToken {}

@Suite("Zeitleine")
struct LeashTests {
    private func entry(_ title: String, _ start: Day, _ end: Day? = nil) -> CalendarEntry {
        CalendarEntry(id: title, eventID: title, title: title, start: start, end: end ?? start, time: "", notes: "",
                      kind: .personal, repetition: nil, tipSlug: "")
    }

    private func layout(_ start: Day, _ list: [CalendarEntry]) -> LeashLayout {
        LeashLayout(start: start, entries: list, pointsPerDay: 10, dateHeight: 20, rowHeight: 26, spacing: 16)
    }

    @Test("Der gewählte Tag ist immer der erste Knoten, auch ohne Termin")
    func startNode() {
        let l = layout(Day(2026, 10, 17), [entry("A", Day(2026, 10, 30))])
        #expect(l.nodes.first?.day == Day(2026, 10, 17))
        #expect(l.nodes.first?.entries.isEmpty == true)
    }

    @Test("Weit Entferntes liegt maßstäblich, Nahes nie enger als ein Knoten")
    func spacing() {
        let s = Day(2026, 10, 17)
        let l = layout(s, [entry("A", s), entry("B", s.adding(days: 1)), entry("C", s.adding(days: 40))])
        let y = l.nodes.map(\.y)
        #expect(y[1] == CGFloat(62))  // eng: Knoten 20 + 26, Abstand 16 – statt 10 pt für einen Tag
        #expect(y[2] == CGFloat(400))  // weit: 40 Tage × 10 pt
    }

    @Test("Termine desselben Tages bilden einen Knoten")
    func grouping() {
        let s = Day(2026, 10, 17)
        let l = layout(s, [entry("A", s), entry("B", s)])
        #expect(l.nodes.count == 1)
        #expect(l.nodes[0].height == CGFloat(72))  // Datum 20 + zwei Zeilen à 26
    }

    @Test("Lücken ab vier Tagen bekommen ihre Länge, gerechnet ab dem Ende eines Mehrtägigen")
    func gaps() {
        let s = Day(2026, 10, 17)
        let l = layout(s, [entry("Urlaub", s, s.adding(days: 6)), entry("B", s.adding(days: 9)), entry("C", s.adding(days: 11))])
        #expect(l.gaps.map(\.days) == [])  // 6 → 9 sind drei Tage, 9 → 11 zwei
        let l2 = layout(s, [entry("Urlaub", s, s.adding(days: 2)), entry("B", s.adding(days: 9))])
        #expect(l2.gaps.map(\.days) == [7])
    }

    @Test("Ein Mehrtägiges steht auch an seinen späteren Tagen")
    func running() {
        let s = Day(2026, 12, 24)
        let list = [entry("Weihnachten", s, Day(2026, 12, 26)), entry("Vorbei", Day(2026, 12, 20), Day(2026, 12, 22))]
        let l = layout(Day(2026, 12, 25), list)
        #expect(l.nodes.first?.day == Day(2026, 12, 25))
        #expect(l.nodes.first?.entries.map(\.title) == ["Weihnachten"])
        #expect(l.nodes.count == 1)
    }

    @Test("Ein Mehrtägiges reicht bis zur Höhe seines letzten Tages")
    func span() throws {
        let s = Day(2026, 10, 17)
        let l = layout(s, [entry("Urlaub", s, s.adding(days: 5)), entry("Danach", s.adding(days: 10))])
        let span = try #require(l.spans.first)
        #expect(span.from == 0)
        #expect(abs(span.to - l.nodes[1].y * 0.5) < 0.01)  // Tag 5 von 10 → halbe Strecke
    }
}

@Suite("Termin-Editor: Beginn und Ende")
@MainActor
struct EventTimesTests {
    private func at(_ d: Day, _ h: Int, _ m: Int = 0) -> Date { Calendar.gregorianLocal.date(bySettingHour: h, minute: m, second: 0, of: d.date)! }

    @Test("Über mehrere Tage mit Uhrzeiten: Tage und beide Zeiten werden gespeichert und wieder gelesen")
    func multiDayTimed() {
        let t = EventTimes(allDay: false, start: at(Day(2026, 11, 14), 18), end: at(Day(2026, 11, 16), 12, 30))
        let ev = t.applied(to: DogEvent(title: "Hundesitter", start: Day(2026, 11, 1)))
        #expect(ev.start == "2026-11-14" && ev.end == "2026-11-16" && ev.time == "18:00" && ev.endTime == "12:30")
        #expect(EventTimes(event: ev, isNew: false) == t)
        let entry = CalendarBuilder.occurrences(of: ev).first!
        #expect(entry.timeText == "18:00 Uhr")
        #expect(entry.untilText?.contains("\(Day.weekdayShort[Day(2026, 11, 16).weekdayFromMonday]) \(Day(2026, 11, 16).shortText)") == true)
        #expect(entry.untilText?.hasSuffix("12:30") == true)
    }

    @Test("Ein Tag mit Uhrzeit zeigt die Spanne; ganztägig hat keine Zeiten")
    func sameDayAndAllDay() {
        let ev = EventTimes(allDay: false, start: at(Day(2026, 11, 12), 10), end: at(Day(2026, 11, 12), 11, 30)).applied(to: DogEvent(title: "Tierarzt", start: .today))
        #expect(ev.end == "" && ev.endTime == "11:30")
        #expect(CalendarBuilder.occurrences(of: ev).first?.timeText == "10:00–11:30 Uhr")
        let all = EventTimes(allDay: true, start: at(Day(2026, 11, 12), 10), end: at(Day(2026, 11, 13), 11)).applied(to: ev)
        #expect(all.time == "" && all.endTime == "" && all.end == "2026-11-13")
    }

    @Test("Ältere Termine ohne Ende: eine Stunde; neue beginnen zur nächsten vollen Stunde")
    func defaults() {
        var old = DogEvent(title: "Impfung", start: Day(2026, 11, 12)); old.time = "09:15"
        let t = EventTimes(event: old, isNew: false)
        #expect(t.end.timeIntervalSince(t.start) == 3600)
        let now = at(.today, 14, 20)
        let fresh = EventTimes(event: DogEvent(title: "", start: .today), isNew: true, now: now)
        #expect(!fresh.allDay && fresh.start == at(.today, 15) && fresh.end == at(.today, 16))
    }
}

@Suite("Lange Serien")
struct LongSeriesTests {
    @Test("Eine wöchentliche Serie seit Jahren erreicht das sichtbare Fenster, das erste Vorkommen bleibt")
    func weeklySinceYears() {
        let ev = DogEvent(title: "Hundeschule", start: Day(2012, 1, 2), repetition: .weekly)
        let today = Day(2026, 10, 17)
        let list = CalendarBuilder.occurrences(of: ev, today: today)
        #expect(list.first?.start == Day(2012, 1, 2))
        #expect(list.first?.id == "\(ev.id)#0")
        let rest = list.dropFirst()
        #expect(rest.first?.start == Day(2025, 10, 6))
        #expect(rest.contains { $0.start == Day(2026, 10, 19) })
        // Die Nummern zählen weiter vom Beginn der Serie an.
        #expect(rest.allSatisfy { e in
            let n = Int(e.id.split(separator: "#").last!)!
            return Repetition.weekly.step(ev.startDay!, n) == e.start
        })
        #expect(rest.allSatisfy { $0.start >= Day(2025, 10, 1) })
    }

    @Test("Eine Serie, die vor dem Fenster endete, zeigt nur ihren Beginn")
    func endedBefore() {
        let ev = DogEvent(title: "Welpenkurs", start: Day(2015, 3, 1), repetition: .weekly, repeatUntil: Day(2016, 3, 1))
        let list = CalendarBuilder.occurrences(of: ev, today: Day(2026, 10, 17))
        #expect(list.map(\.start) == [Day(2015, 3, 1)])
    }

    @Test("Die erste Nummer im Fenster")
    func firstStep() {
        let start = Day(2020, 1, 1)
        #expect(CalendarBuilder.firstStep(.weekly, start: start, reaching: start) == 0)
        #expect(CalendarBuilder.firstStep(.weekly, start: start, reaching: Day(2020, 1, 8)) == 1)
        #expect(CalendarBuilder.firstStep(.weekly, start: start, reaching: Day(2020, 1, 9)) == 2)
        #expect(CalendarBuilder.firstStep(.monthly, start: Day(2020, 1, 31), reaching: Day(2020, 3, 1)) == 2)
    }

    @Test("Die Marke im Systemkalender führt zum Termin zurück")
    func calendarMarker() throws {
        let url = try #require(SystemCalendar.marker(for: "ev_abc-123"))
        #expect(url.absoluteString == "thisdog://event/ev_abc-123")
        #expect(SystemCalendar.eventID(fromMarker: url) == "ev_abc-123")
        #expect(SystemCalendar.eventID(fromMarker: URL(string: "https://thisdog.app/event/x")!) == nil)
        #expect(SystemCalendar.eventID(fromMarker: URL(string: "thisdog://event/")!) == nil)
    }
}
