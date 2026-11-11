import Foundation
import WatchConnectivity

/// Die Verbindung zur Watch: schickt den Stand einer Runde vom iPhone, nimmt Befehle und fertige Runden an.
@MainActor
final class WatchBridge: NSObject {
    private var store: DogStore?
    private var recorder: WalkRecorder?
    private var heat: HeatService?
    private var expiry: Task<Void, Never>?
    /// Schickt den Stand einer laufenden Runde regelmäßig neu – sonst hielte die Watch einen alten Stand für gültig.
    private var heartbeat: Task<Void, Never>?
    private var lastDigest: WatchLink.Digest?
    /// Der letzte Stand einer Runde auf der Watch – fürs Nachholen der Live-Aktivität im Vordergrund.
    private var lastWatch: Data?

    func connect(store: DogStore, recorder: WalkRecorder, heat: HeatService) {
        guard WCSession.isSupported() else { return }
        self.store = store
        self.recorder = recorder
        self.heat = heat
        recorder.onChange = { [weak self] in self?.send() }
        PlaceFinder.onFound = { [weak self] in self?.refresh() }
        WCSession.default.delegate = self
        WCSession.default.activate()
        LiveStart.observe()
    }

    /// Die App ist wieder vorn: Läuft eine Runde auf der Watch und fehlt die Anzeige (Push kam nicht an),
    /// startet sie jetzt die App selbst.
    func becameActive() {
        refresh()
        if let lastWatch { applyWatch(lastWatch) }
    }

    /// Etwas außerhalb der Runde hat sich geändert (Runden, Gesundheit, Wetter, Ziele). Geschickt wird nur,
    /// wenn die Zusammenfassung dadurch anders aussieht.
    func refresh() {
        guard let d = digest(), d != lastDigest else { return }
        // Fürs Widget auf dem iPhone, auch ohne Watch.
        lastDigest = d
        DigestShelf.save(d)
        send()
    }

