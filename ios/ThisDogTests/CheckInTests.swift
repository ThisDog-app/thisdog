import CoreLocation
import Foundation
import Testing
@testable import ThisDog

@Suite("Einchecken und Revier")
struct CheckInTests {
    private let cal = Calendar.gregorianLocal
    private func place(_ id: String, _ lat: Double = 48.22, _ lon: Double = 16.39) -> Place {
        Place(name: "Ort \(id)", kind: "dog_park", label: "Hundezone", rank: 0, lat: lat, lon: lon, serverID: id)
    }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func nurVorOrtUndNichtZweimalInZweiStunden() {
        let p = place("way/1")
        #expect(CheckIns.inReach(p, from: CLLocationCoordinate2D(latitude: 48.2210, longitude: 16.39)))
        #expect(!CheckIns.inReach(p, from: CLLocationCoordinate2D(latitude: 48.2300, longitude: 16.39)))
        let now = date("2026-10-18T10:00:00Z")
        let c = CheckIn(place: p, at: now.addingTimeInterval(-3600))
        #expect(CheckIns.recent(p, in: [c], now: now) == c)
        #expect(CheckIns.recent(p, in: [c], now: now.addingTimeInterval(3 * 3600)) == nil)
    }

    @Test func stammgastAbZehnBesuchen() {
        let p = place("way/1")
        let nine = (0..<9).map { CheckIn(place: p, at: date("2026-10-0\($0 + 1)T08:00:00Z")) }
        let r9 = Revier(nine, now: date("2026-10-18T10:00:00Z"))
        #expect(!r9.badges.contains { $0.id == "stammgast" })
        #expect(r9.next?.detail == "noch 1 Besuche in Ort way/1")
        let r10 = Revier(nine + [CheckIn(place: p, at: date("2026-10-12T08:00:00Z"))], now: date("2026-10-18T10:00:00Z"))
        #expect(r10.badges.map(\.id) == ["stammgast"])
        #expect(r10.spots.first?.visits == 10)
    }

    @Test func sonntageInFolge() {
        // 18.10.2026 ist ein Sonntag. Eingecheckt am 11., 4. und 27.9. – der 18. fehlt noch, zählt also nicht dagegen.
        let p = place("way/2")
        let all = ["2026-10-11", "2026-10-04", "2026-09-27", "2026-09-20"].map { CheckIn(place: p, at: date("\($0)T09:00:00Z")) }
        #expect(Revier.sundayStreak(all, now: date("2026-10-18T07:00:00Z"), calendar: cal) == 4)
        #expect(Revier.sundayStreak(Array(all.dropFirst()), now: date("2026-10-18T07:00:00Z"), calendar: cal) == 0)
    }

    @Test func revierTitel() {
        #expect(CheckIns.revierTitle("Stella") == "Stellas Revier")
        #expect(CheckIns.revierTitle("Max") == "Max’ Revier")
    }
}
