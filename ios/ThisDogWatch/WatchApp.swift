import CoreLocation
import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct ThisDogWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WalkView().environment(model).tint(Mandarine.color)
        }
    }
}

enum Mandarine {
    static let color = Color(red: 0xFF / 255, green: 0x87 / 255, blue: 0x46 / 255)
}

/// Nimmt die Runde auf der Watch auf (eigenes GPS, auch ohne iPhone) und kennt den Stand einer Runde vom iPhone.
@MainActor
@Observable
final class WatchModel: NSObject {
    private(set) var phase: WatchLink.Phase = .idle
    private(set) var meters: Double = 0
    private(set) var phone = WatchLink.PhoneStatus()
    private(set) var denied = false
    /// Die eben beendete (und schon ans iPhone geschickte) Runde, solange die Zusammenfassung offen ist.
    private(set) var finished: WatchLink.FinishedWalk?
    /// Woche, Ziele, Fälligkeiten und Wetter vom iPhone; bleibt gespeichert, auch für die Komplikation.
    private(set) var digest = DigestShelf.load()
    /// Ein Befehl für die Runde auf dem iPhone kam nicht direkt an und wartet in der Warteschlange.
    private(set) var queuedNote: String?

    private var banked: Double = 0
    private var runningSince: Date?
    private var startedAt: Date?
    private var coordinates: [CLLocationCoordinate2D] = []

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var last: CLLocation?
    @ObservationIgnored private var reportedAt = Date.distantPast
    @ObservationIgnored private let file = URL.applicationSupportDirectory.appending(path: "laufende-runde.json")
    /// Läuft der Stand vom iPhone ab, gibt die Watch den Start wieder frei.
    @ObservationIgnored private var phoneExpiry: Task<Void, Never>?
    @ObservationIgnored private var noteExpiry: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        restore()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-runde"), phase == .idle { start() }
        if args.contains("-pause") { pause() }
        if args.contains("-telefon") {
            phone = .init(dogName: String(localized: "Stella"), phase: .recording, meters: 1840, banked: 1421, runningSince: Date())
        }
        if args.contains("-name") { phone.dogName = String(localized: "Stella") }
        // Zusammenfassung wie vom iPhone, ohne iPhone: `-beispiel`.
        if args.contains("-beispiel") {
            var d = WatchLink.Digest()
            d.dogName = String(localized: "Stella")
            d.weekMeters = 12_400
            d.weekWalks = 6
            d.recent = [.init(start: Date().addingTimeInterval(-7200), meters: 2300, seconds: 1820),
                        .init(start: Date().addingTimeInterval(-86400), meters: 3100, seconds: 2400)]
            d.places = [.init(id: "a", name: "Hundezone Augarten", kind: "Hundezone", lat: 48.2265, lon: 16.3755),
                        .init(id: "b", name: "Englische Wiese", kind: "Park", lat: 48.2235, lon: 16.3700)]
            d.dues = [.init(id: "due_x", title: "Milbemax", kind: "Entwurmung", due: Date().addingTimeInterval(3 * 86400), doneable: true)]
            d.air = 33
            d.airAt = Date()
            digest = d
        }
        if args.contains("-fertig") {
            finished = .init(id: "walk_probe", start: 0, end: 1, seconds: 1421, meters: 1840, path: "")
        }
        #endif
    }

    /// Läuft eine Runde auf dem iPhone? Dann zeigt und steuert die Watch nur.
    /// Ein alter Stand (das iPhone schickt nichts mehr) blockiert den Start auf der Watch nicht.
    var followsPhone: Bool { phase == .idle && phone.isRunning(at: Date()) }
    var shownPhase: WatchLink.Phase { followsPhone ? phone.phase : phase }
    var shownMeters: Double { followsPhone ? phone.meters : meters }
    func shownSeconds(at now: Date) -> Double {
        followsPhone ? phone.seconds(at: now) : banked + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    func start() {
        guard !followsPhone else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        denied = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
        guard !denied else { return }
        coordinates = []
        meters = 0
        banked = 0
        last = nil
        startedAt = Date()
        runningSince = Date()
        phase = .recording
        begin()
        persist()
        report()
        WKInterfaceDevice.current().play(.start)
    }

    func togglePause() {
        if followsPhone { send(phone.phase == .paused ? .resume : .pause); return }
        phase == .paused ? resume() : pause()
    }

    private func pause() {
        guard phase == .recording else { return }
        banked += runningSince.map { Date().timeIntervalSince($0) } ?? 0
        runningSince = nil
        phase = .paused
        last = nil
        persist()
        report()
    }

    private func resume() {
        guard phase == .paused else { return }
        runningSince = Date()
        phase = .recording
        begin()
        persist()
        report()
    }

    func end() {
        if followsPhone { send(.finish); return }
        let total = shownSeconds(at: Date())
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        if let startedAt, meters >= 20 || total >= 60 {
            finished = .init(id: "walk_w" + UUID().uuidString.lowercased(), start: startedAt.timeIntervalSince1970 * 1000,
                             end: Date().timeIntervalSince1970 * 1000, seconds: total, meters: meters,
                             path: Polyline.encode(Track.simplify(coordinates)))
        }
        reset()
        // Abschließen heißt Behalten: Die Runde geht gleich ans iPhone. Wer sie nicht will, bricht sie ab.
        if let finished { transfer(finished) }
        WKInterfaceDevice.current().play(.stop)
    }

    /// Bricht die laufende Runde ab, ohne sie zu speichern – hier oder, wenn sie dort läuft, auf dem iPhone.
    func discardRunning() {
        if followsPhone { send(.discard); return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        reset()
        WKInterfaceDevice.current().play(.failure)
    }

    /// Geht in die Warteschlange des Systems und kommt auch an, wenn das iPhone gerade weit weg ist.
    private func transfer(_ walk: WatchLink.FinishedWalk) {
        guard let data = try? JSONEncoder().encode(walk) else { return }
        WCSession.default.transferUserInfo([WatchLink.walkKey: data])
    }

    /// Schließt die Zusammenfassung der eben gespeicherten Runde.
    func closeFinished() { finished = nil }

    private func begin() {
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    private func reset() {
        phase = .idle
        coordinates = []
        meters = 0
        banked = 0
        runningSince = nil
        startedAt = nil
        last = nil
        try? FileManager.default.removeItem(at: file)
        report()
    }

    /// Sagt dem iPhone, ob und wie weit hier eine Runde läuft: Dort gibt es dann keine zweite, und der
    /// Sperrbildschirm zeigt sie als Live-Aktivität. Die Nachricht weckt die App auf dem iPhone auch im
    /// Hintergrund; der Kontext kommt an, sobald sie das nächste Mal läuft.
    fileprivate func report() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let status = WatchLink.WatchStatus(phase: phase, meters: meters, banked: banked, runningSince: runningSince, startedAt: startedAt)
        guard let data = try? JSONEncoder().encode(status) else { return }
        reportedAt = Date()
        try? WCSession.default.updateApplicationContext([WatchLink.watchStatusKey: data])
        if WCSession.default.isReachable {
            WCSession.default.sendMessage([WatchLink.watchStatusKey: data], replyHandler: nil, errorHandler: nil)
        }
    }

    /// Ein Befehl für die Runde auf dem iPhone. Ist es nicht erreichbar oder geht die Nachricht verloren, wartet der
    /// Befehl in der Warteschlange des Systems; das iPhone prüft beim Ankommen, ob er noch passt. Die Watch zeigt den
    /// erwarteten Stand gleich an – der echte vom iPhone ersetzt ihn, sobald er kommt.
    private func send(_ c: WatchLink.Command) {
        let walk = phone.startedAt?.timeIntervalSince1970
        let at = Date().timeIntervalSince1970
        let session = WCSession.default
        // Ohne aktive Verbindung kommt der Befehl nirgends hin – dann bleibt auch die Anzeige, wie sie ist.
        guard session.activationState == .activated else {
            WKInterfaceDevice.current().play(.failure)
            show(String(localized: "Keine Verbindung zum iPhone."))
            return
        }
        if session.isReachable {
            session.sendMessage(Self.message(c, walk: walk, at: at), replyHandler: nil) { [weak self] _ in
                Task { @MainActor in self?.queue(c, walk: walk, at: at) }
            }
            WKInterfaceDevice.current().play(.click)
        } else {
            queue(c, walk: walk, at: at)
        }
        expect(c)
    }

    private static func message(_ c: WatchLink.Command, walk: Double?, at: Double) -> [String: Any] {
        var m: [String: Any] = [WatchLink.commandKey: c.rawValue, WatchLink.commandAtKey: at]
        if let walk { m[WatchLink.commandWalkKey] = walk }
        return m
    }

    private func queue(_ c: WatchLink.Command, walk: Double?, at: Double) {
        WCSession.default.transferUserInfo(Self.message(c, walk: walk, at: at))
        WKInterfaceDevice.current().play(.retry)
        show(String(localized: "Geht ans iPhone, sobald es in der Nähe ist."))
    }

    private func show(_ note: String) {
        queuedNote = note
        noteExpiry?.cancel()
        noteExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.queuedNote = nil }
        }
    }

    /// Der Stand, den das iPhone nach dem Befehl haben wird.
    private func expect(_ c: WatchLink.Command) {
        let now = Date()
        switch c {
        case .pause:
            phone.banked = phone.seconds(at: now)
            phone.runningSince = nil
            phone.phase = .paused
        case .resume:
            phone.runningSince = now
            phone.phase = .recording
        case .finish, .discard:
            phone.phase = .idle
            phone.runningSince = nil
        }
    }

    fileprivate func take(_ loc: CLLocation) {
        guard phase == .recording, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= Track.maxAccuracy else { return }
        if let last {
            guard let d = Track.step(from: last, to: loc) else { return }
            meters += d
        }
        last = loc
        coordinates.append(loc.coordinate)
        if coordinates.count % 10 == 0 { persist() }
        if Date().timeIntervalSince(reportedAt) >= 60 { report() }
    }

    fileprivate func apply(_ status: WatchLink.PhoneStatus) {
        // Ein älterer Stand (Kontext nach Nachricht) überschreibt keinen neueren.
        if let new = status.sent, let old = phone.sent, new < old { return }
        phone = status
        phoneExpiry?.cancel()
        guard status.phase != .idle, let sent = status.sent else { return }
        // `followsPhone` hängt an der Uhrzeit: Läuft der Stand ab, muss die Ansicht es auch erfahren.
        let left = sent.addingTimeInterval(WatchLink.PhoneStatus.validFor).timeIntervalSinceNow
        phoneExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(left, 0)))
            guard !Task.isCancelled, let self, self.phone.sent == sent else { return }
            self.phone.phase = .idle
            self.phone.runningSince = nil
        }
    }

    fileprivate func apply(_ d: WatchLink.Digest) {
        guard d != digest else { return }
        digest = d
        DigestShelf.save(d)
    }

    /// Abhaken auf der Watch: Geht über die Warteschlange des Systems und kommt auch an, wenn das iPhone weit weg ist.
    func markDone(_ id: String) {
        WCSession.default.transferUserInfo([WatchLink.doneKey: id])
        digest.dues.removeAll { $0.id == id }
        DigestShelf.save(digest)
        WKInterfaceDevice.current().play(.success)
    }


    fileprivate func changed(_ status: CLAuthorizationStatus) {
        denied = status == .denied || status == .restricted
        if phase == .recording, !denied { begin() }
    }

    // MARK: Sichern

    private struct Saved: Codable {
        var phase: WatchLink.Phase
        var lat: [Double]
        var lon: [Double]
        var meters: Double
        var banked: Double
        var runningSince: Date?
        var startedAt: Date?
    }

    private func persist() {
        let s = Saved(phase: phase, lat: coordinates.map(\.latitude), lon: coordinates.map(\.longitude), meters: meters,
                      banked: banked, runningSince: runningSince, startedAt: startedAt)
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
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
        if phase == .recording { begin() }
    }
}

