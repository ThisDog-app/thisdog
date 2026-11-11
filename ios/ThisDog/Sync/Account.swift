import CryptoKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Anmeldung, Rudel und Abgleich.
///
/// Ein Konto entsteht ohne E-Mail und ohne Passwort, sobald es gebraucht wird: beim Einladen oder wenn
/// eine Einladung ankommt (`ensureAccount`). Die Sitzung gehört diesem Gerät. Eine E-Mail-Adresse lässt
/// sich jederzeit hinzufügen – nur mit ihr kommt man von einem neuen Telefon wieder an dasselbe Konto.
/// Mit Adresse meldet man sich wie bisher per Link oder Code aus der Mail an.
@MainActor
@Observable
final class Account {
    /// `signedIn(email: nil)`: Konto nur auf diesem Gerät, ohne Adresse.
    enum State: Equatable { case unknown, signedOut, linkSent(email: String), signedIn(email: String?) }

    private(set) var state: State = .unknown
    private(set) var packs: [Pack] = []
    private(set) var me: Int?
    private(set) var syncing = false
    private var resyncRequested = false
    /// Ließ sich beim letzten Abgleich alles öffnen? Nur dann ist klar, was das Rudel nicht hat.
    private(set) var lastSyncComplete = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    /// Der Bildschirm „Rudel“ ist offen (von überall aus zu öffnen, auch durch einen Link).
    var presentsPack = false
    /// Eine Mitteilung, die ankam, während die App offen ist – die App zeigt sie selbst an.
    var notice: Notice?
    /// Eine Einladung, die ankam, bevor jemand angemeldet war. Sie wird nach dem Anmelden eingelöst.
    private(set) var pendingInvite: String?
    /// Der Rudel-Schlüssel aus dem Einladungslink (hinter dem `#`, nie beim Server).
    @ObservationIgnored private var pendingKey: SymmetricKey?
    private(set) var joinMessage: String?
    /// Die Mail mit dem Code ist an diese Adresse unterwegs – auch, wenn man schon angemeldet ist und nur
    /// eine Adresse hinzufügt (dann läuft der Abgleich weiter).
    private(set) var codeFor: String?
    /// Gerade per Einladung ins Rudel gekommen: Der Rudel-Bildschirm fragt dann nach dem Namen.
    var justJoined = false
    /// Das Rudel ist verschlüsselt, aber auf diesem Gerät gibt es den Schlüssel nicht.
    private(set) var keyMissing = false

    /// Das Rudel, dessen Daten auf diesem Gerät liegen.
    var currentPack: Pack? { packs.first { $0.id == store.packID } ?? packs.first }

    @ObservationIgnored let api = Api()
    @ObservationIgnored let store: DogStore
    @ObservationIgnored private var pendingSync: Task<Void, Never>?

    /// Hundefreunde: wer befreundet ist, wer gerade unterwegs ist.
    @ObservationIgnored private(set) lazy var friends = Friends(account: self)

    init(store: DogStore) {
        self.store = store
    }

    // MARK: Anmelden

    func refresh() async {
        do {
            let me: Me = try await api.get("auth.php", ["action": "me"])
            if me.signedIn {
                state = .signedIn(email: me.email)
                await loadPacks()
                await sync()
                // Bei jedem Start: Apple kann die Kennung ändern, und der Server soll das Gerät kennen.
                PushRegistration.register()
            } else if case .linkSent = state {
                // bleibt, bis der Link oder der Code kommt
            } else {
                state = .signedOut
            }
        } catch {
            if state == .unknown { state = .signedOut }
        }
    }

    func requestLink(email: String) async throws {
        struct Body: Encodable { let email: String; let app = true; let hasData: Bool }
        let _: Ok = try await api.post("auth.php", ["action": "request"], body: Body(email: email, hasData: !store.events.isEmpty))
        codeFor = email
        if !isSignedIn { state = .linkSent(email: email) }
    }

    var isSignedIn: Bool { if case .signedIn = state { true } else { false } }
    var hasEmail: Bool { if case .signedIn(let mail?) = state { !mail.isEmpty } else { false } }

    /// Ein Konto für dieses Gerät, falls es noch keins gibt – ohne E-Mail, ohne Mail, ohne Warten.
    func ensureAccount() async throws {
        if state == .unknown { await refresh() }
        if isSignedIn { return }
        struct Started: Decodable { let signedIn: Bool; let email: String? }
        let s: Started = try await api.post("auth.php", ["action": "start"], body: [String: String]())
        state = .signedIn(email: s.email)
        codeFor = nil
        await afterSignIn()
    }

