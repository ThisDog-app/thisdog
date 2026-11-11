import ActivityKit
import CoreLocation
import Foundation
import Observation
import UIKit

/// Zeichnet eine Runde auf – auch im Hintergrund, wenn das Telefon in der Tasche liegt.
///
/// Verworfen werden Punkte, die zu ungenau sind (Häuserschluchten) oder die einen Sprung bedeuten,
/// den kein Mensch mit Hund läuft. Die laufende Runde liegt nach jedem Punkt auch in einer Datei:
/// Wird die App beendet, geht nichts verloren, und beim nächsten Start läuft die Runde weiter.
@MainActor
@Observable
final class WalkRecorder: NSObject {
    enum Phase: String, Codable { case idle, recording, paused }

    private(set) var phase: Phase = .idle
    private(set) var coordinates: [CLLocationCoordinate2D] = []
    private(set) var meters: Double = 0
    /// Wo man gerade steht, auch vor dem Start (für die Karte).
    private(set) var here: CLLocationCoordinate2D?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Ein Punkt je vollem Kilometer mit der gelaufenen Zeit bis dorthin.
    private(set) var splits: [Double] = []
    private(set) var startedAt: Date?
    /// Läuft gerade eine Runde auf der Watch? Dann bietet das iPhone keine zweite an.
    private(set) var runsOnWatch = false

    /// Gelaufene Sekunden bis zur letzten Pause plus seit dem letzten Weiterlaufen.
    private var banked: Double = 0
    private var runningSince: Date?

    static let maxAccuracy = Track.maxAccuracy
    static let maxSpeed = Track.maxSpeed
    static let minStep = Track.minStep

    /// Jeder glaubwürdige Punkt der laufenden Runde (für die Hundefreunde) und jeder Standort überhaupt.
    @ObservationIgnored var onPoint: ((CLLocationCoordinate2D, Date) -> Void)?
    @ObservationIgnored var onHere: ((CLLocationCoordinate2D) -> Void)?
    /// Die Runde ist vorbei (beendet oder verworfen).
    @ObservationIgnored var onEnd: (() -> Void)?
    /// Der Stand hat sich geändert (für die Watch): Start, Pause, Ende und alle 50 m.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var last: CLLocation?
    @ObservationIgnored private var activity: Activity<WalkActivityAttributes>?
    @ObservationIgnored private var reportedMeters: Double = 0
    @ObservationIgnored private let file = URL.applicationSupportDirectory.appending(path: "laufende-runde.json")

    /// Ohne echte Ortung (`liveLocation: false`) nimmt die Aufzeichnung nur Punkte über `take` an –
    /// für Tests, die sonst eine Standortabfrage auslösten, die im Simulator stehen bleibt.
    @ObservationIgnored private let liveLocation: Bool

    init(liveLocation: Bool = true) {
        self.liveLocation = liveLocation
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
        if liveLocation { restore() }
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    func seconds(at now: Date = Date()) -> Double {
        banked + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    /// Der Stand für die Watch.
    func watchStatus(dogName: String) -> WatchLink.PhoneStatus {
        let p: WatchLink.Phase = switch phase { case .idle: .idle; case .recording: .recording; case .paused: .paused }
        return .init(dogName: dogName, phase: p, meters: meters, banked: banked, runningSince: runningSince, sent: Date(), startedAt: startedAt)
    }

    var pace: Double? { meters >= 100 ? seconds() / 60 / (meters / 1000) : nil }

    /// Für „Wohin heute?“: einmal den Standort, ohne aufzuzeichnen.
    func locateOnce() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization(); return }
        manager.requestLocation()
    }

    /// Läuft auf der Watch eine Runde? Dann zeigt das iPhone sie auf dem Sperrbildschirm und in der Dynamic Island,
    /// mit dem Stand, den die Watch schickt (`state`; ohne ihn bleibt die Anzeige, wie sie ist).
    func watchWalk(running: Bool, state: WalkActivityAttributes.ContentState? = nil, startedAt: Date? = nil) {
        runsOnWatch = running
        guard liveLocation, phase == .idle else { return }
        if running {
            if let state { showWatchActivity(state, startedAt: startedAt) }
        } else {
            endWatchActivities()
        }
    }