    private func send() {
        keepAlive()
        guard let recorder, let store, WCSession.default.activationState == .activated, WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(recorder.watchStatus(dogName: store.profile.name)) else { return }
        var context: [String: Any] = [WatchLink.statusKey: data]
        if let d = digest(), let digestData = try? JSONEncoder().encode(d) {
            context[WatchLink.digestKey] = digestData
            lastDigest = d
            DigestShelf.save(d)
        }
        try? WCSession.default.updateApplicationContext(context)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(context, replyHandler: nil, errorHandler: nil)
        }
    }

    /// Läuft hier eine Runde, geht der Stand spätestens alle paar Minuten an die Watch, auch ohne Änderung
    /// (etwa in der Pause). Bleibt er aus, gibt die Watch den Start nach `PhoneStatus.validFor` wieder frei.
    private func keepAlive() {
        guard let recorder, recorder.phase != .idle else {
            heartbeat?.cancel()
            heartbeat = nil
            return
        }
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(WatchLink.PhoneStatus.resendEvery))
                guard !Task.isCancelled, let self else { return }
                self.send()
            }
        }
    }

    /// Die Zusammenfassung für die Watch.
    func digest(now: Date = Date()) -> WatchLink.Digest? {
        guard let store else { return nil }
        let today = Day(date: now)
        let monday = today.adding(days: -today.weekdayFromMonday)
        let week = store.walks.filter { $0.day >= monday }
        var d = WatchLink.Digest()
        d.dogName = store.profile.name
        d.weekMeters = week.reduce(0) { $0 + $1.meters }
        d.weekWalks = week.count
        d.recent = store.walks.sorted { $0.start > $1.start }.prefix(5)
            .map { .init(start: $0.startDate, meters: $0.meters, seconds: $0.seconds) }
        d.places = PlaceFinder.lastFound.prefix(8).map { .init(id: $0.id, name: $0.name, kind: $0.label, lat: $0.lat, lon: $0.lon) }
        d.dues = store.dues.filter { today.days(until: $0.due) <= 30 && today.days(until: $0.due) >= -60 }.prefix(4)
            .map { .init(id: $0.id, title: $0.title, kind: $0.kind, due: $0.due.date, doneable: store.canMarkDone($0, today: today)) }
        if let heat {
            d.air = heat.air
            d.daylight = heat.daylight
            d.airAt = heat.at
            d.asphalt = heat.conditions
        }
        return d
    }

    private func markDone(_ id: String) {
        guard let store, store.markDone(id) else { return }
        send()
    }

    /// Ein Befehl der Watch für die Runde auf dem iPhone – direkt (`queued: false`) oder über die Warteschlange,
    /// dann womöglich viel später und nur, wenn er noch passt.
    private func perform(_ command: WatchLink.Command, walk: Date? = nil, sentAt: Date? = nil, queued: Bool = false) {
        guard let recorder, recorder.phase != .idle,
              command.applies(walk: walk, sentAt: sentAt, queued: queued, running: recorder.startedAt) else {
            // Passt der Befehl nicht (mehr), erfährt die Watch wenigstens den richtigen Stand.
            send()
            return
        }
        switch command {
        case .pause: recorder.pause()
        case .resume: recorder.resume()
        case .discard: recorder.discard()
        case .finish: if let walk = recorder.finish() { store?.save(walk) }
        }
    }

    private func applyWatch(_ data: Data) {
        guard let recorder, let status = try? JSONDecoder().decode(WatchLink.WatchStatus.self, from: data) else { return }
        // Ein älterer Stand (Kontext nach Nachricht) darf einen neueren nicht überschreiben.
        if let lastWatch, let last = try? JSONDecoder().decode(WatchLink.WatchStatus.self, from: lastWatch), last.sent > status.sent { return }
        lastWatch = data
        expiry?.cancel()
        let running = status.isRunning(at: Date())
        var state: WalkActivityAttributes.ContentState?
        if let meters = status.meters, let banked = status.banked {
            state = .init(meters: meters, banked: banked, runningSince: status.phase == .recording ? status.runningSince : nil)
        }
        recorder.watchWalk(running: running, state: state, startedAt: status.startedAt)
        guard running else { return }
        let left = status.sent.addingTimeInterval(WatchLink.WatchStatus.validFor).timeIntervalSinceNow
        expiry = Task { [weak recorder] in
            try? await Task.sleep(for: .seconds(max(left, 0)))
            if !Task.isCancelled { recorder?.watchWalk(running: false) }
        }
    }

    /// Kam das „vorbei“ der Watch nicht an, verschwindet die Anzeige spätestens mit der fertigen Runde –
    /// aber nur, wenn es dieselbe Runde ist und nicht schon die nächste läuft.
    private func finishedOnWatch(_ data: Data) {
        guard let w = try? JSONDecoder().decode(WatchLink.FinishedWalk.self, from: data),
              let lastWatch, let last = try? JSONDecoder().decode(WatchLink.WatchStatus.self, from: lastWatch),
              let started = last.startedAt, abs(started.timeIntervalSince1970 * 1000 - w.start) < 1000 else { return }
        expiry?.cancel()
        self.lastWatch = nil
        recorder?.watchWalk(running: false)
    }

    private func receive(_ data: Data) {
        guard let w = try? JSONDecoder().decode(WatchLink.FinishedWalk.self, from: data) else { return }
        store?.save(Walk(id: w.id, start: w.start, end: w.end, seconds: w.seconds, meters: w.meters, path: w.path))
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext[WatchLink.watchStatusKey] as? Data
        Task { @MainActor in
            self.send()
            if let context { self.applyWatch(context) }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let data = context[WatchLink.watchStatusKey] as? Data else { return }
        Task { @MainActor in self.applyWatch(data) }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.send() } }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let data = message[WatchLink.watchStatusKey] as? Data {
            Task { @MainActor in self.applyWatch(data) }
        }
        guard let raw = message[WatchLink.commandKey] as? String, let command = WatchLink.Command(rawValue: raw) else { return }
        let walk = (message[WatchLink.commandWalkKey] as? Double).map { Date(timeIntervalSince1970: $0) }
        Task { @MainActor in self.perform(command, walk: walk) }
    }

    /// Fertige Runden kommen über die Warteschlange des Systems: Sie erreichen das iPhone auch dann, wenn es
    /// beim Beenden nicht in der Nähe war.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let id = userInfo[WatchLink.doneKey] as? String {
            Task { @MainActor in self.markDone(id) }
        }
        // Ein Befehl für die Runde hier, der direkt nicht ankam (iPhone gerade nicht erreichbar).
        if let raw = userInfo[WatchLink.commandKey] as? String, let command = WatchLink.Command(rawValue: raw) {
            let walk = (userInfo[WatchLink.commandWalkKey] as? Double).map { Date(timeIntervalSince1970: $0) }
            let at = (userInfo[WatchLink.commandAtKey] as? Double).map { Date(timeIntervalSince1970: $0) }
            Task { @MainActor in self.perform(command, walk: walk, sentAt: at, queued: true) }
        }
        guard let data = userInfo[WatchLink.walkKey] as? Data else { return }
        Task { @MainActor in
            self.receive(data)
            self.finishedOnWatch(data)
        }
    }
}