    /// Den Link aus der Mail einlösen (kommt als Universal Link herein).
    func confirm(secret: String) async throws {
        struct Body: Encodable { let t: String }
        struct Answer: Decodable { let email: String? }
        let a: Answer = try await api.post("auth.php", ["action": "confirm"], body: Body(t: secret))
        state = .signedIn(email: a.email)
        codeFor = nil
        await afterSignIn()
    }

    func enterCode(_ code: String) async throws {
        guard let email = codeFor else { return }
        struct Body: Encodable { let email: String; let code: String }
        let _: Ok = try await api.post("auth.php", ["action": "code"], body: Body(email: email, code: code))
        state = .signedIn(email: email)
        codeFor = nil
        await afterSignIn()
    }

    func signOut() async {
        let _: Ok? = try? await api.post("auth.php", ["action": "logout"], body: [String: String]())
        state = .signedOut
        codeFor = nil
        packs = []
        keyMissing = false
        store.resetSync()
        PackDirectory.clear()
    }

    func startOver() {
        codeFor = nil
        if case .linkSent = state { state = .signedOut }
    }

    /// Konto löschen: E-Mail, Anmeldungen und Gerätekennungen auf dem Server, dazu Rudel, in denen sonst
    /// niemand ist. Die Daten auf diesem Gerät bleiben; die Schlüssel der eigenen Rudel verschwinden.
    func deleteAccount() async throws {
        let _: Ok = try await api.post("auth.php", ["action": "delete"], body: [String: String]())
        for p in packs { KeyStore.removePackKey(p.id) }
        state = .signedOut
        packs = []
        keyMissing = false
        store.resetSync()
    }

    /// Ein Universal Link: thisdog.app/anmelden/<Geheimnis> oder thisdog.app/rudel/<Geheimnis>.
    /// Gibt zurück, ob der Link der App gehörte.
    @discardableResult
    func open(_ url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.host() == "thisdog.app", parts.count == 2 else { return false }
        let secret = parts[1]
        let key = Sealing.key(fromFragment: url)
        switch parts[0] {
        case "anmelden":
            presentsPack = true
            Task { do { try await confirm(secret: secret) } catch { joinMessage = PackScreen.text(for: error) } }
        case "rudel":
            presentsPack = true
            pendingKey = key
            if isSignedIn {
                Task { await acceptInvite(secret) }
            } else {
                // Ohne Konto: eins anlegen, das löst die Einladung gleich mit ein (afterSignIn).
                pendingInvite = secret
                Task {
                    do {
                        try await ensureAccount()
                        // War schon ein Konto da (nur noch nicht geprüft), ist die Einladung noch offen.
                        if let invite = pendingInvite { await acceptInvite(invite) }
                    } catch { joinMessage = PackScreen.text(for: error) }
                }
            }
        case "freund":
            guard let key else { return true }
            Task {
                try? await ensureAccount()
                await friends.accept(secret: secret, key: key)
            }
        default:
            return false
        }
        return true
    }

    private func acceptInvite(_ secret: String) async {
        do {
            try await join(secret: secret)
            joinMessage = nil
            justJoined = true
        } catch {
            joinMessage = PackScreen.text(for: error)
        }
        pendingInvite = nil
    }

    private func afterSignIn() async {
        if let invite = pendingInvite { await acceptInvite(invite) }
        await loadPacks()
        // Alles, was vorher nur hier lag, geht beim ersten Abgleich ins Rudel – aber wie beim Beitreten: Profil und
        // Hundebild des Rudels gelten. Sonst überschriebe ein neues Gerät mit dem beim Einrichten Getippten alles.
        if let pack = store.packID, store.rev == 0 {
            store.joinPack(pack)
            let before = lastSync
            await syncNow()
            if lastSync != before, lastSyncComplete {
                store.claimUnanswered()
                await syncNow()
            }
        } else {
            store.markAllChanged()
            await syncNow()
        }
        PushRegistration.register()
    }

    // MARK: Rudel

    func loadPacks() async {
        guard let list: PackList = try? await api.get("pack.php", ["action": "list"]) else { return }
        packs = list.packs
        me = list.me
        publishDirectory()
        if store.packID == nil || !packs.contains(where: { $0.id == store.packID }) {
            store.switchPack(to: packs.first?.id)
        }
    }