    func start() {
        guard !runsOnWatch else { return }
        if liveLocation, authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        coordinates = []
        meters = 0
        banked = 0
        splits = []
        last = nil
        startedAt = Date()
        runningSince = Date()
        phase = .recording
        begin()
        persist()
        startActivity()
        onChange?()
    }

    func pause() {
        guard phase == .recording else { return }
        banked = seconds()
        runningSince = nil
        phase = .paused
        last = nil  // Nach der Pause zählt der Weg nicht als Sprung vom alten Punkt aus.
        persist()
        updateActivity()
        onChange?()
    }

    func resume() {
        guard phase == .paused else { return }
        runningSince = Date()
        phase = .recording
        begin()
        persist()
        updateActivity()
        onChange?()
    }

    /// Beendet die Runde und gibt sie zurück; `nil`, wenn kaum gelaufen wurde.
    func finish() -> Walk? {
        let total = seconds()
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        defer { reset() }
        guard let startedAt, meters >= 20 || total >= 60 else { return nil }
        return Walk(id: Walk.newID(), start: startedAt.timeIntervalSince1970 * 1000, end: Date().timeIntervalSince1970 * 1000,
                    seconds: total, meters: meters, path: Polyline.encode(Track.simplify(coordinates)))
    }

    func discard() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        reset()
    }

    private func begin() {
        guard liveLocation else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    private func reset() {
        if phase != .idle { onEnd?() }
        endActivity()
        phase = .idle
        coordinates = []
        meters = 0
        banked = 0
        splits = []
        runningSince = nil
        startedAt = nil
        last = nil
        try? FileManager.default.removeItem(at: file)
        onChange?()
    }

    // MARK: Punkte

    /// Nimmt einen Ortungspunkt auf, wenn er glaubwürdig ist. Gibt zurück, ob er zählt.
    @discardableResult
    func take(_ loc: CLLocation) -> Bool {
        here = loc.coordinate
        onHere?(loc.coordinate)
        guard phase == .recording, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= Self.maxAccuracy else { return false }
        if let last {
            guard let d = Track.step(from: last, to: loc) else { return false }
            meters += d
            while meters >= Double(splits.count + 1) * 1000 { splits.append(seconds(at: loc.timestamp)) }
        }
        last = loc
        coordinates.append(loc.coordinate)
        if let startedAt { onPoint?(loc.coordinate, startedAt) }
        if meters - reportedMeters >= 50 { updateActivity(); onChange?() }
        if coordinates.count % 10 == 0 { persist() }
        return true
    }

    // MARK: Sichern

    private struct Saved: Codable {
        var phase: Phase
        var lat: [Double]
        var lon: [Double]
        var meters: Double
        var banked: Double
        var runningSince: Date?
        var startedAt: Date?
        var splits: [Double]
    }

    private func persist() {
        guard liveLocation else { return }
        let s = Saved(phase: phase, lat: coordinates.map(\.latitude), lon: coordinates.map(\.longitude), meters: meters,
                      banked: banked, runningSince: runningSince, startedAt: startedAt, splits: splits)
        try? JSONEncoder().encode(s).write(to: file, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: data), s.phase != .idle else { return }
        phase = s.phase
        coordinates = zip(s.lat, s.lon).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
        meters = s.meters
        banked = s.banked
        runningSince = s.runningSince
        startedAt = s.startedAt
        splits = s.splits
        if phase == .recording { begin() }
        activity = Activity<WalkActivityAttributes>.activities.first
    }

    // MARK: Sperrbildschirm

    private var activityState: WalkActivityAttributes.ContentState {
        .init(meters: meters, banked: banked, runningSince: runningSince)
    }

    private func startActivity() {
        guard liveLocation, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Eine liegengebliebene Anzeige einer früheren Runde räumen. Die IDs werden vor dem Anfordern der
        // neuen gemerkt: Der Task läuft erst danach und hat früher auch die frische Anzeige gleich wieder beendet.
        // Die Aktivitäten werden im Task neu nachgeschlagen – `Activity` darf nicht zwischen Kontexten wandern.
        let stale = Set(Activity<WalkActivityAttributes>.activities.map(\.id))
        if !stale.isEmpty {
            Task {
                for old in Activity<WalkActivityAttributes>.activities where stale.contains(old.id) {
                    await old.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        activity = try? Activity.request(attributes: WalkActivityAttributes(dogName: ""),
                                         content: .init(state: activityState, staleDate: nil))
        reportedMeters = meters
    }

    private func updateActivity() {
        reportedMeters = meters
        guard let id = activity?.id else { return }
        let content = ActivityContent(state: activityState, staleDate: nil)
        Task { await Self.activity(id)?.update(content) }
    }

    private func endActivity() {
        guard let id = activity?.id else { return }
        let content = ActivityContent(state: activityState, staleDate: nil)
        Task { await Self.activity(id)?.end(content, dismissalPolicy: .immediate) }
        activity = nil
    }

    // MARK: Runde auf der Watch

    /// Für welche Watch-Runde der Start schon über den Server angestoßen wurde (nicht zweimal).
    @ObservationIgnored private var pushedFor: Date?

    private func showWatchActivity(_ state: WalkActivityAttributes.ContentState, startedAt: Date?) {
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(WatchLink.WatchStatus.validFor))
        if let id = (activity ?? Activity<WalkActivityAttributes>.activities.first)?.id {
            activity = Self.activity(id)
            Task { await Self.activity(id)?.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Im Vordergrund darf die App die Anzeige selbst starten. Im Hintergrund (von der Watch geweckt)
        // verbietet iOS das – dann startet sie der Server per Push.
        if UIApplication.shared.applicationState != .background,
           let a = try? Activity.request(attributes: WalkActivityAttributes(dogName: ""), content: content) {
            activity = a
            return
        }
        let key = startedAt ?? state.clockStart ?? Date.distantPast
        guard pushedFor != key else { return }
        pushedFor = key
        LiveStart.request(state)
    }

    private func endWatchActivities() {
        activity = nil
        pushedFor = nil
        let ids = Activity<WalkActivityAttributes>.activities.map(\.id)
        guard !ids.isEmpty else { return }
        Task { for id in ids { await Self.activity(id)?.end(nil, dismissalPolicy: .immediate) } }
    }

    private nonisolated static func activity(_ id: String) -> Activity<WalkActivityAttributes>? {
        Activity<WalkActivityAttributes>.activities.first { $0.id == id }
    }
}

extension WalkRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in for l in locations { self.take(l) } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                if self.phase == .recording { self.begin() } else { self.manager.requestLocation() }
            }
        }
    }
}

/// Startet die Live-Aktivität über den Server (Push-to-Start), wenn die App im Hintergrund ist.
/// Die Kennung dafür vergibt iOS; sie wird gemerkt, sobald sie da ist.
@MainActor
enum LiveStart {
    private static let tokenKey = "liveStartToken"

    /// Hört auf neue Kennungen – einmal beim Start der App.
    static func observe() {
        Task {
            for await data in Activity<WalkActivityAttributes>.pushToStartTokenUpdates {
                UserDefaults.standard.set(data.map { String(format: "%02x", $0) }.joined(), forKey: tokenKey)
            }
        }
    }

    static func request(_ state: WalkActivityAttributes.ContentState) {
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        struct Body: Encodable { let token: String; let environment: String; let state: WalkActivityAttributes.ContentState }
        let env = PushEnvironment.current
        // Von der Watch geweckt bleiben nur Sekunden: so lange um Aufschub bitten, bis der Server geantwortet hat.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "live-start") { UIApplication.shared.endBackgroundTask(task) }
        Task {
            let _: Ok? = try? await Api().post("push.php", ["action": "live_start"], body: Body(token: token, environment: env, state: state))
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}
