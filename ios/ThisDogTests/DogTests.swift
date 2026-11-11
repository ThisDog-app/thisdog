import Foundation
import UIKit
import Testing
@testable import ThisDog

@Suite("Hund")
@MainActor
struct DogTests {
    private func freshStore() -> DogStore {
        DogStore(file: URL.temporaryDirectory.appending(path: "dog-test-\(UUID().uuidString).json"))
    }

    @Test("Erledigt: neuer Eintrag von heute, nächste Fälligkeit im alten Abstand, alte entfällt")
    func markDone() {
        let s = freshStore()
        let today = Day(2026, 11, 9)
        s.save(Deworming(id: "deworming_a", product: "Milbemax", date: "2026-08-15", next: "2026-11-13"))
        s.save(Vaccination(id: "vaccinations_a", name: "Tollwut", date: "", next: "2026-11-01"))
        s.save(Medication(id: "meds_a", name: "Tabletten", from: "2026-11-01", to: "2026-11-12"))
        let worm = s.dues.first { $0.id == "due_deworming_a" }!
        #expect(s.canMarkDone(worm, today: today))
        #expect(!s.canMarkDone(s.dues.first { $0.id == "due_meds_a" }!, today: today))
        #expect(s.markableDueIDs == ["due_deworming_a", "due_vaccinations_a"])

        #expect(s.markDone("due_deworming_a", today: today))
        // 90 Tage Abstand bleiben 90 Tage.
        #expect(s.dewormings.contains { $0.date == "2026-11-09" && $0.next == today.adding(days: 90).iso && $0.product == "Milbemax" })
        #expect(s.dewormings.first { $0.id == "deworming_a" }?.next == "")

        // Ohne letztes Datum: Impfung wieder in einem Jahr.
        #expect(s.markDone("due_vaccinations_a", today: today))
        #expect(s.vaccinations.contains { $0.date == "2026-11-09" && $0.next == "2027-11-09" })
        #expect(!s.markDone("due_meds_a", today: today))
        #expect(!s.dues.contains { $0.id == "due_deworming_a" || $0.id == "due_vaccinations_a" })
    }

    @Test("Alter und Lebensphase wie in der Web-App")
    func age() {
        var p = DogProfile()
        p.birthdate = "2023-06-20"
        #expect(p.age(on: Day(2026, 10, 18)) == "3 Jahre, 3 Monate")
        #expect(p.age(on: Day(2023, 7, 20)) == "1 Monat")
        #expect(p.stage(on: Day(2024, 1, 1)) == "Welpe")
        p.weightKg = 45
        #expect(p.stage(on: Day(2029, 7, 1)) == "Senior")   // große Hunde: ab 6 Jahren
        p.weightKg = 8
        #expect(p.stage(on: Day(2029, 7, 1)) == "Erwachsen")
    }

    @Test("Ein Profil der Web-App wird gelesen, auch wenn Felder fehlen")
    func webProfile() throws {
        let json = #"{"name":"Stella","breed":"Pudel","birthdate":"2023-06-20","sex":"f","weightKg":21.4,"neutered":false}"#
        let p = try JSONDecoder().decode(DogProfile.self, from: Data(json.utf8))
        #expect(p.name == "Stella")
        #expect(p.activity == "normal")
        #expect(p.vetPhone == "")
    }

    @Test("Ein Gewicht je Tag, das Profil folgt dem jüngsten")
    func weights() {
        let s = freshStore()
        var p = DogProfile(); p.name = "Stella"; s.save(p)
        s.saveWeight(22.0, on: Day(2026, 9, 1))
        s.saveWeight(21.5, on: Day(2026, 10, 1))
        s.saveWeight(21.4, on: Day(2026, 10, 1))
        #expect(s.weights.count == 2)
        #expect(s.profile.weightKg == 21.4)
        #expect(s.outgoingRecords().contains { $0.kind == "weight" && $0.id == "2026-10-01" })
    }

    @Test("Fälligkeiten stehen im Kalender, der Geburtstag auch")
    func calendar() {
        let s = freshStore()
        var p = DogProfile(); p.name = "Stella"; p.birthdate = "2023-06-20"; s.save(p)
        s.save(Vaccination(id: "vaccinations_1", name: "Tollwut", date: "2025-10-01", next: "2026-10-01"))
        let titles = s.entries.map(\.title)
        #expect(titles.contains("Impfung fällig: Tollwut"))
        #expect(titles.contains { $0.hasPrefix("Stella wird") })
    }

