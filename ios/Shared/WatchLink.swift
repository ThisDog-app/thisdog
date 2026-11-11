import Foundation

/// Was iPhone und Watch einander schicken (WatchConnectivity). Eine Runde läuft dort, wo sie begonnen wurde:
/// Die Watch nimmt mit eigenem GPS auf und schickt die fertige Runde; eine Runde vom iPhone steuert sie nur.
enum WatchLink {
    enum Phase: String, Codable, Sendable { case idle, recording, paused }

    /// Stand des iPhones für die Watch.
    struct PhoneStatus: Codable, Sendable, Equatable {
        var dogName: String = ""
        var phase: Phase = .idle
        var meters: Double = 0
        var banked: Double = 0
        var runningSince: Date?
        /// Wann das iPhone diesen Stand geschickt hat, und seit wann die Runde dort läuft. Fehlen bei älteren
        /// Fassungen der iPhone-App.
        var sent: Date?
        var startedAt: Date?

        /// Solange eine Runde läuft, schickt das iPhone den Stand spätestens so oft, auch ohne Änderung.
        static let resendEvery: TimeInterval = 5 * 60
        /// Bleibt das iPhone stumm (Akku leer, App beendet), gibt die Watch den Start nach dieser Zeit wieder frei.
        static let validFor: TimeInterval = 20 * 60

        func seconds(at now: Date) -> Double { banked + (runningSince.map { now.timeIntervalSince($0) } ?? 0) }

        /// Läuft auf dem iPhone eine Runde? Ohne Zeitstempel (ältere iPhone-App) gilt der Stand wie bisher.
        func isRunning(at now: Date) -> Bool {
            phase != .idle && (sent.map { now.timeIntervalSince($0) < Self.validFor } ?? true)
        }
    }

    /// Eine fertige Runde von der Watch.
    struct FinishedWalk: Codable, Sendable {
        var id: String
        var start: Double
        var end: Double
        var seconds: Double
        var meters: Double
        var path: String
    }

    /// Stand einer Runde, die auf der Watch läuft, für das iPhone (auch für die Live-Aktivität dort).
    struct WatchStatus: Codable, Sendable, Equatable {
        var phase: Phase = .idle
        var sent: Date = Date()
        /// Strecke und Zeit; fehlen bei älteren Fassungen der Watch-App.
        var meters: Double?
        var banked: Double?
        var runningSince: Date?
        var startedAt: Date?

        /// Bleibt die Watch stumm (Akku leer), gibt das iPhone den Start nach dieser Zeit wieder frei.
        static let validFor: TimeInterval = 60 * 60

        func isRunning(at now: Date) -> Bool { phase != .idle && now.timeIntervalSince(sent) < Self.validFor }
    }

    enum Command: String, Sendable {
        case pause, resume, finish, discard

        /// Ein Befehl, der über die Warteschlange erst später ankommt, kann überholt sein. Er gilt nur für die
        /// Runde, für die er gedacht war (`walk`: ihr Beginn, wie ihn die Watch kannte), und Pause oder Weiter
        /// nur, solange sie frisch sind – später gedrückt würden sie die Zeit der Runde verfälschen.
        func applies(walk: Date?, sentAt: Date?, queued: Bool, running startedAt: Date?, now: Date = Date()) -> Bool {
            guard let startedAt else { return false }
            if let walk, abs(walk.timeIntervalSince(startedAt)) > 1 { return false }
            guard queued else { return true }
            switch self {
            case .finish, .discard: return true
            case .pause, .resume: return sentAt.map { now.timeIntervalSince($0) < Self.freshFor } ?? false
            }
        }

        static let freshFor: TimeInterval = 5 * 60
    }

    /// Was die Watch außer der laufenden Runde vom iPhone wissen will: Woche, letzte Runden, Ziele in der Nähe,
    /// was beim Hund ansteht, und wie warm es draußen ist. Kommt mit jedem Stand und liegt auf der Watch auch
    /// für die Komplikation bereit.
    struct Digest: Codable, Sendable, Equatable {
        struct RecentWalk: Codable, Sendable, Equatable, Identifiable {
            var start: Date
            var meters: Double
            var seconds: Double
            var id: Date { start }
        }
        struct Place: Codable, Sendable, Equatable, Identifiable {
            var id: String
            var name: String
            var kind: String
            var lat: Double
            var lon: Double
        }
        struct Due: Codable, Sendable, Equatable, Identifiable {
            var id: String
            var title: String
            var kind: String
            var due: Date
            /// Lässt sich abhaken (Impfung, Entwurmung).
            var doneable: Bool
        }

        var dogName = ""
        var weekMeters: Double = 0
        var weekWalks = 0
        var recent: [RecentWalk] = []
        var places: [Place] = []
        var dues: [Due] = []
        /// Lufttemperatur in °C und ob gerade Tag ist; `nil`, solange kein Wetter da ist.
        var air: Double?
        var daylight = true
        var airAt: Date?
        /// Das Wetter für den Belag; die Watch rechnet damit selbst, weil die Sonne weiterwandert.
        var asphalt: Asphalt.Conditions?

        /// Wetter, das älter als zwei Stunden ist, warnt nicht mehr.
        func heat(at now: Date = Date()) -> Asphalt.Paws? {
            guard let asphalt, let airAt, now.timeIntervalSince(airAt) < 2 * 3600 else { return nil }
            return Asphalt.warning(asphalt, at: now)
        }

        func surface(at now: Date = Date()) -> Double? {
            asphalt.map { Asphalt.surface($0, at: now) }
        }
    }

    static let digestKey = "digest"
    /// Von der Watch: diese Fälligkeit ist erledigt (Wert: ihre Kennung).
    static let doneKey = "done"

    static let statusKey = "status"
    static let watchStatusKey = "watchStatus"
    static let commandKey = "command"
    /// Zum Befehl: Beginn der gemeinten Runde und wann er auf der Watch gegeben wurde (Sekunden seit 1970).
    static let commandWalkKey = "commandWalk"
    static let commandAtKey = "commandAt"
    static let walkKey = "walk"
}
