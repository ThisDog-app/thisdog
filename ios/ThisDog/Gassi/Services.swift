import CoreLocation
import Foundation
import Observation

/// Eine Adresse rund um den Hund: Tierarzt, Hundefriseur, Tierbedarf … (aus OpenStreetMap, api/services.php).
struct Service: Decodable, Identifiable, Hashable, Sendable {
    /// Kennung in OpenStreetMap („node/123“).
    let id: String
    let kind: String
    /// Die Art in Einzahl, vom Server („Tierarzt“).
    let label: String
    let name: String
    let lat: Double
    let lon: Double
    var street: String? = nil
    var city: String? = nil
    var phone: String? = nil
    var website: String? = nil
    /// Öffnungszeiten roh aus OpenStreetMap („Mo-Fr 08:00-18:00; Sa 09:00-12:00“).
    var hours: String? = nil
    /// Nur bei Tierärzten mit Notdienst.
    var emergency = false

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var serviceKind: ServiceKind? { ServiceKind(rawValue: kind) }
    /// Unbekannte Arten bekommen die Stecknadel.
    var icon: String { serviceKind?.icon ?? "pin" }

    /// „Tierarzt · Praterstraße 12“ – die zweite Zeile in der Liste.
    var line: String { ([label] + [street].compactMap { $0 }).joined(separator: " · ") }

    /// Je Tag eine Zeile.
    var hoursText: String? {
        guard let hours, !hours.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return hours.replacingOccurrences(of: "; ", with: "\n")
    }

    var websiteURL: URL? { website.flatMap(Self.websiteURL) }
    var phoneURL: URL? { phone.flatMap(Self.phoneURL) }

    /// OpenStreetMap kennt Adressen auch ohne „https://“ („www.example.at“); mehrere stehen mit „;“ getrennt.
    static func websiteURL(_ raw: String) -> URL? {
        let s = (raw.split(separator: ";").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let lower = s.lowercased()
        let full = lower.hasPrefix("http://") || lower.hasPrefix("https://") ? s : "https://" + s.drop { $0 == "/" }
        guard let url = URL(string: full), let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    /// „+43 1 2345678“ → tel:+4312345678; die erste Nummer, wenn mehrere dastehen.
    static func phoneURL(_ raw: String) -> URL? {
        let first = raw.split(separator: ";").first.map(String.init) ?? ""
        let digits = first.filter { $0.isNumber || $0 == "+" }
        guard digits.count >= 3 else { return nil }
        return URL(string: "tel:" + digits)
    }
}

extension Service {
    private enum Keys: String, CodingKey { case id, place, kind, label, name, lat, lon, street, city, phone, website, hours, emergency }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // Beim Sponsor ist „id“ die Nummer der Anzeige; der Ort steht unter „place“.
        id = try c.decodeIfPresent(String.self, forKey: .place) ?? c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        name = try c.decode(String.self, forKey: .name)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        street = try? c.decodeIfPresent(String.self, forKey: .street)
        city = try? c.decodeIfPresent(String.self, forKey: .city)
        phone = try? c.decodeIfPresent(String.self, forKey: .phone)
        website = try? c.decodeIfPresent(String.self, forKey: .website)
        hours = try? c.decodeIfPresent(String.self, forKey: .hours)
        emergency = (try? c.decodeIfPresent(Bool.self, forKey: .emergency)) ?? false
    }
}

/// Der gesponserte Platz einer Gegend: ein Eintrag wie die anderen, dazu Anzeigentext und wer bezahlt hat.
struct ServiceSponsor: Decodable, Hashable, Sendable {
    /// Nummer der Anzeige (fürs Zählen der Antipper).
    let id: Int
    let entry: Service
    var text: String? = nil
    var advertiser: String? = nil

    private enum Keys: String, CodingKey { case id, text, advertiser }

    init(id: Int, entry: Service, text: String? = nil, advertiser: String? = nil) {
        self.id = id; self.entry = entry; self.text = text; self.advertiser = advertiser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(Int.self, forKey: .id)
        entry = try Service(from: decoder)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        advertiser = try? c.decodeIfPresent(String.self, forKey: .advertiser)
    }
}

/// Die Antwort von api/services.php.
struct ServiceAnswer: Decodable, Sendable {
    var services: [Service] = []
    var sponsor: ServiceSponsor? = nil
    /// false: Für diese Gegend gibt es keinen Auszug (außerhalb von Deutschland, Österreich und der Schweiz).
    var covered = true

