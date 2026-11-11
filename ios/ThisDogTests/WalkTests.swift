import CoreLocation
import Foundation
import Testing
@testable import ThisDog

@Suite("Gassirunde")
struct WalkTests {
    private let wien = CLLocationCoordinate2D(latitude: 48.2245, longitude: 16.3780)

    private func loc(_ dLatM: Double, _ dLonM: Double, accuracy: Double = 5, at t: TimeInterval) -> CLLocation {
        let c = CLLocationCoordinate2D(latitude: wien.latitude + dLatM / 111_320,
                                       longitude: wien.longitude + dLonM / (111_320 * cos(wien.latitude * .pi / 180)))
        return CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                          timestamp: Date(timeIntervalSince1970: 1_800_000_000 + t))
    }

    @Test("Polyline: hin und zurück auf etwa einen Meter genau")
    func polyline() {
        let pts = [wien, CLLocationCoordinate2D(latitude: 48.22513, longitude: 16.37944),
                   CLLocationCoordinate2D(latitude: 48.2301, longitude: 16.3702)]
        let back = Polyline.decode(Polyline.encode(pts))
        #expect(back.count == 3)
        for (a, b) in zip(pts, back) { #expect(Track.distance(a, b) < 1.5) }
    }

    @Test("Glätten lässt Punkte auf einer Geraden weg, behält Ecken")
    func simplify() {
        let straight = (0...20).map { CLLocationCoordinate2D(latitude: wien.latitude + Double($0) * 0.0001, longitude: wien.longitude) }
        #expect(Track.simplify(straight).count == 2)
        let corner = straight + [CLLocationCoordinate2D(latitude: straight.last!.latitude, longitude: wien.longitude + 0.002)]
        #expect(Track.simplify(corner).count == 3)
    }

    @Test("Ungenaue Punkte und Sprünge zählen nicht, normale Schritte schon")
    @MainActor func filters() {
        let r = WalkRecorder(liveLocation: false)
        r.discard()
        r.start()
        #expect(r.take(loc(0, 0, at: 0)))
        #expect(!r.take(loc(10, 0, accuracy: 80, at: 10)))       // zu ungenau
        #expect(!r.take(loc(1, 0, at: 12)))                      // kaum bewegt
        #expect(r.take(loc(15, 0, at: 20)))                      // 15 m in 20 s
        #expect(!r.take(loc(500, 0, at: 25)))                    // 485 m in 5 s: Sprung
        #expect(abs(r.meters - 15) < 0.5)
        r.discard()
    }

    @Test("Der Stand der Watch bringt Strecke und Zeit mit; ältere Fassungen ohne sie gelten weiter")
    func watchStatusCarriesProgress() throws {
        let now = Date()
        let s = WatchLink.WatchStatus(phase: .recording, sent: now, meters: 820, banked: 300, runningSince: now, startedAt: now.addingTimeInterval(-600))
        let back = try JSONDecoder().decode(WatchLink.WatchStatus.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let old = try JSONDecoder().decode(WatchLink.WatchStatus.self, from: Data(#"{"phase":"recording","sent":0}"#.utf8))
        #expect(old.meters == nil)
        #expect(old.phase == .recording)
    }

    @Test("Läuft eine Runde auf der Watch, startet das iPhone keine zweite")
    @MainActor func noSecondWalkBesideWatch() {
        let r = WalkRecorder(liveLocation: false)
        r.discard()
        r.watchWalk(running: true)
        r.start()
        #expect(r.phase == .idle)
        r.watchWalk(running: false)
        r.start()
        #expect(r.phase == .recording)
        r.discard()
    }

    @Test("Eine verstummte Watch gibt den Start nach einer Stunde wieder frei")
    func silentWatchExpires() {
        let now = Date()
        #expect(WatchLink.WatchStatus(phase: .recording, sent: now.addingTimeInterval(-3599)).isRunning(at: now))
        #expect(!WatchLink.WatchStatus(phase: .recording, sent: now.addingTimeInterval(-3601)).isRunning(at: now))
        #expect(!WatchLink.WatchStatus(phase: .idle, sent: now).isRunning(at: now))
    }

    @Test("In der Pause wächst die Strecke nicht")
    @MainActor func pause() {
        let r = WalkRecorder(liveLocation: false)
        r.discard()
        r.start()
        r.take(loc(0, 0, at: 0))
        r.take(loc(20, 0, at: 20))
        r.pause()
        #expect(!r.take(loc(60, 0, at: 60)))
        r.resume()
        r.take(loc(60, 0, at: 70))    // erster Punkt nach der Pause: Anfang, kein Weg
        r.take(loc(80, 0, at: 90))
        #expect(abs(r.meters - 40) < 0.5)
        r.discard()
    }

    @Test("Ein voller Kilometer wird als Abschnitt vermerkt")
    @MainActor func splits() {
        let r = WalkRecorder(liveLocation: false)
        r.discard()
        r.start()
        for i in 0...110 { r.take(loc(Double(i) * 10, 0, at: Double(i) * 8)) }
        #expect(r.splits.count == 1)
        r.discard()
    }

    @Test("Beenden liefert die Runde mit gemessener Länge und kodierter Strecke")
    @MainActor func finish() throws {
        let r = WalkRecorder(liveLocation: false)
        r.discard()
        r.start()
        for i in 0...30 { r.take(loc(Double(i) * 10, Double(i % 2) * 6, at: Double(i) * 8)) }
        let w = try #require(r.finish())
        #expect(w.meters > 300)
        #expect(w.coordinates.count >= 2)
        #expect(r.phase == .idle)
        #expect(Walk.kind == "walk")
    }

    @Test("Zu kurz gelaufen: keine Runde")
    @MainActor func tooShort() {
        let r = WalkRecorder(liveLocation: false)
        r.discard()
        r.start()
        r.take(loc(0, 0, at: 0))
        #expect(r.finish() == nil)
    }

    @Test("Texte: Strecke, Uhr, Tempo")
    func texts() {
        #expect(WalkText.distance(640) == "640 m")
        #expect(WalkText.distance(1843) == "1,84 km")
        #expect(WalkText.clock(1421) == "23:41")
        #expect(WalkText.clock(3912) == "1:05:12")
        #expect(WalkText.pace(12.87) == "12:52")
    }
}

@Suite("Runde auf dem iPhone, gesteuert von der Watch")
struct PhoneWalkFromWatchTests {
    @Test("Ein verstummtes iPhone gibt den Start auf der Watch wieder frei; ältere iPhone-Apps ohne Zeitstempel gelten weiter")
    func silentPhoneExpires() throws {
        let now = Date()
        let valid = WatchLink.PhoneStatus.validFor
        #expect(WatchLink.PhoneStatus(phase: .recording, sent: now.addingTimeInterval(-valid + 1)).isRunning(at: now))
        #expect(!WatchLink.PhoneStatus(phase: .paused, sent: now.addingTimeInterval(-valid - 1)).isRunning(at: now))
        #expect(!WatchLink.PhoneStatus(phase: .idle, sent: now).isRunning(at: now))
        // Das iPhone schickt öfter, als der Stand gilt – sonst liefe er zwischen zwei Sendungen ab.
        #expect(WatchLink.PhoneStatus.resendEvery * 2 < valid)
        let old = try JSONDecoder().decode(WatchLink.PhoneStatus.self, from: Data(#"{"dogName":"Stella","phase":"recording","meters":0,"banked":0}"#.utf8))
        #expect(old.sent == nil)
        #expect(old.isRunning(at: now))
    }

    @Test("Ein Befehl aus der Warteschlange gilt nur für dieselbe Runde, Pause und Weiter nur, solange sie frisch sind")
    func queuedCommands() {
        let now = Date()
        let started = now.addingTimeInterval(-1800)
        #expect(WatchLink.Command.finish.applies(walk: started, sentAt: now.addingTimeInterval(-3600), queued: true, running: started, now: now))
        #expect(!WatchLink.Command.discard.applies(walk: started, sentAt: now, queued: true, running: started.addingTimeInterval(600), now: now))
        #expect(!WatchLink.Command.finish.applies(walk: started, sentAt: now, queued: false, running: nil, now: now))
        #expect(WatchLink.Command.pause.applies(walk: started, sentAt: now.addingTimeInterval(-60), queued: true, running: started, now: now))
        #expect(!WatchLink.Command.pause.applies(walk: started, sentAt: now.addingTimeInterval(-3600), queued: true, running: started, now: now))
        // Direkt angekommen und von einer älteren Watch ohne Runden-Beginn: wie bisher.
        #expect(WatchLink.Command.resume.applies(walk: nil, sentAt: nil, queued: false, running: started, now: now))
    }

    @Test("Der Stand vom iPhone trägt Zeitstempel und Beginn der Runde")
    @MainActor func phoneStatusStamped() {
        let r = WalkRecorder(liveLocation: false)
        r.discard()
        r.start()
        let s = r.watchStatus(dogName: "Stella")
        #expect(s.sent.map { abs($0.timeIntervalSinceNow) < 5 } == true)
        #expect(s.startedAt == r.startedAt)
        r.discard()
    }
}
