import CoreLocation
import Foundation
import Testing
@testable import ThisDog

@Suite("Adressen")
struct ServiceTests {
    private func answer(_ json: String) throws -> ServiceAnswer {
        try JSONDecoder().decode(ServiceAnswer.self, from: Data(json.utf8))
    }

    // MARK: Dekodieren

    @Test func liestBeispielantwortMitAllenFeldernUndSponsor() throws {
        let a = try answer(#"""
        {"services": [{"id": "node/123", "kind": "vet", "label": "Tierarzt", "name": "Tierklinik Praterstern",
           "lat": 48.2185, "lon": 16.3921, "street": "Praterstraße 12", "city": "1020 Wien",
           "phone": "+43 1 2345678", "website": "https://example.at", "hours": "Mo-Fr 08:00-18:00; Sa 09:00-12:00",
           "emergency": true}],
         "sponsor": {"id": 12, "place": "node/456", "kind": "groomer", "label": "Hundefriseur", "name": "Salon Struppi",
           "lat": 48.21, "lon": 16.38, "street": "Gasse 1", "city": "1020 Wien", "phone": "+43 660 1", "website": "struppi.at",
           "hours": "Di-Fr 10:00-18:00", "text": "Erste Pflege für Welpen gratis", "advertiser": "Struppi GmbH"},
         "covered": true}
        """#)
        #expect(a.covered)
        let s = try #require(a.services.first)
        #expect(s.id == "node/123")
        #expect(s.serviceKind == .vet)
        #expect(s.icon == "tierarzt")
        #expect(s.street == "Praterstraße 12")
        #expect(s.city == "1020 Wien")
        #expect(s.emergency)
        #expect(s.line == "Tierarzt · Praterstraße 12")
        #expect(s.hoursText == "Mo-Fr 08:00-18:00\nSa 09:00-12:00")
        #expect(s.phoneURL?.absoluteString == "tel:+4312345678")

        let sp = try #require(a.sponsor)
        #expect(sp.id == 12)
        // Die Kennung des Eintrags ist der Ort, nicht die Nummer der Anzeige.
        #expect(sp.entry.id == "node/456")
        #expect(sp.entry.serviceKind == .groomer)
        #expect(sp.text == "Erste Pflege für Welpen gratis")
        #expect(sp.advertiser == "Struppi GmbH")
        #expect(sp.entry.websiteURL?.absoluteString == "https://struppi.at")
    }

    @Test func ohneOptionaleFelderUndOhneSponsor() throws {
        let a = try answer(#"{"services": [{"id": "way/9", "kind": "dog_spa", "label": "Etwas Neues", "name": "Wellness", "lat": 48.2, "lon": 16.4}], "sponsor": null, "covered": true}"#)
        let s = try #require(a.services.first)
        #expect(s.street == nil && s.city == nil && s.phone == nil && s.website == nil && s.hours == nil)
        #expect(!s.emergency)
        #expect(s.hoursText == nil)
        #expect(s.websiteURL == nil)
        #expect(s.phoneURL == nil)
        #expect(s.line == "Etwas Neues")
        // Unbekannte Art: Stecknadel.
        #expect(s.serviceKind == nil)
        #expect(s.icon == "pin")
        #expect(a.sponsor == nil)
    }

    @Test func sponsorOhneTextUndAuftraggeber() throws {
        let a = try answer(#"{"services": [], "sponsor": {"id": 3, "place": "node/1", "kind": "shop", "label": "Tierbedarf", "name": "Napf", "lat": 48.2, "lon": 16.4}, "covered": true}"#)
        let sp = try #require(a.sponsor)
        #expect(sp.text == nil)
        #expect(sp.advertiser == nil)
        #expect(sp.entry.id == "node/1")
    }

    @Test func nichtAbgedeckteGegend() throws {
        let a = try answer(#"{"services": [], "sponsor": null, "covered": false}"#)
        #expect(!a.covered)
        #expect(a.services.isEmpty)
    }

    // MARK: Filter

    private let nearby = [
        Service(id: "node/1", kind: "vet", label: "Tierarzt", name: "Tierklinik Praterstern", lat: 48.212, lon: 16.37, street: "Praterstraße 12"),
        Service(id: "node/2", kind: "shop", label: "Tierbedarf", name: "Futterhaus", lat: 48.215, lon: 16.37, street: "Taborstraße 38"),
        Service(id: "node/3", kind: "vet", label: "Tierarzt", name: "Praxis Lehner", lat: 48.230, lon: 16.37),
        Service(id: "node/4", kind: "cafe", label: "Hundefreundliches Lokal", name: "Café Wurstel", lat: 48.211, lon: 16.37),
    ]
    private let sponsor = ServiceSponsor(id: 12, entry: Service(id: "node/456", kind: "groomer", label: "Hundefriseur", name: "Salon Struppi", lat: 48.21, lon: 16.38),
                                         text: "Gratis", advertiser: "Struppi GmbH")
    private let here = CLLocationCoordinate2D(latitude: 48.21, longitude: 16.37)

    @Test func chipFiltertNachArt() {
        let vets = ServiceFilter.list(nearby: nearby, kind: .vet, query: "", from: here)
        #expect(vets.map(\.id) == ["node/1", "node/3"])
        let all = ServiceFilter.list(nearby: nearby, kind: nil, query: "", from: here)
        // Nach Entfernung sortiert.
        #expect(all.map(\.id) == ["node/4", "node/1", "node/2", "node/3"])
    }

    @Test func suchtextNachNameArtUndStrasse() {
        #expect(ServiceFilter.list(nearby: nearby, kind: nil, query: "wurstel").map(\.id) == ["node/4"])
        #expect(ServiceFilter.list(nearby: nearby, kind: nil, query: "tierarzt").map(\.id) == ["node/1", "node/3"])
        #expect(ServiceFilter.list(nearby: nearby, kind: nil, query: "taborstr").map(\.id) == ["node/2"])
        // Die Mehrzahl des Chips findet auch.
        #expect(ServiceFilter.list(nearby: nearby, kind: nil, query: "Tierärzte").map(\.id) == ["node/1", "node/3"])
        // Chip und Suchtext zusammen.
        #expect(ServiceFilter.list(nearby: nearby, kind: .shop, query: "prater").isEmpty)
        #expect(ServiceFilter.list(nearby: nearby, kind: .vet, query: "prater").map(\.id) == ["node/1"])
    }

    @Test func trefferDerServersucheWerdenVereint() {
        let found = [
            Service(id: "node/1", kind: "vet", label: "Tierarzt", name: "Tierklinik Praterstern", lat: 48.212, lon: 16.37),
            Service(id: "node/99", kind: "vet", label: "Tierarzt", name: "Tierklinik Nord", lat: 48.30, lon: 16.37),
            Service(id: "node/456", kind: "groomer", label: "Hundefriseur", name: "Salon Struppi", lat: 48.21, lon: 16.38),
        ]
        let list = ServiceFilter.list(nearby: nearby, found: found, kind: nil, query: "tierklinik", sponsor: sponsor, from: here)
        // node/1 nur einmal, der Sponsor gar nicht – er steht oben in seiner eigenen Karte.
        #expect(list.map(\.id) == ["node/1", "node/99"])
        // Treffer vom Server zählen auch beim Chip.
        #expect(ServiceFilter.list(nearby: nearby, found: found, kind: .shop, query: "tierklinik", sponsor: sponsor).isEmpty)
    }

    @Test func sponsorNurBeiPassendemChipUndSuchtext() {
        #expect(ServiceFilter.showsSponsor(sponsor, kind: nil, query: ""))
        #expect(ServiceFilter.showsSponsor(sponsor, kind: .groomer, query: ""))
        #expect(!ServiceFilter.showsSponsor(sponsor, kind: .vet, query: ""))
        #expect(ServiceFilter.showsSponsor(sponsor, kind: nil, query: "struppi"))
        #expect(ServiceFilter.showsSponsor(sponsor, kind: nil, query: "Hundefriseur"))
        #expect(!ServiceFilter.showsSponsor(sponsor, kind: nil, query: "tierarzt"))
        #expect(!ServiceFilter.showsSponsor(nil, kind: nil, query: ""))
    }

    @Test func chipsNurFuerVorhandeneArtenInFesterReihenfolge() {
        #expect(ServiceFilter.kinds(nearby, sponsor: nil) == [.vet, .shop, .cafe])
        // Der Sponsor ist Teil der Antwort und bringt seine Art mit.
        #expect(ServiceFilter.kinds(nearby, sponsor: sponsor) == [.vet, .groomer, .shop, .cafe])
        #expect(ServiceFilter.kinds([], sponsor: nil).isEmpty)
        // Unbekannte Arten bekommen keinen Chip.
        let odd = Service(id: "x", kind: "dog_spa", label: "Spa", name: "Spa", lat: 48.2, lon: 16.3)
        #expect(ServiceFilter.kinds([odd], sponsor: nil).isEmpty)
    }

    // MARK: Website und Telefon

    @Test func websiteBekommtHttpsWennEsFehlt() {
        #expect(Service.websiteURL("example.at")?.absoluteString == "https://example.at")
        #expect(Service.websiteURL("www.example.at/kontakt")?.absoluteString == "https://www.example.at/kontakt")
        #expect(Service.websiteURL("https://example.at")?.absoluteString == "https://example.at")
        #expect(Service.websiteURL("http://example.at")?.absoluteString == "http://example.at")
        #expect(Service.websiteURL("HTTPS://Example.at")?.absoluteString == "HTTPS://Example.at")
        #expect(Service.websiteURL("  example.at  ")?.absoluteString == "https://example.at")
        // Mehrere Adressen: die erste.
        #expect(Service.websiteURL("example.at; example.com")?.absoluteString == "https://example.at")
        #expect(Service.websiteURL("") == nil)
        #expect(Service.websiteURL("kein link") == nil)
        #expect(Service.websiteURL("localhost") == nil)
    }

    @Test func telefonnummerOhneLeerzeichen() {
        #expect(Service.phoneURL("+43 1 234 56 78")?.absoluteString == "tel:+4312345678")
        #expect(Service.phoneURL("+43 1 1; +43 2 2")?.absoluteString == "tel:+4311")
        #expect(Service.phoneURL("–") == nil)
    }
}