extension WatchModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in for l in locations { self.take(l) } }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.changed(status) }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.report() }
        take(session.receivedApplicationContext)
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) { take(context) }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { take(message) }

    /// Stand der Runde und Zusammenfassung, wie sie vom iPhone kommen.
    private nonisolated func take(_ dict: [String: Any]) {
        if let data = dict[WatchLink.statusKey] as? Data, let status = try? JSONDecoder().decode(WatchLink.PhoneStatus.self, from: data) {
            Task { @MainActor in self.apply(status) }
        }
        if let data = dict[WatchLink.digestKey] as? Data, let d = try? JSONDecoder().decode(WatchLink.Digest.self, from: data) {
            Task { @MainActor in self.apply(d) }
        }
    }
}

// MARK: Ansichten

struct WalkView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        if let walk = model.finished {
            FinishedView(walk: walk)
        } else if model.shownPhase == .idle {
            StartView()
        } else {
            RunningView()
        }
    }
}

private struct StartView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let d = model.digest
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        let name = model.phone.dogName.isEmpty ? d.dogName : model.phone.dogName
                        Text(name.isEmpty ? String(localized: "Gassi") : String(localized: "Gassi mit \(name)"))
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .minimumScaleFactor(0.7)
                        if let paws = d.heat(), let air = d.air, let surface = d.surface() { HeatLine(paws: paws, air: air, surface: surface) }
                        if let note = model.queuedNote {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                        if model.denied {
                            Text("Erlaube den Standort in den Einstellungen der Watch.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button { model.start() } label: {
                            Text("Runde starten").font(.system(.headline, design: .rounded)).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .foregroundStyle(.black)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    if !d.places.isEmpty {
                        NavigationLink { PlacesView() } label: { row("Ziele", "\(d.places.count)", symbol: "location.north.circle") }
                    }
                    NavigationLink { WeekView() } label: {
                        row("Woche", "\(WalkText.km(d.weekMeters)) km", symbol: "pawprint")
                    }
                    if !d.dues.isEmpty {
                        NavigationLink { DuesView() } label: { row("Ansteht", "\(d.dues.count)", symbol: "cross.case") }
                    }
                }
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(Mandarine.color)
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// „31 °C – Asphalt 62 °C“, rot oder gelb.
private struct HeatLine: View {
    let paws: Asphalt.Paws
    let air: Double
    let surface: Double

    var body: some View {
        let color: Color = paws == .bad ? .red : .yellow
        VStack(alignment: .leading, spacing: 1) {
            Label("\(Int(air.rounded())) °C – Asphalt \(Int(surface.rounded())) °C", systemImage: "sun.max.fill")
                .font(.footnote.weight(.semibold)).foregroundStyle(color)
            Text(paws == .bad ? String(localized: "Zu heiß für die Pfoten. Auf Gras ausweichen.") : String(localized: "Schattenroute wählen."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: Ziele

private struct PlacesView: View {
    @Environment(WatchModel.self) private var model
    @State private var guide = Guide()

    var body: some View {
        List(model.digest.places) { p in
            NavigationLink { GuideView(place: p, guide: guide) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).lineLimit(2)
                    HStack(spacing: 4) {
                        Text(p.kind)
                        if let m = guide.distance(to: p) { Text("· \(WalkText.distance(m))") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Ziele")
        .onAppear { guide.start() }
        .onDisappear { guide.stop() }
    }
}

/// Wo man steht und wohin die Uhr zeigt – für den Pfeil zum Ziel.
@MainActor
@Observable
final class Guide: NSObject, CLLocationManagerDelegate {
    private(set) var here: CLLocation?
    private(set) var heading: Double?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var users = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
    }

    func start() {
        users += 1
        guard users == 1 else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func distance(to p: WatchLink.Digest.Place) -> Double? {
        here.map { $0.distance(from: CLLocation(latitude: p.lat, longitude: p.lon)) }
    }

    /// Richtung zum Ziel, von Norden im Uhrzeigersinn (Grad).
    func bearing(to p: WatchLink.Digest.Place) -> Double? {
        guard let here else { return nil }
        let φ1 = here.coordinate.latitude * .pi / 180, φ2 = p.lat * .pi / 180
        let Δλ = (p.lon - here.coordinate.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 60 else { return }
        Task { @MainActor in self.here = l }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        let v = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        Task { @MainActor in self.heading = v }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

private struct GuideView: View {
    let place: WatchLink.Digest.Place
    let guide: Guide
    @State private var arrived = false

    var body: some View {
        let dist = guide.distance(to: place)
        VStack(spacing: 6) {
            if let dist, dist < 40 {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Mandarine.color)
                Text("Angekommen").font(.system(.headline, design: .rounded))
            } else if let b = guide.bearing(to: place) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(Mandarine.color)
                    // Ohne Kompass zeigt der Pfeil nach Norden-oben wie eine Karte.
                    .rotationEffect(.degrees(b - (guide.heading ?? 0)))
                    .animation(.easeOut(duration: 0.3), value: b - (guide.heading ?? 0))
                if let dist { Text(WalkText.distance(dist)).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit() }
                if guide.heading == nil { Text("Pfeil zeigt nach Norden ausgerichtet.").font(.caption2).foregroundStyle(.secondary) }
            } else {
                ProgressView()
                Text("Suche Standort …").font(.footnote).foregroundStyle(.secondary)
            }
            Text(place.name).font(.footnote).multilineTextAlignment(.center).lineLimit(2)
        }
        .onAppear { guide.start() }
        .onDisappear { guide.stop() }
        .onChange(of: (dist ?? 999) < 40) { _, now in
            if now, !arrived { arrived = true; WKInterfaceDevice.current().play(.success) }
        }
    }
}

// MARK: Woche

private struct WeekView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let d = model.digest
        List {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(WalkText.km(d.weekMeters)) km").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text(d.weekWalks == 1 ? String(localized: "1 Runde seit Montag") : String(localized: "\(d.weekWalks) Runden seit Montag"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            if !d.recent.isEmpty {
                Section("Letzte Runden") {
                    ForEach(d.recent) { w in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(AppLocale.current)))
                                .font(.caption2).foregroundStyle(.secondary)
                            HStack {
                                Text("\(WalkText.km(w.meters)) km").monospacedDigit()
                                Spacer()
                                Text(WalkText.clock(w.seconds)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Woche")
    }
}

// MARK: Was ansteht

private struct DuesView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        List(model.digest.dues) { due in
            VStack(alignment: .leading, spacing: 4) {
                Text(due.title).font(.headline).lineLimit(2)
                Text(Self.when(due)).font(.caption2).foregroundStyle(due.due < Calendar.current.startOfDay(for: Date()) ? .red : .secondary)
                if due.doneable {
                    Button("Erledigt") { model.markDone(due.id) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).foregroundStyle(.black)
                }
            }
        }
        .navigationTitle("Was ansteht")
    }

    static func when(_ due: WatchLink.Digest.Due) -> String {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: due.due)).day ?? 0
        if n < 0 { return String(localized: "\(due.kind), seit \(-n) Tagen fällig") }
        if n == 0 { return String(localized: "\(due.kind), heute fällig") }
        return n == 1 ? String(localized: "\(due.kind), in 1 Tag fällig") : String(localized: "\(due.kind), in \(n) Tagen fällig")
    }
}

/// Abschließen speichert die Runde sofort. Abbrechen (klein, mit Rückfrage) beendet sie ohne Speichern.
private struct RunningView: View {
    @Environment(WatchModel.self) private var model
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(status).font(.footnote.weight(.semibold)).foregroundStyle(model.shownPhase == .paused ? .secondary : Mandarine.color)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        // Klein und mit Rückfrage, auf Höhe von „Unterwegs“: Abbrechen ist die Ausnahme.
                        Button("Abbrechen") { confirmsDiscard = true }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(WalkText.clock(model.shownSeconds(at: ctx.date)))
                        .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(WalkText.km(model.shownMeters)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("km").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            if let note = model.queuedNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { model.togglePause() } label: {
                    Text(model.shownPhase == .paused ? String(localized: "Weiter") : String(localized: "Pause")).font(.system(.body, design: .rounded, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonBorderShape(.capsule)
                // Abschließen heißt Speichern – ohne Rückfrage.
                Button { model.end() } label: {
                    Text("Abschließen").font(.system(.body, design: .rounded, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 40)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .foregroundStyle(.black)
            }
        }
        .confirmationDialog("Runde abbrechen?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Runde verwerfen", role: .destructive) { model.discardRunning() }
            Button("Weiterlaufen", role: .cancel) {}
        } message: {
            Text("Die Runde wird nicht gespeichert.")
        }
    }

    private var status: String {
        let where_ = model.followsPhone ? String(localized: " auf dem iPhone") : ""
        return (model.shownPhase == .paused ? String(localized: "Pause") : String(localized: "Unterwegs")) + where_
    }
}

private struct FinishedView: View {
    @Environment(WatchModel.self) private var model
    let walk: WatchLink.FinishedWalk

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Runde gespeichert").font(.footnote.weight(.semibold)).foregroundStyle(Mandarine.color)
            Text(WalkText.distance(walk.meters)).font(.system(size: 34, weight: .bold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
            Text(WalkText.duration(walk.seconds)).font(.system(.headline, design: .rounded)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { model.closeFinished() } label: {
                Text("Fertig").font(.system(.body, design: .rounded, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .foregroundStyle(.black)
        }
    }
}
