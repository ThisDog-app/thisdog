import Foundation

/// Die Rechnungen der Rechner – dieselben Formeln wie in der Web-App (`js/tools.js`).
enum Calc {
    /// Grundumsatz (Resting Energy Requirement) in kcal: 70 × kg^0,75.
    static func rer(_ kg: Double) -> Double { 70 * pow(kg, 0.75) }

    struct Factor: Equatable { let value: Double; let note: String }

    /// Faktor für den Erhaltungsbedarf und woraus er sich ergibt.
    static func factor(_ p: DogProfile, today: Day = .today) -> Factor {
        if let b = p.birthDay {
            let months = Double(b.days(until: today)) / 30.44
            if months < 4 { return Factor(value: 3.0, note: String(localized: "Welpe bis 4 Monate, hoher Wachstumsbedarf")) }
            if months < 12 { return Factor(value: 2.0, note: String(localized: "Welpe bis 12 Monate, Wachstum")) }
        }
        var f = p.neutered ? 1.6 : 1.8
        var parts = [p.neutered ? "kastriert" : String(localized: "nicht kastriert")]
        if p.activity == "low" { f -= 0.2; parts.append("ruhig") }
        if p.activity == "high" { f += 0.4; parts.append(String(localized: "sehr aktiv")) }
        if p.stage(on: today) == String(localized: "Senior") { f -= 0.2; parts.append(String(localized: "Senior")) }
        return Factor(value: max(1.0, (f * 100).rounded() / 100), note: parts.joined(separator: ", "))
    }

    struct Energy: Equatable { let rer: Double; let kcal: Double; let factor: Factor; let kg: Double }

    /// Tagesbedarf. Mit `useTarget` zählt das Wunschgewicht: Ein zu schwerer Hund braucht die Energie
    /// für den Hund, der er werden soll.
    static func energy(_ p: DogProfile, useTarget: Bool = false, today: Day = .today) -> Energy? {
        let kg = useTarget ? (p.targetWeightKg ?? p.weightKg) : p.weightKg
        guard let kg, kg > 0 else { return nil }
        let f = factor(p, today: today)
        let r = rer(kg)
        return Energy(rer: r, kcal: r * f.value, factor: f, kg: kg)
    }

    /// Gramm Futter am Tag bei `kcalPer100g`.
    static func grams(kcal: Double, kcalPer100g: Double) -> Double? { kcalPer100g > 0 ? kcal / kcalPer100g * 100 : nil }

    /// Höchstens ein Zehntel der Tagesenergie aus Leckerli; Trockenleckerli haben etwa 3,5 kcal je Gramm.
    static func treats(kcal: Double) -> (kcal: Double, grams: Double) { (kcal * 0.1, kcal * 0.1 / 3.5) }

    /// Wasser: 50 bis 60 ml je kg und Tag.
    static func water(_ kg: Double) -> ClosedRange<Double> { (kg * 50)...(kg * 60) }

    typealias Paws = Asphalt.Paws
    static func paws(surface: Double) -> Paws { Asphalt.paws(surface: surface) }

    static let foodKinds: [(String, Double)] = [(String(localized: "Trocken"), 350), (String(localized: "Nass"), 95), (String(localized: "Frisch, BARF"), 150)]
}

/// Einstellungen der Rechner, abgeglichen wie in der Web-App (Art „settings“).
struct ToolSettings: Codable, Hashable, Sendable {
    var meals = 2
    /// „current“ oder „target“
    var feedBasis = "current"
    var kcalPer100g: Double = 350
    var u: Double = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meals = ((try? c.decodeIfPresent(Int.self, forKey: .meals)) ?? nil) ?? 2
        feedBasis = ((try? c.decodeIfPresent(String.self, forKey: .feedBasis)) ?? nil) ?? "current"
        kcalPer100g = ((try? c.decodeIfPresent(Double.self, forKey: .kcalPer100g)) ?? nil) ?? 350
        u = ((try? c.decodeIfPresent(Double.self, forKey: .u)) ?? nil) ?? 0
    }
}

extension ToolSettings: SyncedItem {
    static let kind = "settings"
    var id: String { "settings" }
}
