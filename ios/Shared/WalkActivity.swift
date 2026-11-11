import ActivityKit
import Foundation

/// Die laufende Runde auf dem Sperrbildschirm und in der Dynamic Island.
/// Liegt in App und Widget-Erweiterung zugleich – beide müssen dieselbe Form kennen.
struct WalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var meters: Double
        /// Gelaufene Sekunden bis zur letzten Pause.
        var banked: Double
        /// Seit wann wieder gelaufen wird; `nil` in der Pause.
        var runningSince: Date?

        /// Der Zeitpunkt, ab dem die Uhr zählt, als wäre nie pausiert worden – so kann das System
        /// die Zeit selbst weiterzählen, ohne dass die App jede Sekunde etwas schicken muss.
        var clockStart: Date? { runningSince.map { $0.addingTimeInterval(-banked) } }
    }

    var dogName: String
}