    private enum Keys: String, CodingKey { case services, sponsor, covered }

    init(services: [Service] = [], sponsor: ServiceSponsor? = nil, covered: Bool = true) {
        self.services = services; self.sponsor = sponsor; self.covered = covered
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        services = try c.decodeIfPresent([Service].self, forKey: .services) ?? []
        sponsor = try c.decodeIfPresent(ServiceSponsor.self, forKey: .sponsor)
        covered = try c.decodeIfPresent(Bool.self, forKey: .covered) ?? true
    }
}

/// Die Arten, in der Reihenfolge der Chips.
enum ServiceKind: String, CaseIterable, Identifiable, Sendable {
    case vet, groomer, shop, school, shelter, boarding, cafe
    var id: String { rawValue }

    /// Der Chip, in Mehrzahl.
    var title: String {
        switch self {
        case .vet: String(localized: "Tierärzte")
        case .groomer: String(localized: "Hundefriseure")
        case .shop: String(localized: "Tierbedarf")
        case .school: String(localized: "Hundeschulen")
        case .shelter: String(localized: "Tierheime")
        case .boarding: String(localized: "Pensionen")
        case .cafe: String(localized: "Lokale")
        }
    }

    var icon: String {
        switch self {
        case .vet: "tierarzt"
        case .groomer: "schere"
        case .shop: "laden"
        case .school: "pfeife"
        case .shelter: "herz"
        case .boarding: "haus"
        case .cafe: "tasse"
        }
    }
}

/// Was die Liste zeigt: gewählter Chip (nil = Alle) und Suchtext. Ohne Oberfläche, damit es sich prüfen lässt.
enum ServiceFilter {
    /// Ab so vielen Zeichen fragt die Suche auch den Server (weiterer Umkreis).
    static let serverQueryLength = 3

    /// Chips nur für Arten, die es in der Antwort gibt – in der festen Reihenfolge.
    static func kinds(_ services: [Service], sponsor: ServiceSponsor?) -> [ServiceKind] {
        let present = Set(services.map(\.kind) + [sponsor?.entry.kind].compactMap { $0 })
        return ServiceKind.allCases.filter { present.contains($0.rawValue) }
    }

    /// Name, Art oder Straße enthält den Suchtext (ohne Rücksicht auf Groß- und Kleinschreibung oder Akzente).
    static func matches(_ s: Service, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let fields = [s.name, s.label, s.street ?? "", s.serviceKind?.title ?? ""]
        return fields.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func matches(_ s: Service, kind: ServiceKind?) -> Bool {
        kind == nil || s.kind == kind?.rawValue
    }

    /// Die Liste: Was in der Nähe zum Suchtext passt, dazu die Treffer der Serversuche (nach Kennung vereint),
    /// gefiltert nach Chip und nach Entfernung sortiert. Der Sponsor steht nie zusätzlich darin.
    static func list(nearby: [Service], found: [Service] = [], kind: ServiceKind?, query: String,
                     sponsor: ServiceSponsor? = nil, from here: CLLocationCoordinate2D? = nil) -> [Service] {
        var seen = Set<String>([sponsor?.entry.id].compactMap { $0 })
        var out: [Service] = []
        for s in nearby where matches(s, query: query) && seen.insert(s.id).inserted { out.append(s) }
        // Der Server sucht großzügiger (Namen im weiteren Umkreis); was er findet, gilt als Treffer.
        for s in found where seen.insert(s.id).inserted { out.append(s) }
        out = out.filter { matches($0, kind: kind) }
        if let here { out.sort { Track.distance(here, $0.coordinate) < Track.distance(here, $1.coordinate) } }
        return out
    }

    /// Der Sponsor erscheint nur, wenn er zum Chip (Alle oder gleiche Art) und zum Suchtext passt.
    static func showsSponsor(_ sponsor: ServiceSponsor?, kind: ServiceKind?, query: String) -> Bool {
        guard let sponsor else { return false }
        return matches(sponsor.entry, kind: kind) && matches(sponsor.entry, query: query)
    }
}

/// Holt Adressen beim Server – ohne Anmeldung, über dieselbe Schnittstelle wie die Orte.
enum ServiceFinder {
    /// Ab so vielen Metern weg von der letzten Suche wird neu gesucht (wie bei den Orten).
    static let refreshDistance: Double = 250

