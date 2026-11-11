import CoreLocation
import MapKit

/// Ein Ziel für die Runde: Hundezone, Park, Wald, Wiese.
struct Place: Decodable, Identifiable, Hashable, Sendable {
    var name: String
    let kind: String
    let label: String
    let rank: Int
    let lat: Double
    let lon: Double
    /// Kennung beim Server („way/123“, „wien/5“, „eigen/7“); nil bei Orten aus Apple Karten.
    var serverID: String? = nil
    /// Was die Daten sagen (OpenStreetMap, Stadt Wien, ThisDog): Merkmal → Wert und Quelle.
    var facts: [String: Fact] = [:]
    /// Bewertungen: Merkmal → [ja, nein]; wie viele Konten bewertet haben; Hundegrößen [klein, mittel, groß].
    var votes: [String: [Int]] = [:]
    var voters = 0
    var sizes = [0, 0, 0]
    /// Von einem Nutzer eingetragen.
    var byUser = false
    /// Freigegebene Fotos (Kennung beim Server) und wann ThisDog den Ort vor Ort geprüft hat (Sekunden seit 1970).
    var photos: [Photo] = []
    var checkedAt: Double? = nil

    struct Photo: Decodable, Hashable, Sendable, Identifiable {
        let id: Int
        let w: Int
        let h: Int
        var url: URL { Api.base.appending(path: "photo.php").appending(queryItems: [URLQueryItem(name: "id", value: String(id))]) }
        var thumb: URL { url.appending(queryItems: [URLQueryItem(name: "klein", value: "1")]) }
    }

    struct Fact: Decodable, Hashable, Sendable {
        let v: Int
        let src: String
    }

    var id: String { serverID ?? "\(kind):\(lat),\(lon)" }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var isDogZone: Bool { kind == "dog_park" }

    /// Aus Luftlinie eine Runde schätzen: Umwegzuschlag 1,3 für Fußwege, hin und zurück –
    /// wie in der Web-App. Wer ein Ziel öffnet, bekommt den echten Weg.
    func roundTrip(from here: CLLocationCoordinate2D) -> Double {
        Track.distance(here, coordinate) * 1.3 * 2
    }

    /// Gemütliches Hundetempo: 66 m in der Minute.
    static func minutes(for meters: Double) -> Int { Int((meters / 66).rounded()) }
}

extension Place {
    private enum Keys: String, CodingKey { case id, name, kind, label, rank, lat, lon, facts, votes, voters, sizes, byUser, photos, checkedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        rank = try c.decode(Int.self, forKey: .rank)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        serverID = try c.decodeIfPresent(String.self, forKey: .id)
        facts = (try? c.decodeIfPresent([String: Fact].self, forKey: .facts)) ?? [:]
        votes = (try? c.decodeIfPresent([String: [Int]].self, forKey: .votes)) ?? [:]
        voters = (try? c.decodeIfPresent(Int.self, forKey: .voters)) ?? 0
        sizes = (try? c.decodeIfPresent([Int].self, forKey: .sizes)) ?? [0, 0, 0]
        byUser = (try? c.decodeIfPresent(Bool.self, forKey: .byUser)) ?? false
        photos = (try? c.decodeIfPresent([Photo].self, forKey: .photos)) ?? []
        checkedAt = try? c.decodeIfPresent(Double.self, forKey: .checkedAt)
    }
}

/// Was man an einem Ort bewerten kann – dieselben Schlüssel wie api/place.php.
enum PlaceFeature: String, CaseIterable, Identifiable, Sendable {
    case offLeash = "off_leash", fenced, water, clean, grass, shade, bench, bags, split
    var id: String { rawValue }

    /// Was man an diesem Ort fragt: Ob es getrennte Bereiche für große und kleine Hunde gibt, nur bei Hundezonen.
    static func all(dogZone: Bool) -> [PlaceFeature] { dogZone ? allCases : allCases.filter { $0 != .split } }
    static func all(for p: Place) -> [PlaceFeature] { all(dogZone: p.isDogZone) }

    var title: String {
        switch self {
        case .offLeash: String(localized: "Freilaufen möglich")
        case .fenced: String(localized: "Eingezäunt")
        case .water: String(localized: "Trinkwasser")
        case .clean: String(localized: "Sauber")
        case .grass: String(localized: "Rasen")
        case .shade: String(localized: "Schatten")
        case .bench: String(localized: "Bänke")
        case .bags: String(localized: "Kotbeutelspender")
        case .split: String(localized: "Getrennt für große und kleine Hunde")
        }
    }

    var short: String {
        switch self {
        case .offLeash: String(localized: "Freilaufen")
        case .bags: String(localized: "Kotbeutel")
        case .split: String(localized: "Groß und klein getrennt")
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .offLeash: "hund"
        case .fenced: "zaun"
        case .water: "tropfen"
        case .clean: "sauber"
        case .grass: "blatt"
        case .shade: "park"
        case .bench: "bank"
        case .bags: "beutel"
        case .split: "teilung"
        }
    }
}

/// Was die Ortsseite über ein Merkmal sagt.
enum PlaceVerdict: Equatable {
    /// Gibt es / gibt es nicht / teilweise – mit Quelle (nil = die Bewertungen).
    case yes(String?), no(String?), partly(String?)
    /// Die Bewertungen sind sich nicht einig.
    case unsure(yes: Int, of: Int)
}

extension Place {
    /// Ab so vielen Bewertungen zählen die Stimmen; darunter gilt, was die Daten sagen.
    static let enoughVoters = 3

    var enoughVotes: Bool { voters >= Self.enoughVoters }