    /// Der Einladungslink trägt den Rudel-Schlüssel hinter dem `#` – so kommt er beim neuen Mitglied an,
    /// ohne je beim Server zu liegen. Derselbe Link holt den Schlüssel auch auf ein weiteres eigenes Gerät.
    /// Ich bin Besitzer im aktuellen Rudel (ohne Rudel oder auf älteren Servern: ja).
    var isOwner: Bool { currentPack?.members.first { $0.id == me }?.isOwner ?? true }

    func setRole(_ role: String, of member: Int) async throws {
        struct Body: Encodable { let pack: Int; let member: Int; let role: String }
        guard let id = currentPack?.id else { return }
        let _: Ok = try await api.post("pack.php", ["action": "role"], body: Body(pack: id, member: member, role: role))
        await loadPacks()
    }

    /// `allowed` dürfen nur Besitzer setzen, `wanted` nur man selbst.
    func setNotify(of member: Int, allowed: [String]? = nil, wanted: [String]? = nil) async throws {
        struct Body: Encodable { let pack: Int; let member: Int; let allowed: [String]?; let wanted: [String]? }
        guard let id = currentPack?.id else { return }
        let _: Ok = try await api.post("pack.php", ["action": "notify"], body: Body(pack: id, member: member, allowed: allowed, wanted: wanted))
        await loadPacks()
    }

