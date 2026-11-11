import Foundation
import Testing
@testable import ThisDog

@Suite("Ratgeber")
struct TipTests {
    private static let tips: [Tip] = {
        let url = Bundle.main.url(forResource: "tips", withExtension: "json")!
        return try! JSONDecoder().decode([Tip].self, from: Data(contentsOf: url))
    }()

    @Test("Alle Tipps lesbar, jedes Bild in der App")
    func data() {
        #expect(Self.tips.count >= 20)
        for t in Self.tips where t.imageName != nil { #expect(t.bundledImage != nil, "\(t.slug)") }
    }

    @Test("Text: Überschriften, Aufzählungen, Absätze")
    func blocks() {
        let b = TipText.blocks("### Warum\n\nHunde kühlen **kaum**.\n\n* früh gehen\n* Wasser mit\n\nFazit")
        #expect(b == [.heading("Warum"), .paragraph("Hunde kühlen **kaum**."), .bullet("früh gehen"), .bullet("Wasser mit"), .paragraph("Fazit")])
    }

    @Test("Häkchen im Format der Web-App: je Tipp eine Liste")
    func checks() throws {
        let json = #"{"sommerhitze-sicher":[true,false,true,false]}"#
        let c = try JSONDecoder().decode(TipChecks.self, from: Data(json.utf8))
        #expect(c.bySlug["sommerhitze-sicher"] == [true, false, true, false])
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        #expect((back["sommerhitze-sicher"] as? [Bool]) == [true, false, true, false])
    }

    @Test("Empfehlung: Jahreszeit zählt am meisten, dann Lebensphase")
    func ranking() {
        let summer = Self.tips.first { $0.slug == "sommerhitze-sicher" }!
        #expect(TipRanking.score(summer, season: .summer, stage: "adult") >= 4)
        #expect(TipRanking.score(summer, season: .winter, stage: "adult") < 3)
        #expect(Season.of(Day(2026, 10, 18)) == .autumn)
        #expect(Season.of(Day(2026, 12, 1)) == .winter)
    }

    @Test("Abhaken wird gespeichert und geht in den Abgleich")
    @MainActor func toggle() {
        let s = DogStore(file: URL.temporaryDirectory.appending(path: "tips-\(UUID().uuidString).json"))
        let tip = Self.tips.first { ($0.checklist?.count ?? 0) > 2 }!
        s.toggleCheck(tip, 1)
        #expect(s.checks.bySlug[tip.slug]?[1] == true)
        #expect(s.outgoingRecords().contains { $0.kind == "checks" })
    }
}