    @Test("Ring: vergangener Anteil zwischen letztem Mal und Fälligkeit")
    func progress() {
        let due = HealthDue(id: "x", title: "Milbemax", kind: "Entwurmung", last: Day(2026, 7, 1), due: Day(2026, 10, 1))
        let p = due.progress(on: Day(2026, 8, 16)) ?? -1
        #expect(abs(p - 0.5) < 0.02)
        #expect(due.progress(on: Day(2026, 12, 1)) == 1)
    }

    @Test("Gesundheitsdaten aus dem Rudel kommen an, Profil als einzelner Datensatz")
    func incoming() throws {
        let s = freshStore()
        var p = DogProfile(); p.name = "Stella"
        s.applyIncoming([
            SyncRecord(kind: "profile", id: "profile", updatedAt: 10, payload: try JSONValue.from(p)),
            SyncRecord(kind: "deworming", id: "deworming_1", updatedAt: 11,
                       payload: try JSONValue.from(Deworming(id: "deworming_1", product: "Milbemax", date: "2026-08-18", next: "2026-10-30"))),
        ], rev: 2, sent: [])
        #expect(s.profile.name == "Stella")
        #expect(s.dues.first?.title == "Milbemax")
    }
}

@Suite("Erinnerungen an Gesundheit")
struct HealthReminderTests {
    @Test("Eine fällige Impfung erinnert am Tag um 8 Uhr")
    @MainActor func dueReminds() {
        let now = Calendar.gregorianLocal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        let due = HealthDue(id: "due_v", title: "Tollwut", kind: "Impfung", last: nil, due: Day(2026, 10, 20))
        let extra = CalendarBuilder.dogEntries(profile: DogProfile(), dues: [due])
        let list = Reminders.upcoming([], extra: extra, now: now)
        #expect(list.map(\.1.title) == ["Impfung fällig: Tollwut"])
        #expect(Calendar.gregorianLocal.component(.hour, from: list[0].0) == 8)
    }
}

@Suite("Rechner")
struct CalcTests {
    @Test("Tagesbedarf wie in der Web-App: 21,4 kg, nicht kastriert, normal aktiv")
    func energy() throws {
        var p = DogProfile(); p.weightKg = 21.4; p.birthdate = "2023-06-20"
        let e = try #require(Calc.energy(p, today: Day(2026, 10, 18)))
        #expect(abs(e.rer - 70 * pow(21.4, 0.75)) < 0.001)
        #expect(e.factor.value == 1.8)
        #expect(abs((Calc.grams(kcal: e.kcal, kcalPer100g: 350) ?? 0) - e.kcal / 3.5) < 0.001)
    }

    @Test("Faktor: Welpe, kastriert, ruhig, sehr aktiv, Senior")
    func factors() {
        var p = DogProfile(); p.weightKg = 30
        p.birthdate = "2026-08-01"
        #expect(Calc.factor(p, today: Day(2026, 10, 18)).value == 3.0)
        p.birthdate = "2026-01-01"
        #expect(Calc.factor(p, today: Day(2026, 10, 18)).value == 2.0)
        p.birthdate = "2019-01-01"; p.neutered = true; p.activity = "low"
        #expect(Calc.factor(p, today: Day(2026, 10, 18)).value == 1.2)   // 1,6 − 0,2 ruhig − 0,2 Senior (über 25 kg ab 84 Monaten)
        p.neutered = false; p.activity = "high"; p.birthdate = "2023-01-01"
        #expect(Calc.factor(p, today: Day(2026, 10, 18)).value == 2.2)
    }

    @Test("Mit Wunschgewicht rechnet der Bedarf auf das Wunschgewicht")
    func target() throws {
        var p = DogProfile(); p.weightKg = 24; p.targetWeightKg = 21
        let e = try #require(Calc.energy(p, useTarget: true))
        #expect(e.kg == 21)
    }

