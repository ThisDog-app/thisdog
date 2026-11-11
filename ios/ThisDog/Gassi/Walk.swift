import CoreLocation
import Foundation

/// Eine Gassirunde. Gespeichert und abgeglichen wie ein Termin (Art „walk“); die Strecke steht
/// geglättet und als „Encoded Polyline“ darin, damit eine lange Runde in einen Datensatz passt.
struct Walk: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// Beginn und Ende in Millisekunden seit 1970, wie alle Zeitstempel im Abgleich.
    var start: Double
    var end: Double
    /// Gelaufene Zeit ohne Pausen, in Sekunden.
    var seconds: Double
    var meters: Double
    /// Strecke, kodiert nach dem Polyline-Verfahren (5 Nachkommastellen, etwa 1 m genau).
    var path: String
    var notes: String = ""
    var u: Double = 0

    var startDate: Date { Date(timeIntervalSince1970: start / 1000) }
    var day: Day { Day(date: startDate) }
    var coordinates: [CLLocationCoordinate2D] { Polyline.decode(path) }

    /// Minuten je Kilometer, wenn genug gelaufen wurde, um es zu sagen.
    var pace: Double? { meters >= 100 ? seconds / 60 / (meters / 1000) : nil }

    static func newID() -> String {
        DogEvent.newID().replacingOccurrences(of: "evt_", with: "walk_")
    }
}
