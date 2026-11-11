import Foundation
import Testing
import UIKit
@testable import ThisDog

@Suite("Abgleich auf dem Gerät")
@MainActor
struct SyncTests {
    private func freshStore() -> DogStore {
        DogStore(file: URL.temporaryDirectory.appending(path: "sync-test-\(UUID().uuidString).json"))
    }

    private func record(_ id: String, _ title: String?, at u: Double, by: Int? = nil) throws -> SyncRecord {
        var ev = DogEvent(id: id, title: title ?? "", start: Day(2026, 10, 20))
        ev.u = u
        return SyncRecord(kind: "event", id: id, updatedAt: u, by: by, payload: title == nil ? nil : try JSONValue.from(ev))
    }

    @Test("Beitreten: Profil und Hundebild des Rudels gelten, nicht die beim Einrichten getippten")
    func joinKeepsPackDog() throws {
        let s = freshStore()
        var mine = DogProfile(); mine.name = "stella"
        s.save(mine)
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 40, height: 40)) }
        s.setAvatar(Avatar.dog, photo: photo.jpegData(compressionQuality: 0.8))
        #expect(s.avatarImage(Avatar.dog) != nil)
        s.save(DogEvent(id: "evt_mein", title: "Tierarzt", start: Day(2026, 11, 12)))
        s.joinPack(7)
        // Was neu dazukommt, geht hinaus – Profil und Hundebild nicht.
        let out = Set(s.outgoingRecords().map(\.kind))
        #expect(out.contains("event"))
        #expect(!out.contains("profile") && !out.contains("avatar"))
        // Das Rudel hat ein älteres, aber vollständiges Profil: Es gewinnt.
        var pack = DogProfile(); pack.name = "Stella"; pack.chip = "276"
        s.applyIncoming([SyncRecord(kind: "profile", id: "profile", updatedAt: 10, payload: try JSONValue.from(pack))], rev: 3, sent: [])
        s.claimUnanswered()
        #expect(s.profile.name == "Stella" && s.profile.chip == "276")
        // Ein Hundebild hatte das Rudel nicht: Das von hier gehört jetzt dazu.
        let after = s.outgoingRecords()
        #expect(after.contains { $0.kind == "avatar" && $0.id == Avatar.dog && $0.updatedAt > 0 })
        #expect(!after.contains { $0.kind == "profile" })
    }

    @Test("Ein offener Notfallpass schreibt nur seine Änderungen zurück, nicht den veralteten Rest")
    func profileEditsMergeOntoCurrent() {
        var base = DogProfile(); base.name = "Anna"
        var draft = base; draft.chip = "276"
        var current = DogProfile(); current.name = "Stella"; current.vetName = "Dr. Huber"; current.weightKg = 12
        let merged = current.applying(edits: draft, since: base)
        #expect(merged.name == "Stella" && merged.chip == "276" && merged.vetName == "Dr. Huber" && merged.weightKg == 12)
    }

    @Test("Eigene Änderungen gehen hinaus, im Format der Web-App")
    func outgoing() throws {
        let s = freshStore()
        s.save(DogEvent(id: "evt_a", title: "Tierarzt", start: Day(2026, 10, 20)))
        let out = s.outgoingRecords()
        #expect(out.count == 1)
        #expect(out[0].kind == "event")
        let payload = try #require(out[0].payload)
        #expect(try payload.decode(DogEvent.self).title == "Tierarzt")
    }

    @Test("Nach dem Abgleich ist nichts mehr offen")
    func clearedAfterSync() {
        let s = freshStore()
        s.save(DogEvent(id: "evt_a", title: "Tierarzt", start: Day(2026, 10, 20)))
        let sent = s.outgoingRecords()
        s.applyIncoming([], rev: 3, sent: sent)
        #expect(s.outgoingRecords().isEmpty)
        #expect(s.rev == 3)
    }

    @Test("Eine Änderung während des Abgleichs bleibt offen")
    func editDuringSync() async throws {
        let s = freshStore()
        s.save(DogEvent(id: "evt_a", title: "Tierarzt", start: Day(2026, 10, 20)))
        let sent = s.outgoingRecords()
        try await Task.sleep(for: .milliseconds(5))
        var ev = try #require(s.event(id: "evt_a"))
        ev.title = "Tierarzt, 10:30"
        s.save(ev)
        s.applyIncoming([], rev: 3, sent: sent)
        #expect(s.outgoingRecords().map(\.id) == ["evt_a"])
    }

    @Test("Aus dem Rudel: Neueres gewinnt, Älteres nicht, und es wird vermerkt, wer es war")
    func incoming() throws {
        let s = freshStore()
        var mine = DogEvent(id: "evt_a", title: "Meins", start: Day(2026, 10, 20))
        s.save(mine)
        mine = try #require(s.event(id: "evt_a"))
        s.applyIncoming([try record("evt_a", "Älter", at: mine.u - 1000, by: 7)], rev: 1, sent: [])
        #expect(s.event(id: "evt_a")?.title == "Meins")
        s.applyIncoming([try record("evt_a", "Neuer", at: mine.u + 1000, by: 7),
                         try record("evt_b", "Von Anna", at: 5, by: 7)], rev: 2, sent: [])
        #expect(s.event(id: "evt_a")?.title == "Neuer")
        #expect(s.event(id: "evt_b")?.title == "Von Anna")
        #expect(s.changedBy["event:evt_b"] == 7)
    }

    @Test("Eine Löschung aus dem Rudel entfernt den Termin und kommt nicht als Änderung zurück")
    func incomingDelete() throws {
        let s = freshStore()
        s.applyIncoming([try record("evt_b", "Von Anna", at: 5)], rev: 1, sent: [])
        s.applyIncoming([try record("evt_b", nil, at: 9)], rev: 2, sent: [])
        #expect(s.event(id: "evt_b") == nil)
        #expect(s.outgoingRecords().isEmpty)
    }

    @Test("Eigene Löschung geht als Grabstein hinaus")
    func ownDelete() throws {
        let s = freshStore()
        s.applyIncoming([try record("evt_b", "Von Anna", at: 5)], rev: 1, sent: [])
        s.delete(id: "evt_b")
        let out = s.outgoingRecords()
        #expect(out.map(\.id) == ["evt_b"])
        #expect(out[0].payload == nil)
    }

    @Test("Beim Verlassen bleibt das Gerät leer, beim Beitreten wandert alles mit")
    func switching() {
        let s = freshStore()
        s.save(DogEvent(id: "evt_a", title: "Meins", start: Day(2026, 10, 20)))
        s.applyIncoming([], rev: 4, sent: s.outgoingRecords())
        s.switchPack(to: 9, keepLocal: true)
        #expect(s.rev == 0)
        #expect(s.outgoingRecords().map(\.id) == ["evt_a"])
        s.switchPack(to: nil, keepLocal: false)
        #expect(s.events.isEmpty)
        #expect(s.outgoingRecords().isEmpty)
    }

    /// Ein großes, unruhiges Foto – Rauschen komprimiert schlecht, also der ungünstige Fall.
    private func noisyPhoto(_ w: Int, _ h: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            var g = SystemRandomNumberGenerator()
            for x in stride(from: 0, to: w, by: 8) {
                for y in stride(from: 0, to: h, by: 8) {
                    UIColor(red: .random(in: 0...1, using: &g), green: .random(in: 0...1, using: &g), blue: .random(in: 0...1, using: &g), alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        return img.jpegData(compressionQuality: 0.95)!
    }

    @Test("Ein Foto wird quadratisch und klein genug für einen Datensatz (Server: 80 000 Zeichen)")
    func avatarFitsRecord() throws {
        let jpeg = try #require(Avatar.prepare(noisyPhoto(1600, 1200)))
        let record = try JSONEncoder().encode(Avatar(id: Avatar.dog, jpeg: jpeg))
        #expect(record.count < 80_000)
        let data = try #require(Data(base64Encoded: jpeg))
        let img = try #require(UIImage(data: data))
        #expect(img.size.width == img.size.height && img.size.width >= 240)
    }

    @Test("Bilder laufen durch den Abgleich: hinaus, aus dem Rudel herein, und entfernt als Löschung")
    func avatarSync() throws {
        let s = freshStore()
        s.setAvatar(Avatar.dog, photo: noisyPhoto(400, 300))
        let out = s.outgoingRecords()
        #expect(out.map(\.kind) == ["avatar"])
        #expect(s.avatarImage(Avatar.dog) != nil)

        let other = Avatar(id: Avatar.member(7), jpeg: try #require(Avatar.prepare(noisyPhoto(300, 300))), u: 5_000)
        s.applyIncoming([SyncRecord(kind: "avatar", id: other.id, updatedAt: 5_000, by: 7, payload: try JSONValue.from(other))], rev: 3, sent: out)
        #expect(s.avatarImage(Avatar.member(7)) != nil)
        #expect(s.outgoingRecords().isEmpty)

        s.setAvatar(Avatar.dog, photo: nil)
        #expect(s.avatarImage(Avatar.dog) == nil)
        let gone = s.outgoingRecords()
        #expect(gone.count == 1 && gone[0].payload == nil)
    }

    @Test("Datensätze aus der Web-App ohne „u“ kommen trotzdem an (Merkliste)")
    func incomingWithoutStamp() {
        let s = freshStore()
        let r = SyncRecord(kind: "favorite", id: "Nudeln (gekocht, ohne Salz)", updatedAt: 1_755_000_000_000, by: 2,
                           payload: .object(["name": .string("Nudeln (gekocht, ohne Salz)")]))
        s.applyIncoming([r], rev: 1, sent: [])
        #expect(s.favorites.map(\.name) == ["Nudeln (gekocht, ohne Salz)"])
    }
}

@Suite("Push-Umfeld")
struct PushEnvironmentTests {
    private func profile(_ aps: String?) throws -> URL {
        let ent = aps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict>\(ent)</dict></dict></plist>"
        // Wie im echten Profil: Binäres vor und nach der Plist.
        var data = Data([0x30, 0x82, 0x01, 0x00]); data.append(Data(xml.utf8)); data.append(Data([0x00, 0xA0, 0x82]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mobileprovision")
        try data.write(to: url)
        return url
    }

    @Test("Das Signierprofil entscheidet, nicht Debug oder Release")
    func fromProfile() throws {
        #expect(PushEnvironment.fromProfile(try profile("development")) == "sandbox")
        #expect(PushEnvironment.fromProfile(try profile("production")) == "production")
        #expect(PushEnvironment.fromProfile(try profile(nil)) == nil)
        #expect(PushEnvironment.fromProfile(nil) == nil)
    }
}
