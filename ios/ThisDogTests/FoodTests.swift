import Foundation
import Testing
@testable import ThisDog

@Suite("Food-Check")
struct FoodTests {
    private static let foods: [Food] = {
        let url = Bundle.main.url(forResource: "foods", withExtension: "json")!
        return try! JSONDecoder().decode([Food].self, from: Data(contentsOf: url))
    }()
    private let search = FoodSearch(FoodTests.foods)

    private func top(_ q: String) -> String? { search.search(q).first?.food.name }

    @Test("Alle Lebensmittel lesbar, jedes mit Urteil")
    func data() {
        #expect(Self.foods.count > 200)
        #expect(Self.foods.allSatisfy { ["ok", "warn", "bad"].contains($0.status) })
    }

    @Test("Tomate findet die Tomate, nicht die Soße")
    func tomato() {
        #expect(top("Tomate") == "Tomate (reif)")
        #expect(top("Tomaten") == "Tomate (reif)")
        #expect(top("Melone") == "Wassermelone (ohne Kerne und Schale)")
    }

    @Test("Mehrzahl, zusammengesetzte Wörter, Aliase")
    func german() {
        #expect(top("Trauben") == "Trauben")
        #expect(top("Weintrauben") == "Trauben")
        #expect(top("Knoblauchdip") == "Aioli")
    }

    @Test("Umlaute: mit, als ae und ganz ohne")
    func umlauts() {
        #expect(top("Käse")?.hasPrefix("Käse") == true)
        #expect(top("kaese")?.hasPrefix("Käse") == true)
        #expect(top("kase")?.hasPrefix("Käse") == true)
    }

    @Test("Tippfehler werden verziehen, Unsinn findet nichts")
    func typos() {
        #expect(top("Bananne") == "Banane")
        #expect(search.search("xqzv").isEmpty)
    }

    @Test("Bausteine wie in der Web-App")
    func parts() {
        #expect(FoodSearch.norm("Äpfel, roh") == "aepfel roh")
        #expect(FoodSearch.stem("trauben") == "traub")
        #expect(FoodSearch.editDistance("hund", "hand") == 1)
    }
}

@Suite("Oft gefragt")
@MainActor
struct FrequentFoodTests {
    @Test("Jeder Eintrag in „Oft gefragt“ steht genau so in der Lebensmittelliste")
    func namesExist() throws {
        let url = try #require(Bundle.main.url(forResource: "foods", withExtension: "json"))
        let foods = try JSONDecoder().decode([Food].self, from: Data(contentsOf: url))
        let names = Set(foods.map(\.name))
        for n in FoodCheck.frequentNames { #expect(names.contains(n), "\(n) fehlt in foods.json") }
    }
}

@Suite("Food-Check: Foto und Strichcode")
struct FoodScanTests {
    private static let foods: [Food] = {
        let url = Bundle.main.url(forResource: "foods", withExtension: "json")!
        return try! JSONDecoder().decode([Food].self, from: Data(contentsOf: url))
    }()
    private let search = FoodSearch(FoodScanTests.foods)

    @Test("Jeder Begriff aus der Bilderkennung findet etwas in der Liste")
    func photoTermsFind() {
        for (id, term) in FoodPhoto.terms {
            #expect(!search.search(term).isEmpty, "\(id) → „\(term)“ findet nichts")
        }
    }

    @Test("Foto: wahrscheinlichste zuerst, ohne Doppelte, Unsicheres fällt weg")
    func photoTermsOrder() {
        let t = FoodPhoto.terms(from: [("cake", 0.3), ("grape", 0.8), ("cupcake", 0.5), ("table", 0.9), ("onion", 0.05)])
        #expect(t == ["Trauben", "Kuchen"])
    }

    @Test("Zutaten: Gefährliches wird gefunden, das Schlimmste zuerst")
    func ingredientHits() {
        let check = IngredientCheck(foods: Self.foods)
        let hits = check.hits(tags: ["en:sugar", "en:onion"], text: "Zucker, Röstzwiebeln, Magerkakao, Süßungsmittel: Xylit")
        #expect(Set(hits.map(\.name)) == ["Zwiebel", "Schokolade", "Xylit"])
        #expect(hits.allSatisfy { $0.verdict == .bad })
        let nuts = check.hits(tags: [], text: "Haselnüsse 13 %, Walnusskerne")
        #expect(nuts.map(\.name) == ["Walnüsse"])
    }

    @Test("Zutaten: keine Fehlalarme bei Traubenzucker, Krume oder Serum")
    func ingredientFalseAlarms() {
        let check = IngredientCheck(foods: Self.foods)
        #expect(check.hits(tags: ["en:dextrose"], text: "Weizenmehl, Traubenzucker, Brotkrume, Molkenserum").isEmpty)
        #expect(check.hits(tags: [], text: "Rum, Zucker").map(\.name) == ["Alkohol"])
    }
}