    static func near(_ here: CLLocationCoordinate2D) async throws -> ServiceAnswer {
        #if DEBUG
        if ServiceDemo.isOn { return ServiceDemo.answer(around: here) }
        #endif
        return try await Api().get("services.php", query(here))
    }

    /// Namenssuche im weiteren Umkreis (ca. 30 km).
    static func search(_ text: String, near here: CLLocationCoordinate2D) async throws -> ServiceAnswer {
        #if DEBUG
        if ServiceDemo.isOn { return ServiceAnswer() }
        #endif
        var q = query(here)
        q["q"] = text
        return try await Api().get("services.php", q)
    }

    /// Der Sponsor wurde angetippt. Ob das ankommt, ist egal.
    static func tap(_ sponsor: Int) {
        #if DEBUG
        if ServiceDemo.isOn { return }
        #endif
        struct Body: Encodable { let action = "tap"; let sponsor: Int }
        Task.detached { let _: Ok? = try? await Api().post("services.php", body: Body(sponsor: sponsor)) }
    }

    /// Auf zwei Stellen gerundet, wie bei places.php.
    private static func query(_ here: CLLocationCoordinate2D) -> [String: String] {
        ["lat": String(format: "%.2f", here.latitude), "lon": String(format: "%.2f", here.longitude)]
    }
}

/// Was der Reiter „Adressen“ geladen hat und was gerade gewählt ist. Lebt so lange wie die Gassi-Seite.
@MainActor @Observable
final class ServiceList {
    private(set) var services: [Service] = []
    private(set) var sponsor: ServiceSponsor?
    private(set) var covered = true
    private(set) var loading = false
    private(set) var failed = false
    /// Treffer der Serversuche für `query`.
    private(set) var found: [Service] = []
    private(set) var center: CLLocationCoordinate2D?

    var kind: ServiceKind? { didSet { if kind != oldValue { shown = Self.page } } }
    var query = "" { didSet { if query != oldValue { shown = Self.page } } }
    /// So viele Zeilen zeigt die Liste; „Mehr zeigen“ legt eine Seite drauf.
    var shown = ServiceList.page
    static let page = 30
    /// Die Adresse, deren Seite offen ist.
    var selected: Service?

    var loaded: Bool { center != nil }

    func list(from here: CLLocationCoordinate2D?) -> [Service] {
        ServiceFilter.list(nearby: services, found: query.count >= ServiceFilter.serverQueryLength ? found : [],
                           kind: kind, query: query, sponsor: sponsor, from: here)
    }

    var showsSponsor: Bool { ServiceFilter.showsSponsor(sponsor, kind: kind, query: query) }
    var kinds: [ServiceKind] { ServiceFilter.kinds(services, sponsor: sponsor) }

    func isSponsor(_ s: Service) -> Bool { sponsor?.entry.id == s.id }

    /// Beim ersten Öffnen laden, danach erst wieder nach 250 m.
    func refresh(_ here: CLLocationCoordinate2D, force: Bool = false) async {
        if !force, let center, Track.distance(center, here) < ServiceFinder.refreshDistance { return }
        guard !loading else { return }
        loading = true
        failed = false
        center = here
        do {
            let a = try await ServiceFinder.near(here)
            services = a.services
            sponsor = a.sponsor
            covered = a.covered
            if let kind, !kinds.contains(kind) { self.kind = nil }
            #if DEBUG
            // Für Bildschirmfotos: `-adressenseite node/1` oder `-adressenseite anzeige` öffnet die Seite,
            // `-adressenart vet` wählt einen Chip, `-adressensuche text` sucht.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-adressenart"), i + 1 < args.count { kind = ServiceKind(rawValue: args[i + 1]) }
            if let i = args.firstIndex(of: "-adressensuche"), i + 1 < args.count { query = args[i + 1] }
            if let i = args.firstIndex(of: "-adressenseite"), i + 1 < args.count {
                selected = args[i + 1] == "anzeige" ? sponsor?.entry : services.first { $0.id == args[i + 1] }
            }
            #endif
        } catch {
            failed = true
            // Nochmal versuchen dürfen, auch ohne 250 m zu gehen.
            if services.isEmpty { center = nil }
        }
        loading = false
    }