    /// Mindestens drei Viertel ja: gibt es. Höchstens ein Viertel: gibt es nicht. Dazwischen uneinig.
    func verdict(_ f: PlaceFeature) -> PlaceVerdict? {
        // Vor Ort geprüft gilt vor allem anderen, bis jemand neu prüft.
        if let fact = facts[f.rawValue], fact.src == "thisdog" { return fact.v == 1 ? .yes("thisdog") : .no("thisdog") }
        let v = votes[f.rawValue] ?? [0, 0]
        let n = v.reduce(0, +)
        if enoughVotes, n > 0 {
            let share = Double(v[0]) / Double(n)
            if share >= 0.75 { return .yes(nil) }
            if share <= 0.25 { return .no(nil) }
            return .unsure(yes: v[0], of: n)
        }
        guard let fact = facts[f.rawValue] else { return nil }
        switch fact.v {
        case 1: return .yes(fact.src)
        case 0: return .no(fact.src)
        default: return .partly(fact.src)
        }
    }

    /// Weitere Angaben aus den Daten, die man nicht bewertet: Mülleimer, Licht, Tränke.
    /// (Kotbeutel lassen sich bewerten und stehen bei den Merkmalen.)
    var extras: [(symbol: String, title: String)] {
        [("water_bowl", "napf", String(localized: "Hundetränke")), ("bin", "muell", String(localized: "Mülleimer")), ("lit", "lampe", String(localized: "Beleuchtet"))]
            .compactMap { key, symbol, title in facts[key]?.v == 1 ? (symbol, title) : nil }
    }

    /// Fläche in m², wenn bekannt (Stadt Wien).
    var area: Int? { facts["area"]?.v }

    /// In Teilen des Parks gilt Hundeverbot (Stadt Wien).
    var hasNoDogsArea: Bool { facts["no_dogs_area"]?.v == 1 }

    /// Wer die Daten liefert, für die Zeile unter den Merkmalen.
    var sourceNote: String {
        let src = Set(facts.values.map(\.src))
        var parts: [String] = []
        if byUser { parts.append(String(localized: "Eingetragen von Menschen mit Hund")) }
        else if serverID?.hasPrefix("eigen/") == true { parts.append(String(localized: "Eingetragen von ThisDog")) }
        else { parts.append(String(localized: "Aus OpenStreetMap")) }
        if src.contains("wien") { parts.append(String(localized: "ergänzt mit Daten der Stadt Wien (CC BY 4.0)")) }
        return parts.joined(separator: ", ")
    }

    static func sourceLabel(_ src: String?) -> String {
        switch src {
        case "wien": String(localized: "Laut Stadt Wien")
        case "eigen", "thisdog": String(localized: "Laut ThisDog")
        default: String(localized: "Laut Karte")
        }
    }
}

/// Holt Ziele in der Nähe. Erst vom eigenen Server (OpenStreetMap, mit Hundezonen); antwortet der
/// nicht, aus Apple Karten (nur Parks – Hundezonen kennt Apple nicht).
@MainActor
enum PlaceFinder {
    static let radius: Double = 3000
    /// Ab so vielen Metern weg von der letzten Suche wird neu gesucht.
    static let refreshDistance: Double = 250

    /// Was zuletzt gefunden wurde – für die Watch, die selbst nicht sucht.
    private(set) static var lastFound: [Place] = []
    /// Neue Ziele gefunden.
    static var onFound: (() -> Void)?

    static func near(_ here: CLLocationCoordinate2D) async -> [Place] {
        var found = await fromServer(here)
        if found.isEmpty { found = await fromApple(here) }
        let sorted = found
            .filter { Track.distance(here, $0.coordinate) <= radius }
            .sorted { (Track.distance(here, $0.coordinate), $0.rank) < (Track.distance(here, $1.coordinate), $1.rank) }
        if !sorted.isEmpty { lastFound = sorted; onFound?() }
        return sorted
    }

    private static func fromServer(_ here: CLLocationCoordinate2D) async -> [Place] {
        struct Answer: Decodable { let places: [Place] }
        // Auf zwei Stellen gerundet (rund 1 km) – so grob rechnet der Server ohnehin (eine Zelle je Kilometer),
        // und mehr steht dann auch in keinem Zugriffsprotokoll.
        let q = ["lat": String(format: "%.2f", here.latitude), "lon": String(format: "%.2f", here.longitude)]
        let a: Answer? = try? await Api().get("places.php", q)
        return a?.places ?? []
    }

    private static func fromApple(_ here: CLLocationCoordinate2D) async -> [Place] {
        let req = MKLocalPointsOfInterestRequest(center: here, radius: radius)
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .nationalPark])
        guard let r = try? await MKLocalSearch(request: req).start() else { return [] }
        var seen = Set<String>()
        return r.mapItems.compactMap { item in
            // Eingänge stehen bei Apple als eigene Orte – sie sind kein Ziel, sondern ein Teil davon.
            guard let name = item.name, !name.hasPrefix(String(localized: "Eingang")), seen.insert(name).inserted else { return nil }
            let c = item.location.coordinate
            let dogZone = [String(localized: "Hundezone"), String(localized: "Hundeauslauf"), String(localized: "Hundewiese"), String(localized: "Hundefreilauf"), String(localized: "Hundespielplatz")].contains { name.contains($0) }
            return Place(name: name, kind: dogZone ? "dog_park" : "park", label: dogZone ? String(localized: "Hundezone") : String(localized: "Park"),
                         rank: dogZone ? 0 : 1, lat: c.latitude, lon: c.longitude)
        }
    }
}