    @Test("Asphalt: Sommermittag wie die Messreihen, Herbst und Nacht nahe der Luft, Grenzen 43 und 52 °C")
    func asphalt() {
        let f = ISO8601DateFormatter()
        func surface(_ air: Double, cloud: Double = 0, wind: Double = 3, _ when: String) -> Double {
            Asphalt.surface(.init(air: air, cloud: cloud, wind: wind, lat: 48.21, lon: 16.37), at: f.date(from: when)!)
        }
        // Wien, Juli, 13 Uhr, klar: Messreihen sagen 51 °C bei 25 °C und 60 °C bei 30 °C Luft.
        #expect(abs(surface(25, "2026-07-15T11:00:00Z") - 51) < 4)
        #expect(abs(surface(30, "2026-07-15T11:00:00Z") - 60) < 4)
        // Bewölkt oder windig deutlich kühler.
        #expect(surface(30, cloud: 1, "2026-07-15T11:00:00Z") < 43)
        #expect(surface(30, wind: 8, "2026-07-15T11:00:00Z") < surface(30, "2026-07-15T11:00:00Z") - 5)
        // November, Mittag, 5 °C: kaum wärmer als die Luft; nachts nicht wärmer.
        #expect(surface(5, cloud: 0.9, "2026-11-11T11:00:00Z") < 13)
        #expect(surface(5, "2026-11-11T20:00:00Z") <= 5)
        #expect(Calc.paws(surface: 51) == .warn)
        #expect(Calc.paws(surface: 52) == .bad)
        #expect(Calc.paws(surface: 42) == .ok)
    }

    @Test("Leckerli ein Zehntel, Wasser 50 bis 60 ml je kg")
    func treatsWater() {
        #expect(Calc.treats(kcal: 1000).kcal == 100)
        #expect(Calc.water(20) == 1000...1200)
    }
}

@Suite("Notfallpass")
@MainActor
struct EmergencyTests {
    @Test("Der Pass nimmt nur laufende Medikamente mit und die Felder aus dem Profil")
    func snapshot() throws {
        let s = DogStore(file: URL.temporaryDirectory.appending(path: "notfall-\(UUID().uuidString).json"))
        var p = DogProfile()
        p.name = "Stella"; p.sex = "f"; p.chip = "040098100123456"; p.ownerName = "Alex"; p.ownerPhone = "+43 660 1"
        p.allergies = "Huhn"
        s.save(p)
        let today = Day.today
        s.save(Medication(id: "m1", name: "Apoquel", dose: "1 Tablette", from: today.adding(days: -3).iso, to: today.adding(days: 4).iso))
        s.save(Medication(id: "m2", name: "Antibiotikum", dose: "", from: today.adding(days: -30).iso, to: today.adding(days: -2).iso))
        s.save(Medication(id: "m3", name: "Dauermedikament", dose: "", from: today.adding(days: -100).iso, to: ""))
        let card = EmergencySnapshot(store: s)
        #expect(card.name == "Stella" && card.sex == "Hündin" && card.important == "Huhn")
        #expect(card.meds.contains("Apoquel, 1 Tablette"))
        #expect(card.meds.contains("Dauermedikament"))
        #expect(!card.meds.contains("Antibiotikum"))
    }

    @Test("Hund-Seite: naher Geburtstag zuerst, sonst Menschenjahre")
    func dogFunFact() {
        let today = Day.today
        var p = DogProfile()
        p.name = "Stella"
        #expect(DogScreen.funFact(for: p, on: today) == nil)
        p.birthdate = today.adding(years: -2).iso
        #expect(DogScreen.funFact(for: p, on: today) == "Heute ist Geburtstag! Alles Gute, Stella!")
        p.birthdate = today.adding(days: 1).adding(years: -2).iso
        #expect(DogScreen.funFact(for: p, on: today) == "Morgen ist Geburtstag. Schon was besorgt?")
        p.birthdate = today.adding(days: 30).adding(years: -2).iso
        #expect(DogScreen.funFact(for: p, on: today) == "Noch 30 Tage bis zum Geburtstag.")
        p.birthdate = today.adding(days: -100).adding(years: -3).iso
        p.weightKg = 6
        #expect(DogScreen.funFact(for: p, on: today) == "In Menschenjahren etwa 29.")
    }