    func invite(role: String = "owner") async throws -> Invite {
        struct Body: Encodable { let pack: Int; let role: String }
        try await ensureAccount()
        if currentPack == nil { await loadPacks() }
        guard let id = currentPack?.id else { throw Api.Failure.notSignedIn }
        guard let key = await packKey(id) else { throw Api.Failure.server("key_missing") }
        let invite: Invite = try await api.post("pack.php", ["action": "invite"], body: Body(pack: id, role: role))
        await PushRegistration.askPermission()
        let url = URL(string: invite.url.absoluteString + "#k=" + Sealing.encode(key)) ?? invite.url
        // Gemerkt (ohne Schlüssel – der liegt im Schlüsselbund), damit der Link wieder da ist, solange er gilt.
        let saved = SavedInvite(pack: id, url: invite.url, role: role, expiresAt: invite.expiresAt)
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: SavedInvite.key)
        // Damit „Einladungslinks ungültig machen“ den neuen Link mitzählt.
        await loadPacks()
        return Invite(url: url, expiresAt: invite.expiresAt)
    }

    struct SavedInvite: Codable {
        static let key = "lastInvite"
        let pack: Int
        let url: URL
        let role: String
        let expiresAt: Double
    }

    /// Die letzte Einladung in dieses Rudel, wenn sie noch mindestens eine Stunde gilt – mit Schlüssel.
    func lastInvite() async -> (url: URL, role: String, expires: Date)? {
        guard let data = UserDefaults.standard.data(forKey: SavedInvite.key),
              let s = try? JSONDecoder().decode(SavedInvite.self, from: data),
              s.pack == currentPack?.id else { return nil }
        let expires = Date(timeIntervalSince1970: s.expiresAt / 1000)
        guard expires.timeIntervalSinceNow > 3600, let key = await packKey(s.pack),
              let url = URL(string: s.url.absoluteString + "#k=" + Sealing.encode(key)) else { return nil }
        return (url, s.role, expires)
    }

    func forgetInvite() { UserDefaults.standard.removeObject(forKey: SavedInvite.key) }

    /// Als Besitzer: alle noch gültigen Einladungslinks des Rudels ungültig machen. Der hier gemerkte gehört dazu.
    func revokeInvites() async throws {
        struct Body: Encodable { let pack: Int }
        struct Revoked: Decodable { let revoked: Int? }
        guard let id = currentPack?.id else { return }
        let _: Revoked = try await api.post("pack.php", ["action": "revoke_invites"], body: Body(pack: id))
        forgetInvite()
        await loadPacks()
    }

    /// Als Besitzer: ein anderes Mitglied aus dem Rudel nehmen. Es kommt sofort nicht mehr an die Daten des
    /// Rudels; was schon auf seinem Telefon liegt, bleibt dort.
    func remove(member: Int) async throws {
        struct Body: Encodable { let pack: Int; let member: Int }
        guard let id = currentPack?.id else { return }
        let _: Ok = try await api.post("pack.php", ["action": "remove"], body: Body(pack: id, member: member))
        await loadPacks()
    }

    /// Mit einem Einladungslink beitreten. Was das Rudel schon hat (Profil, Hundebild), gilt; Termine, Runden
    /// und Einträge von hier wandern mit.
    func join(secret: String) async throws {
        struct Body: Encodable { let invite: String }
        let r: JoinResult = try await api.post("pack.php", ["action": "join"], body: Body(invite: secret))
        // Ein Schlüssel, der hier schon die Daten öffnet, bleibt: Ein Link mit einem alten Schlüssel überschriebe ihn sonst
        // auf allen eigenen Geräten.
        if let key = pendingKey, KeyStore.packKey(r.pack) == nil || keyMissing { KeyStore.setPackKey(key, for: r.pack) }
        pendingKey = nil
        // Schon dabei (eigener Link, zweites Gerät): nichts verwerfen, nur abgleichen.
        if r.already, store.packID == r.pack { await syncNow(); return }
        store.joinPack(r.pack)
        await loadPacks()
        let before = lastSync
        await syncNow()
        // Erst wenn das Rudel geantwortet hat, ist klar, was es nicht hat – offline bleibt es beim Stand des Rudels.
        if lastSync != before, lastSyncComplete {
            store.claimUnanswered()
            await sync()
        }
        // Hundesitter bekommen erst Mitteilungen, wenn sie welche einschalten – dann wird auch erst gefragt.
        if isOwner { await PushRegistration.askPermission() }
    }

    func setName(_ name: String) async {
        struct Body: Encodable { let pack: Int; let name: String }
        guard let id = currentPack?.id else { return }
        let _: Ok? = try? await api.post("pack.php", ["action": "name"], body: Body(pack: id, name: name))
        await loadPacks()
    }

    func leave() async throws {
        struct Body: Encodable { let pack: Int }
        guard let id = currentPack?.id else { return }
        let _: Ok = try await api.post("pack.php", ["action": "leave"], body: Body(pack: id))
        KeyStore.removePackKey(id)
        store.switchPack(to: nil, keepLocal: false)
        await loadPacks()
        await sync()
    }

    /// Wer im Rudel einen Datensatz zuletzt geändert hat – mit Bild. `includeMe`: auch eigene Änderungen
    /// (dann gilt, was kein anderer geändert hat, als eigenes). Ohne Rudel mit anderen: `nil`.
    func author(of item: some SyncedItem, includeMe: Bool = false) -> (name: String, image: UIImage?)? {
        guard let pack = currentPack, pack.members.count > 1 else { return nil }
        let id = store.changer(of: item) ?? (includeMe ? me : nil)
        guard let id, let m = pack.members.first(where: { $0.id == id }) else { return nil }
        return (m.name, store.avatarImage(Avatar.member(id)))
    }

    /// Namen und Bilder der anderen im Rudel für die Mitteilungs-Erweiterung (bleibt auf dem Gerät).
    func publishDirectory() {
        let people = (currentPack?.members ?? []).filter { $0.id != me }
        var images: [Int: Data] = [:]
        for m in people {
            if let jpeg = store.avatars.first(where: { $0.id == Avatar.member(m.id) })?.jpeg, let data = Data(base64Encoded: jpeg) { images[m.id] = data }
        }
        PackDirectory.save(people: people.map { PackDirectory.Person(id: $0.id, name: $0.name) }, images: images)
    }

    func name(of accountID: Int?) -> String? {
        guard let accountID, accountID != me else { return nil }
        return currentPack?.members.first { $0.id == accountID }?.name
    }

    // MARK: Abgleich

    /// Nach einer Änderung kurz warten: Wer drei Felder ändert, löst einen Abgleich aus, nicht drei.
    func scheduleSync() {
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await sync() }
        }
    }

    /// Wartet einen laufenden Abgleich ab und gleicht dann selbst ab – für Beitreten, Anmelden und Verlassen,
    /// die sich auf das Ergebnis verlassen.
    func syncNow() async {
        while syncing { try? await Task.sleep(for: .milliseconds(100)) }
        await sync()
    }

    func sync() async {
        guard case .signedIn = state, let pack = store.packID else { return }
        // Läuft schon einer, kommt dieser gleich danach – sonst wartete eine Änderung bis zum nächsten Anlass.
        guard !syncing else { resyncRequested = true; return }
        syncing = true
        defer {
            syncing = false
            if resyncRequested { resyncRequested = false; Task { await sync() } }
        }
        guard let key = await packKey(pack), store.packID == pack else {
            if keyMissing { lastError = String(localized: "Auf diesem Gerät fehlt der Schlüssel des Rudels.") }
            return
        }
        let outgoing = store.outgoingRecords()
        do {
            let sealed = try outgoing.map { try Self.seal($0, pack: pack, key: key) }
            var r: SyncResponse = try await api.post("sync.php", ["action": "push", "pack": String(pack)],
                                                     body: PushBody(since: store.rev, records: sealed))
            var sent = outgoing
            var since = store.rev
            var failed = false
            while true {
                // Inzwischen beigetreten, verlassen oder gewechselt: Die Antwort gehört zu einem anderen Rudel.
                guard store.packID == pack else { return }
                let (opened, pageFailed) = Self.open(r.records, pack: pack, key: key)
                failed = failed || pageFailed
                // Ließ sich etwas nicht öffnen (anderer Schlüssel), bleibt die Revision stehen: Mit dem richtigen
                // Schlüssel kommt es beim nächsten Mal wieder.
                store.applyIncoming(opened, rev: failed ? store.rev : r.rev, sent: sent)
                sent = []
                // Eine volle Seite: Der Rest kommt seitenweise nach, erst danach ist der Abgleich vollständig.
                // Die Revision muss weiterkommen, sonst holte die Schleife dieselbe Seite immer wieder.
                guard r.more == true, r.rev > since else { break }
                since = r.rev
                r = try await api.post("sync.php", ["action": "push", "pack": String(pack)],
                                       body: PushBody(since: since, records: []))
            }
            lastSyncComplete = !failed
            lastSync = Date()
            lastError = failed ? String(localized: "Einige Daten im Rudel lassen sich mit dem Schlüssel dieses Geräts nicht öffnen.") : nil
            await refreshEmergencyIfNeeded()
            await friends.refreshCardsIfNeeded()
            publishDirectory()
        } catch Api.Failure.notSignedIn {
            state = .signedOut
        } catch Api.Failure.server("not_a_member") {
            // Das Rudel gibt es für dieses Konto nicht mehr (verlassen auf einem anderen Gerät).
            store.switchPack(to: nil, keepLocal: true)
            await loadPacks()
        } catch {
            // Auch mitten im Seitenholen: Was fehlt, kommt beim nächsten Mal – bis dahin ist nichts vollständig.
            lastSyncComplete = false
            lastError = String(localized: "Abgleich nicht möglich, die Änderungen bleiben auf dem Gerät.")
        }
    }

    private struct PushBody: Encodable { let since: Int; let records: [SyncRecord] }

    /// Der Wiederherstellungsschlüssel des aktuellen Rudels, falls dieses Gerät den Schlüssel hat.
    var recoveryCode: String? {
        currentPack.flatMap { KeyStore.packKey($0.id) }.map(RecoveryCode.encode)
    }

    /// Holt den Schlüssel mit dem Wiederherstellungsschlüssel zurück. Geprüft wird an den Daten des Rudels,
    /// bevor er gespeichert wird: Mit dem falschen Schlüssel ließe sich sonst nichts mehr abgleichen.
    func restore(code: String) async throws {
        guard let pack = currentPack?.id else { throw Api.Failure.server("key_missing") }
        guard let key = RecoveryCode.decode(code) else { throw RecoveryCode.Failure.invalid }
        let r: SyncResponse = try await api.post("sync.php", ["action": "push", "pack": String(pack)],
                                                 body: PushBody(since: 0, records: []))
        guard RecoveryCode.fits(key, records: r.records, pack: pack) else { throw RecoveryCode.Failure.wrongPack }
        KeyStore.setPackKey(key, for: pack)
        keyMissing = false
        lastError = nil
        await sync()
    }

    /// Der Schlüssel des Rudels – aus dem Schlüsselbund, sonst (einmalig) neu angelegt.
    ///
    /// Neu angelegt wird nur, solange das Rudel noch nicht verschlüsselt ist. Vorher holt das Gerät alles,
    /// was im Klartext auf dem Server liegt, damit beim Umzug nichts verloren geht, und fragt den Server,
    /// ob es das erste Gerät ist. Danach lädt es alles verschlüsselt hoch; den Klartext löscht der Server.
    func packKey(_ pack: Int) async -> SymmetricKey? {
        if let k = KeyStore.packKey(pack) { keyMissing = false; return k }
        if packs.first(where: { $0.id == pack })?.sealed == true { keyMissing = true; return nil }
        struct SealBody: Encodable { let pack: Int }
        struct Granted: Decodable { let granted: Bool }
        do {
            let r: SyncResponse = try await api.post("sync.php", ["action": "push", "pack": String(pack)],
                                                     body: PushBody(since: store.rev, records: []))
            let open = r.records.filter { !Sealing.isSealed($0.payload) }
            // Wurde Verschlüsseltes ausgelassen, bleibt die Revision stehen – sonst käme es mit dem Schlüssel nie mehr.
            store.applyIncoming(open, rev: open.count == r.records.count ? r.rev : store.rev, sent: [])
            let g: Granted = try await api.post("pack.php", ["action": "seal"], body: SealBody(pack: pack))
            guard g.granted else { keyMissing = true; return nil }
            let key = SymmetricKey(size: .bits256)
            KeyStore.setPackKey(key, for: pack)
            store.markAllChanged()
            keyMissing = false
            await loadPacks()
            return key
        } catch {
            return nil
        }
    }

    static func seal(_ r: SyncRecord, pack: Int, key: SymmetricKey) throws -> SyncRecord {
        guard let payload = r.payload else { return r }
        let sealed = try Sealing.seal(payload, key: key, context: Sealing.recordContext(pack: pack, kind: r.kind, id: r.id))
        return SyncRecord(kind: r.kind, id: r.id, updatedAt: r.updatedAt, by: r.by, payload: sealed)
    }

    /// Öffnet, was vom Server kommt. Grabsteine bleiben, wie sie sind; was sich nicht öffnen lässt, fällt heraus.
    static func open(_ records: [SyncRecord], pack: Int, key: SymmetricKey) -> ([SyncRecord], Bool) {
        var failed = false
        let out = records.compactMap { r -> SyncRecord? in
            guard let payload = r.payload else { return r }
            guard Sealing.isSealed(payload) else { return nil }  // Klartext gilt nicht mehr
            do {
                let plain = try Sealing.open(payload, key: key, context: Sealing.recordContext(pack: pack, kind: r.kind, id: r.id))
                return SyncRecord(kind: r.kind, id: r.id, updatedAt: r.updatedAt, by: r.by, payload: plain)
            } catch {
                failed = true
                return nil
            }
        }
        return (out, failed)
    }
}

