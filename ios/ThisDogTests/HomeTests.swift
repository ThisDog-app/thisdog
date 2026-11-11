import Foundation
import Testing
@testable import ThisDog

@Suite("Startseite")
@MainActor
struct HomeTests {
    private func place(_ name: String) -> Place {
        Place(name: name, kind: "park", label: "Park", rank: 0, lat: 48.2, lon: 16.4, serverID: "way/\(name)")
    }

    @Test("Zeigt nur Orte, an denen noch nicht eingecheckt wurde, höchstens drei")
    func unvisited() {
        let all = ["a", "b", "c", "d", "e"].map(place)
        let list = HomeScreen.unvisited(all, checkIns: [CheckIn(place: all[0]), CheckIn(place: all[2])])
        #expect(list.map(\.name) == ["b", "d", "e"])
    }

    @Test("ThisDog sagt etwas Passendes und wechselt beim Stupsen")
    func dogLine() {
        let today = Day.today
        let line = { (walking: Bool, walked: Bool, last: Day?, seed: Int) in
            HomeScreen.dogLine(walking: walking, walkedToday: walked, lastWalk: last, today: today, hour: 9, seed: seed)
        }
        #expect(line(true, false, today, 0) == "Hier riecht's super!")
        #expect(line(false, true, today, 0) == "Schön war's. Jetzt Sofa?")
        #expect(line(false, false, nil, 0) == "Unsere erste Runde! Ich bin so bereit.")
        #expect(line(false, false, today.adding(days: -3), 0) == "Hallo? Die Leine vermisst mich.")
        #expect(line(false, false, today.adding(days: -1), 0) == "Aufstehen! Die Wiese wartet.")
        #expect(line(false, true, today, 0) != line(false, true, today, 1))
        #expect(line(false, true, today, 3) == line(false, true, today, 0))
    }


    @Test("Die Frage passt zum Tag")
    func headline() {
        #expect(HomeScreen.headline(walking: false, walkedToday: false) == "Zeit für eine Runde?")
        #expect(HomeScreen.headline(walking: false, walkedToday: true) == "Schön, ihr wart heute schon draußen.")
        #expect(HomeScreen.headline(walking: true, walkedToday: true) == "Ihr seid unterwegs.")
    }
}

@Suite("Die nächste Stunde")
struct NextHourTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Ohne Regen trocken, mit Minuten der Beginn, sonst die Wahrscheinlichkeit")
    func lines() {
        let dry = NextHour(now: now, minutes: nil, hours: [.init(date: now.addingTimeInterval(1800), chance: 0.05, snow: false, temperature: 6)], raining: false)
        #expect(dry.line(now: now) == "Die nächste Stunde bleibt trocken.")
        let minutes = (1...60).map { i in NextHour.Minute(date: now.addingTimeInterval(Double(i) * 60), chance: i >= 20 ? 0.8 : 0, intensity: i >= 20 ? 1 : 0) }
        let rain = NextHour(now: now, minutes: minutes, hours: [], raining: false)
        #expect(rain.change == now.addingTimeInterval(20 * 60))
        let likely = NextHour(now: now, minutes: nil, hours: [.init(date: now.addingTimeInterval(1800), chance: 0.7, snow: true, temperature: 0)], raining: false)
        #expect(likely.line(now: now) == "Schnee wahrscheinlich, 70 %.")
        let stops = NextHour(now: now, minutes: minutes.map { .init(date: $0.date, chance: $0.date < now.addingTimeInterval(1800) ? 0.9 : 0, intensity: $0.date < now.addingTimeInterval(1800) ? 1 : 0) }, hours: [], raining: true)
        #expect(stops.change == now.addingTimeInterval(30 * 60))
    }
}

@Suite("Spruch des Tages")
struct SayingTests {
    @Test("Bleibt über den Tag gleich, wechselt am nächsten und wiederholt sich erst nach der ganzen Liste")
    func rotates() {
        let day = Day(2026, 11, 11)
        #expect(Saying.of(day) == Saying.of(Day(2026, 11, 11)))
        #expect(Saying.of(day) != Saying.of(day.adding(days: 1)))
        #expect(Saying.of(day) == Saying.of(day.adding(days: Saying.all.count)))
        #expect(Set(Saying.all).count == Saying.all.count)
        #expect(Saying.of(Day(2025, 6, 1)).isEmpty == false)
    }
}