    @Test("Menschenjahre nach Größe")
    func humanYears() {
        #expect(DogScreen.humanYears(months: 6, weightKg: 6) == 8)
        #expect(DogScreen.humanYears(months: 24, weightKg: 6) == 24)
        #expect(DogScreen.humanYears(months: 48, weightKg: 6) == 32)
        #expect(DogScreen.humanYears(months: 48, weightKg: 40) == 38)
    }
}

@Suite("Duo-Erkennung")
struct DuoDetectionTests {
    @Test func duoOnlyWhenTall() {
        // iPhone quer: breiter Rand, aber wenig Höhe.
        #expect(!DeviceCode.looksLikeDuo(hasSideColumn: true, isPhone: true, verticallyCompact: true))
        // Duo aufgeklappt.
        #expect(DeviceCode.looksLikeDuo(hasSideColumn: true, isPhone: true, verticallyCompact: false))
        // iPad und iPhone hochkant.
        #expect(!DeviceCode.looksLikeDuo(hasSideColumn: true, isPhone: false, verticallyCompact: false))
        #expect(!DeviceCode.looksLikeDuo(hasSideColumn: false, isPhone: true, verticallyCompact: false))
    }
}

@MainActor
@Suite struct HealthNoteTests {
    @Test func syncsAndSummarizes() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString).json")
        let store = DogStore(file: file)
        var n = HealthNote(d: "2026-11-01"); n.time = "08:15"; n.tags = ["Erbrochen"]; n.text = "nach dem Frühstück"
        store.save(n)
        let out = store.outgoingRecords()
        #expect(out.contains { $0.kind == "notes" && $0.id == n.id })
        // Ein zweites Gerät bekommt den Eintrag.
        let other = DogStore(file: FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString).json"))
        other.applyIncoming(out, rev: 1, sent: [])
        #expect(other.notes.first?.tags == ["Erbrochen"])
        #expect(other.notes.first?.time == "08:15")
        let text = HealthDiarySection.vetSummary(other.notes, dog: "Stella", today: Day(iso: "2026-11-09")!)
        #expect(text.contains("Stella"))
        #expect(text.contains("Erbrochen: nach dem Frühstück"))
    }

    @Test func oldRecordWithoutFieldsDecodes() throws {
        let n = try JSONDecoder().decode(HealthNote.self, from: Data(#"{"id":"notes_1","d":"2026-10-01"}"#.utf8))
        #expect(n.tags.isEmpty && n.text.isEmpty && n.photo == nil)
    }

    @Test func photoFitsTheSyncLimit() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000)).image { ctx in
            for i in 0..<400 { UIColor(hue: CGFloat(i % 37) / 37, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: CGFloat(i * 97 % 4000), y: CGFloat(i * 53 % 3000), width: 300, height: 200)) }
        }
        let s = try #require(HealthNote.preparePhoto(big))
        #expect(s.count <= 60_000)
    }
}

@MainActor
@Suite struct LostDogTests {
    @Test func stampRoundTrip() throws {
        let d = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 14, minute: 5)))
        #expect(LostDog.stamp(d) == "2026-11-09T14:05")
        #expect(LostDog.date("2026-11-09T14:05") == d)
    }

    @Test func flyerHasTheEssentials() throws {
        let store = DogStore(file: FileManager.default.temporaryDirectory.appending(path: "lost-\(UUID().uuidString).json"))
        var p = DogProfile(); p.name = "Stella"; p.breed = "Zwergpudel"; p.ownerName = "Alex"; p.ownerPhone = "+43 660 1"
        p.lostSince = "2026-11-09T14:05"; p.lostWhere = "Augarten"; p.lostNote = "Rotes Halsband"
        store.save(p)
        let text = LostDog.flyer(EmergencySnapshot(store: store), url: URL(string: "https://thisdog.app/notfall/abc")!)
        #expect(text.hasPrefix("Stella wird vermisst!"))
        for part in ["Augarten", "Rotes Halsband", "+43 660 1", "https://thisdog.app/notfall/abc", "Zwergpudel"] { #expect(text.contains(part)) }
        // Ältere Profile ohne die Felder: nicht vermisst.
        let old = try JSONDecoder().decode(DogProfile.self, from: Data(#"{"name":"Stella"}"#.utf8))
        #expect(!old.isLost)
    }
}