/// Anmeldung für Mitteilungen. Die Kennung geht an den Server, damit er bei Änderungen im Rudel weckt.
@MainActor
enum PushRegistration {
    static func register() { UIApplication.shared.registerForRemoteNotifications() }

    /// Fragt einmal nach der Erlaubnis für Mitteilungen – sobald es ein Rudel mit anderen gibt (Einladen, Beitreten).
    /// Ohne sie meldet sich das Gerät zwar an, iOS zeigt die Mitteilungen aber nicht. Wurde schon gefragt, passiert nichts.
    static func askPermission() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func send(token: Data) async {
        struct Body: Encodable { let token: String; let environment: String }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let env = PushEnvironment.current
        let _: Ok? = try? await Api().post("push.php", ["action": "register"], body: Body(token: hex, environment: env))
    }
}

#if DEBUG
extension Account {
    /// Für Bildschirmfotos (`-rudeldemo`): ein Rudel mit Alex und Anna, ohne Server.
    func demoPack(annaPhoto: Data?) {
        let all = NotifyKind.allCases.map(\.rawValue)
        packs = [Pack(id: 1, members: [Member(id: 1, name: "Alex", joinedAt: 1_755_000_000, role: "owner", notifyAllowed: all, notifyWanted: all),
                                       Member(id: 2, name: "Anna", joinedAt: 1_756_000_000, role: "sitter", notifyAllowed: all, notifyWanted: ["notfall"])], sealed: true)]
        me = 1
        state = .signedIn(email: "alex@example.org")
        keyMissing = ProcessInfo.processInfo.arguments.contains("-keinschluessel")
        if let annaPhoto, let jpeg = Avatar.prepare(annaPhoto) {
            store.demoSetAvatar(Avatar(id: Avatar.member(2), jpeg: jpeg))
        }
        let walk = store.walks.sorted { $0.start > $1.start }.dropFirst().first
        let event = store.events.first { $0.title.hasPrefix(String(localized: "Tierarzt")) }
        let vac = store.vaccinations.first
        store.demoChangedBy(2, keys: [walk.map { "walk:\($0.id)" }, event.map { "event:\($0.id)" }, vac.map { "vaccinations:\($0.id)" }].compactMap { $0 })
    }
}
#endif
