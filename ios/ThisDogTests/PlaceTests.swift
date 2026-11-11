import Foundation
import Testing
@testable import ThisDog

@Suite("Orte")
struct PlaceTests {
    private func place(_ json: String) throws -> Place {
        try JSONDecoder().decode(Place.self, from: Data(json.utf8))
    }

    @Test func liestServerformatMitMerkmalenUndStimmen() throws {
        let p = try place(#"{"id":"way/1","name":"Hundezone Augarten","kind":"dog_park","label":"Hundezone","rank":0,"lat":48.22,"lon":16.37,"offLeash":true,"fenced":true,"facts":{"fenced":{"v":2,"src":"wien"},"area":{"v":1809,"src":"wien"},"bags":{"v":1,"src":"osm"}},"votes":{"water":[4,1]},"voters":5,"sizes":[3,2,0]}"#)
        #expect(p.id == "way/1")
        #expect(p.area == 1809)
        // Kotbeutel stehen jetzt bei den Merkmalen (aus der Karte, bis genug bewertet haben), nicht mehr extra.
        #expect(p.extras.isEmpty)
        #expect(p.verdict(.bags) == .yes("osm"))
        #expect(p.verdict(.water) == .yes(nil))
        // Zum Zaun haben die Bewertenden nichts gesagt – dann gilt die Stadt.
        #expect(p.verdict(.fenced) == .partly("wien"))
        #expect(p.sourceNote == "Aus OpenStreetMap, ergänzt mit Daten der Stadt Wien (CC BY 4.0)")
    }

    @Test func getrenntFuerGrossUndKleinNurBeiHundezonen() throws {
        let zone = try place(#"{"name":"Hundezone","kind":"dog_park","label":"Hundezone","rank":0,"lat":48.22,"lon":16.37}"#)
        let park = try place(#"{"name":"Augarten","kind":"park","label":"Park","rank":1,"lat":48.22,"lon":16.37}"#)
        #expect(PlaceFeature.all(for: zone).contains(.split))
        #expect(PlaceFeature.all(for: zone).contains(.bags))
        #expect(!PlaceFeature.all(for: park).contains(.split))
        #expect(PlaceFeature.all(for: park).contains(.bags))
    }

    @Test func ohneNeueFelderWieBisher() throws {
        let p = try place(#"{"name":"Augarten","kind":"park","label":"Park","rank":1,"lat":48.22,"lon":16.37}"#)
        #expect(p.serverID == nil)
        #expect(p.voters == 0)
        #expect(p.verdict(.water) == nil)
    }

    @Test func dreiViertelSindJaEinViertelNeinDazwischenUneinig() throws {
        var p = try place(#"{"id":"eigen/1","name":"Wiese","kind":"meadow","label":"Wiese","rank":3,"lat":48.2,"lon":16.4}"#)
        p.voters = 4
        p.votes = ["water": [3, 1], "shade": [1, 3], "clean": [2, 2]]
        #expect(p.verdict(.water) == .yes(nil))
        #expect(p.verdict(.shade) == .no(nil))
        #expect(p.verdict(.clean) == .unsure(yes: 2, of: 4))
    }

    @Test func unterDreiBewertungenZaehltDieKarte() throws {
        var p = try place(#"{"id":"way/2","name":"Park","kind":"park","label":"Park","rank":1,"lat":48.2,"lon":16.4,"facts":{"bench":{"v":1,"src":"osm"}}}"#)
        p.voters = 2
        p.votes = ["bench": [0, 2], "water": [2, 0]]
        #expect(!p.enoughVotes)
        #expect(p.verdict(.bench) == .yes("osm"))
        #expect(p.verdict(.water) == nil)
    }

    @Test func geprueftGiltVorBewertungen() throws {
        var p = try place(#"{"id":"way/3","name":"Zone","kind":"dog_park","label":"Hundezone","rank":0,"lat":48.2,"lon":16.4,"facts":{"water":{"v":0,"src":"thisdog"}},"checkedAt":1792000000,"photos":[{"id":7,"w":1600,"h":1200}]}"#)
        p.voters = 5
        p.votes = ["water": [5, 0]]
        #expect(p.verdict(.water) == .no("thisdog"))
        #expect(p.photos.first?.thumb.absoluteString == "https://thisdog.app/api/photo.php?id=7&klein=1")
        #expect(p.checkedAt == 1792000000)
    }
}

@Suite("Gerätecode")
struct DeviceCodeTests {
    /// Dieselben Werte wie tests/support-test.sh und api/lib-support.php.
    @Test func gleichWieDerServer() {
        #expect(DeviceCode.encode(platform: 0, os: 27, kind: 1, ramLog2: 3, major: 1, minor: 0, build: 12) == "0V5-H00-0CG")
        #expect(DeviceCode.encode(platform: 2, os: 16, kind: 5, ramLog2: 4, major: 1, minor: 2, build: 345) == "4GP-110-AS9")
    }
}

@Suite("Eigene Bewertung")
struct MyRatingTests {
    typealias Mine = PlaceService.Summary.Mine

    @Test func zaehltNurMitInhalt() {
        #expect(!Mine(votes: [:], sizes: nil).isRated)
        #expect(!Mine(votes: [:], sizes: .init()).isRated)
        #expect(Mine(votes: ["water": 0], sizes: nil).isRated)
        #expect(Mine(votes: [:], sizes: .init(large: true)).isRated)
    }
}