    /// Ab drei Zeichen zusätzlich beim Server suchen (entprellt).
    func search(near here: CLLocationCoordinate2D) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= ServiceFilter.serverQueryLength else { found = []; return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let a = try? await ServiceFinder.search(text, near: here)
        guard !Task.isCancelled, text == query.trimmingCharacters(in: .whitespaces) else { return }
        found = a?.services ?? []
    }
}

#if DEBUG
/// Beispieldaten für Bildschirmfotos ohne Server (`-adressen-demo`). Im Format des Servers; lat und lon sind hier
/// Abstände zum Standort, damit die Punkte um einen herum liegen.
enum ServiceDemo {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-adressen-demo") }

    static func answer(around c: CLLocationCoordinate2D) -> ServiceAnswer {
        guard let a = try? JSONDecoder().decode(ServiceAnswer.self, from: Data(json.utf8)) else { return ServiceAnswer() }
        func move(_ s: Service) -> Service {
            var m = Service(id: s.id, kind: s.kind, label: s.label, name: s.name, lat: c.latitude + s.lat, lon: c.longitude + s.lon)
            m.street = s.street; m.city = s.city; m.phone = s.phone; m.website = s.website; m.hours = s.hours; m.emergency = s.emergency
            return m
        }
        return ServiceAnswer(services: a.services.map(move),
                             sponsor: a.sponsor.map { ServiceSponsor(id: $0.id, entry: move($0.entry), text: $0.text, advertiser: $0.advertiser) },
                             covered: true)
    }

    private static let json = """
    {"services": [
      {"id": "node/1", "kind": "vet", "label": "Tierarzt", "name": "Tierklinik Praterstern", "lat": 0.0012, "lon": 0.0021,
       "street": "Praterstraße 12", "city": "1020 Wien", "phone": "+43 1 2345678", "website": "www.example.at",
       "hours": "Mo-Fr 08:00-18:00; Sa 09:00-12:00", "emergency": true},
      {"id": "node/2", "kind": "shop", "label": "Tierbedarf", "name": "Futterhaus Taborstraße", "lat": 0.0030, "lon": -0.0015,
       "street": "Taborstraße 38", "city": "1020 Wien", "hours": "Mo-Sa 09:00-19:00"},
      {"id": "node/3", "kind": "cafe", "label": "Hundefreundliches Lokal", "name": "Café Wurstel", "lat": -0.0024, "lon": 0.0030,
       "street": "Ausstellungsstraße 5", "city": "1020 Wien"},
      {"id": "node/4", "kind": "school", "label": "Hundeschule", "name": "Hundeschule Augarten", "lat": 0.0061, "lon": -0.0040,
       "website": "https://example.org"},
      {"id": "node/5", "kind": "vet", "label": "Tierarzt", "name": "Tierarztpraxis Dr. Lehner", "lat": -0.0055, "lon": -0.0062,
       "street": "Große Mohrengasse 7", "city": "1020 Wien", "phone": "+43 1 9876543"},
      {"id": "node/6", "kind": "groomer", "label": "Hundefriseur", "name": "Pfotenpflege Leopoldstadt", "lat": 0.0080, "lon": 0.0071,
       "street": "Heinestraße 21", "city": "1020 Wien"},
      {"id": "node/7", "kind": "shelter", "label": "Tierheim", "name": "Tierschutzhaus am Rand", "lat": -0.0140, "lon": 0.0120},
      {"id": "node/8", "kind": "boarding", "label": "Hundepension", "name": "Hundehotel Lobau", "lat": -0.0180, "lon": 0.0240,
       "street": "Lobgrundstraße 3", "city": "1220 Wien"},
      {"id": "node/9", "kind": "vet", "label": "Tierarzt", "name": "Kleintierpraxis Mexikoplatz", "lat": 0.0110, "lon": 0.0150,
       "street": "Mexikoplatz 2", "city": "1020 Wien", "hours": "Mo,We,Fr 09:00-12:00"},
      {"id": "node/10", "kind": "shop", "label": "Tierbedarf", "name": "Napf & Leine", "lat": 0.0150, "lon": -0.0120}
    ],
    "sponsor": {"id": 12, "place": "node/456", "kind": "groomer", "label": "Hundefriseur", "name": "Salon Struppi",
      "lat": 0.0021, "lon": 0.0042, "street": "Rotensterngasse 9", "city": "1020 Wien", "phone": "+43 660 1234567",
      "website": "struppi.example.at", "hours": "Di-Fr 10:00-18:00; Sa 09:00-13:00",
      "text": "Erste Pflege für Welpen gratis", "advertiser": "Struppi GmbH"},
    "covered": true}
    """
}
#endif
