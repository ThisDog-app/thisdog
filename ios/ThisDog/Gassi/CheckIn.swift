import CoreLocation
import Foundation

/// Ein Check-in: Der Hund war an einem Ort. Liegt als Datensatz im Rudel (Art „checkin“) und ist damit
/// Ende-zu-Ende verschlüsselt; der Server zählt keine Besuche. Hundefreunde bekommen ihn drei Stunden lang
/// als eigenes, mit dem Schlüssel der Freundschaft verschlüsseltes Paket.
struct CheckIn: SyncedItem, Hashable {
    static let kind = "checkin"
    var id: String
    /// Kennung des Ortes beim Server („way/123“), sonst „Name@lat,lon“.
    var place: String
    var name: String
    /// Art des Ortes (dog_park, park …).
    var type: String
    var lat: Double
    var lon: Double
    /// Zeitpunkt in Millisekunden seit 1970.
    var at: Double
    var u: Double = 0

    var date: Date { Date(timeIntervalSince1970: at / 1000) }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    init(place p: Place, at date: Date = Date()) {
        id = "chk_" + UUID().uuidString.prefix(12).lowercased()
        place = p.serverID ?? "\(p.name)@\(String(format: "%.4f,%.4f", p.lat, p.lon))"
        name = p.name
        type = p.kind
        lat = p.lat
        lon = p.lon
        at = date.timeIntervalSince1970 * 1000
    }
}

/// Wann man einchecken kann und was daraus folgt.
enum CheckIns {
    /// So nah muss man sein: Parks werden mit ihrer Mitte geführt, deshalb großzügig.
    static let reach: CLLocationDistance = 300
    /// Unterwegs fragt die App, sobald man so nah an einem Ort ist.
    static let promptDistance: CLLocationDistance = 80
    /// Ein zweiter Check-in am selben Ort zählt erst nach dieser Zeit.
    static let again: TimeInterval = 2 * 3600

    static func inReach(_ p: Place, from here: CLLocationCoordinate2D?) -> Bool {
        guard let here else { return false }
        return Track.distance(here, p.coordinate) <= reach
    }

    /// Der letzte Check-in an diesem Ort, wenn er jünger als zwei Stunden ist.
    static func recent(_ p: Place, in all: [CheckIn], now: Date = Date()) -> CheckIn? {
        let key = CheckIn(place: p).place
        return all.filter { $0.place == key && now.timeIntervalSince($0.date) < again }.max { $0.at < $1.at }
    }

    /// „heute um 8:12“, „gestern“, „am Dienstag“, „am 3. Okt.“
    static func whenText(_ d: Date, today: Day = .today) -> String {
        let day = Day(date: d)
        switch day.days(until: today) {
        case 0: return String(localized: "heute um \(d.formatted(date: .omitted, time: .shortened))")
        case 1: return "gestern"
        case 2...6: return String(localized: "am \(Day.weekdayNames[day.weekdayFromMonday])")
        default: return String(localized: "am \(day.shortText)")
        }
    }

    static func visits(to p: Place, in all: [CheckIn]) -> [CheckIn] {
        let key = CheckIn(place: p).place
        return all.filter { $0.place == key }.sorted { $0.at > $1.at }
    }
}

extension CheckIns {
    /// Eincheckt: Datensatz im Rudel, Paket an die Hundefreunde, kurze Meldung mit Besuch oder neuem Abzeichen.
    @MainActor
    static func perform(_ p: Place, store: DogStore, account: Account) {
        let before = Revier(store.checkIns)
        let c = CheckIn(place: p)
        store.save(c)
        account.friends.checkedIn(c)
        let after = Revier(store.checkIns)
        let n = visits(to: p, in: store.checkIns).count
        let dog = store.profile.name.isEmpty ? String(localized: "Dein Hund") : store.profile.name
        let fresh = after.badges.first { !before.badges.contains($0) }
        account.notice = Notice(title: n == 1 ? String(localized: "Erster Besuch") : String(localized: "\(n). Besuch"),
                                body: fresh.map { String(localized: "Neues Abzeichen: \($0.title)") } ?? String(localized: "\(dog) in \(p.name)"),
                                fromPack: false, symbol: fresh?.symbol ?? "pin")
    }

    /// „Stellas Revier“, „Max’ Revier“.
    static func revierTitle(_ name: String) -> String {
        guard !name.isEmpty else { return String(localized: "Revier") }
        return name.hasSuffix("s") || name.hasSuffix("x") || name.hasSuffix("z") ? String(localized: "\(name)’ Revier") : String(localized: "\(name)s Revier")
    }
}

/// Stellas Revier: die besuchten Orte, ihre Besuche und Abzeichen.
struct Revier {
    struct Spot: Identifiable {
        let place: String
        let name: String
        let type: String
        let coordinate: CLLocationCoordinate2D
        let visits: Int
        let last: Date
        var id: String { place }
    }

    struct Badge: Identifiable, Equatable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
    }

    let spots: [Spot]
    let recent: [CheckIn]
    let total: Int
    let badges: [Badge]
    /// Was als Nächstes erreichbar ist, mit Fortschritt (z. B. „Stammgast: noch 3 Besuche“).
    let next: Badge?

    init(_ all: [CheckIn], now: Date = Date(), calendar: Calendar = .gregorianLocal) {
        let byPlace = Dictionary(grouping: all, by: \.place)
        spots = byPlace.values.compactMap { list -> Spot? in
            guard let last = list.max(by: { $0.at < $1.at }) else { return nil }
            return Spot(place: last.place, name: last.name, type: last.type, coordinate: last.coordinate, visits: list.count, last: last.date)
        }
        .sorted { ($0.visits, $0.last) > ($1.visits, $1.last) }
        recent = all.sorted { $0.at > $1.at }
        total = all.count

        var earned: [Badge] = []
        var next: Badge?
        let top = spots.first
        if let top, top.visits >= 10 {
            earned.append(Badge(id: "stammgast", symbol: "abzeichen", title: String(localized: "Stammgast"), detail: top.name))
        } else if let top {
            next = Badge(id: "stammgast", symbol: "abzeichen", title: String(localized: "Stammgast"), detail: String(localized: "noch \(10 - top.visits) Besuche in \(top.name)"))
        }
        if spots.count >= 5 {
            earned.append(Badge(id: "entdecken", symbol: "karte", title: String(localized: "Auf Entdeckungstour"), detail: String(localized: "\(spots.count) verschiedene Orte")))
        } else if next == nil, !spots.isEmpty {
            next = Badge(id: "entdecken", symbol: "karte", title: String(localized: "Auf Entdeckungstour"), detail: String(localized: "noch \(5 - spots.count) neue Orte"))
        }
        let sundays = Self.sundayStreak(all, now: now, calendar: calendar)
        if sundays >= 4 {
            earned.append(Badge(id: "sonntag", symbol: "sonne", title: String(localized: "Sonntagsrunde"), detail: String(localized: "\(sundays) Sonntage in Folge")))
        }
        badges = earned
        self.next = next
    }

    /// Wie viele Sonntage in Folge (bis zum letzten Sonntag) es mindestens einen Check-in gab.
    static func sundayStreak(_ all: [CheckIn], now: Date, calendar: Calendar) -> Int {
        let sundays = Set(all.compactMap { c -> Date? in
            calendar.component(.weekday, from: c.date) == 1 ? calendar.startOfDay(for: c.date) : nil
        })
        guard var day = calendar.nextDate(after: now, matching: DateComponents(weekday: 1), matchingPolicy: .nextTime, direction: .backward)
            .map({ calendar.startOfDay(for: $0) }) else { return 0 }
        if calendar.component(.weekday, from: now) == 1 { day = calendar.startOfDay(for: now) }
        // Ist heute Sonntag und noch nicht eingecheckt, zählt die Serie bis letzte Woche.
        if !sundays.contains(day) { day = calendar.date(byAdding: .day, value: -7, to: day)! }
        var n = 0
        while sundays.contains(day) {
            n += 1
            day = calendar.date(byAdding: .day, value: -7, to: day)!
        }
        return n
    }
}

#if DEBUG
extension DogStore {
    /// Für Bildschirmfotos (`-revier`): Check-ins an Wiener Orten der letzten Wochen, mit vier Sonntagen in Folge.
    func seedCheckIns(now: Date = Date()) {
        guard checkIns.isEmpty else { return }
        let cal = Calendar.gregorianLocal
        func place(_ id: String?, _ name: String, _ kind: String, _ lat: Double, _ lon: Double) -> Place {
            Place(name: name, kind: kind, label: kind == "dog_park" ? String(localized: "Hundezone") : String(localized: "Park"), rank: 0, lat: lat, lon: lon, serverID: id)
        }
        let zone = place("way/305847888", String(localized: "Hundezone Venediger-Au-Park"), "dog_park", 48.2194, 16.3942)
        let others = [place(nil, String(localized: "Venediger-Au-Park"), "park", 48.2191, 16.3953), place(nil, String(localized: "Rosa-Jochmann-Park"), "park", 48.2171, 16.3861),
                      place(nil, String(localized: "Hundezone Prater - Laufberg"), "dog_park", 48.2135, 16.4010), place(nil, String(localized: "Augarten"), "park", 48.2253, 16.3762)]
        var days: [Date] = (0..<23).map { cal.date(byAdding: .day, value: -[0, 1, 2, 4, 5, 7, 8, 9, 11, 12, 14, 15, 16, 18, 19, 21, 22, 23, 25, 26, 28, 30, 33][$0], to: now)! }
        // Die letzten vier Sonntage.
        var sunday = cal.nextDate(after: now, matching: DateComponents(weekday: 1), matchingPolicy: .nextTime, direction: .backward)!
        for _ in 0..<4 { days.append(sunday); sunday = cal.date(byAdding: .day, value: -7, to: sunday)! }
        for (i, d) in days.enumerated() {
            let at = cal.date(bySettingHour: 7 + i % 3, minute: 10 + i % 40, second: 0, of: d)!
            save(CheckIn(place: i < 23 ? zone : others[i % others.count], at: min(at, now.addingTimeInterval(-600))))
        }
        for (i, p) in others.enumerated() { save(CheckIn(place: p, at: cal.date(byAdding: .day, value: -3 - i * 2, to: now)!)) }
    }
}
#endif
