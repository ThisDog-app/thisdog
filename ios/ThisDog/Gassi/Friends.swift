import CoreLocation
import CryptoKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Hundefreunde: Rudel, die sich während einer Runde auf der Karte sehen.
///
/// Alles, was zum Freund geht, ist mit dem Schlüssel dieser Freundschaft verschlüsselt (Steckbrief, Standort);
/// der Server reicht nur Pakete weiter. Den Standort gibt es nur, solange eine Runde läuft – mit dem Beenden
/// ist er weg. Ob ein Freund in der Nähe losgeht, rechnet dieses Gerät aus, nachdem der Server es still geweckt hat.
@MainActor
@Observable
final class Friends {
    struct Friend: Identifiable, Equatable {
        let pack: Int
        let invite: String
        var name: String
        var photo: UIImage?
        var id: Int { pack }
    }

    struct Spot: Identifiable, Equatable {
        let pack: Int
        let coordinate: CLLocationCoordinate2D
        let updatedAt: Date
        var id: Int { pack }
        static func == (a: Spot, b: Spot) -> Bool { a.pack == b.pack && a.updatedAt == b.updatedAt }
    }

    /// Ein Freund hat eingecheckt (die letzten drei Stunden).
    struct Visit: Identifiable, Equatable {
        let pack: Int
        let place: String
        let coordinate: CLLocationCoordinate2D
        let at: Date
        var id: Int { pack }
        static func == (a: Visit, b: Visit) -> Bool { a.pack == b.pack && a.at == b.at }
    }

    private struct Card: Codable { let name: String; let photo: String? }
    private struct CheckInBlob: Codable { let name: String; let lat: Double; let lng: Double; let at: Double }
    private struct Position: Codable { let lat: Double; let lng: Double }

    fileprivate(set) var list: [Friend] = []
    fileprivate(set) var live: [Spot] = []
    fileprivate(set) var visits: [Visit] = []
    private(set) var message: String?

    /// Wie weit „in der Nähe“ ist.
    static let nearbyMeters: Double = 1500
    /// So oft geht unterwegs ein neuer Punkt an die Freunde.
    static let interval: TimeInterval = 20

    @ObservationIgnored private unowned let account: Account
    @ObservationIgnored private var lastSent: Date?
    @ObservationIgnored private var walkStarted: Int?

    init(account: Account) { self.account = account }

    private var api: Api { account.api }
    private var store: DogStore { account.store }
    private var myPack: Int? { store.packID }
    private var signedIn: Bool { if case .signedIn = account.state { true } else { false } }

    private func key(for f: Friend) -> SymmetricKey? { store.friendKey(invite: f.invite)?.symmetric }

    // MARK: Freunde

    func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-freunde") { return }
        #endif
        guard signedIn, let me = myPack else { return }
        struct Item: Decodable { let pack: Int; let invite: String; let card: String? }
        struct Answer: Decodable { let friends: [Item] }
        guard let a: Answer = try? await api.get("friends.php", ["action": "list", "pack": String(me)]) else { return }
        list = a.friends.map { item in
            var f = Friend(pack: item.pack, invite: item.invite, name: "Hund", photo: nil)
            if let k = store.friendKey(invite: item.invite)?.symmetric, let blob = item.card,
               let card = try? Sealing.openBlob(blob, as: Card.self, key: k, context: Sealing.friendContext("card", from: item.pack, to: me)) {
                f.name = card.name.isEmpty ? String(localized: "Hund") : card.name
                f.photo = card.photo.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
            }
            return f
        }
        await refreshCardsIfNeeded()
    }

    /// Ein Link zum Teilen: thisdog.app/freund/<Geheimnis>#k=<Schlüssel der Freundschaft>.
    func invite() async throws -> URL {
        guard let me = myPack else { throw Api.Failure.notSignedIn }
        struct Body: Encodable { let pack: Int }
        struct Answer: Decodable { let url: URL; let invite: String }
        let a: Answer = try await api.post("friends.php", ["action": "invite"], body: Body(pack: me))
        let key = SymmetricKey(size: .bits256)
        store.saveFriendKey(invite: a.invite, key: key)
        await account.sync()
        await PushRegistration.askPermission()
        return URL(string: a.url.absoluteString + "#k=" + Sealing.encode(key)) ?? a.url
    }

    func accept(secret: String, key: SymmetricKey) async {
        guard signedIn, let me = myPack else {
            message = String(localized: "Melde dich im Rudel an, dann öffne den Link noch einmal.")
            account.presentsPack = true
            return
        }
        struct Body: Encodable { let pack: Int; let invite: String }
        struct Answer: Decodable { let friend: Int; let invite: String }
        do {
            let a: Answer = try await api.post("friends.php", ["action": "accept"], body: Body(pack: me, invite: secret))
            store.saveFriendKey(invite: a.invite, key: key)
            await account.sync()
            UserDefaults.standard.removeObject(forKey: cardStampKey)
            await load()
            message = nil
            await PushRegistration.askPermission()
        } catch Api.Failure.server(let code) {
            message = switch code {
            case "invite_used": String(localized: "Diese Einladung wurde schon benutzt. Bitte um eine neue.")
            case "invite_expired": String(localized: "Diese Einladung ist abgelaufen. Bitte um eine neue.")
            case "own_pack": String(localized: "Das ist eine Einladung von deinem eigenen Hund.")
            default: String(localized: "Diese Einladung gibt es nicht.")
            }
        } catch {
            message = String(localized: "Keine Verbindung. Öffne den Link gleich noch einmal.")
        }
    }

    func remove(_ f: Friend) async {
        guard let me = myPack else { return }
        struct Body: Encodable { let pack: Int; let friend: Int }
        let _: Ok? = try? await api.post("friends.php", ["action": "remove"], body: Body(pack: me, friend: f.pack))
        store.removeFriendKey(invite: f.invite)
        list.removeAll { $0.pack == f.pack }
        live.removeAll { $0.pack == f.pack }
    }

    // MARK: Steckbrief

    private var cardStampKey: String { "freunde.steckbrief.\(myPack ?? 0)" }

    /// Name und Foto des eigenen Hundes gehen verschlüsselt an jeden Freund – neu, wenn sich etwas geändert hat.
    func refreshCardsIfNeeded() async {
        guard signedIn, let me = myPack, !list.isEmpty else { return }
        let photo = store.avatars.first { $0.id == Avatar.dog }?.jpeg
        let card = Card(name: store.profile.name, photo: photo)
        let stamp = "\(card.name)|\(photo?.count ?? 0)|\(photo?.suffix(24) ?? "")|\(list.map(\.pack).sorted())"
        guard UserDefaults.standard.string(forKey: cardStampKey) != stamp else { return }
        struct Blob: Encodable { let friend: Int; let blob: String }
        struct Body: Encodable { let pack: Int; let blobs: [Blob] }
        let blobs = list.compactMap { f -> Blob? in
            guard let k = key(for: f), let b = try? Sealing.sealBlob(card, key: k, context: Sealing.friendContext("card", from: me, to: f.pack)) else { return nil }
            return Blob(friend: f.pack, blob: b)
        }
        guard !blobs.isEmpty else { return }
        if (try? await api.post("friends.php", ["action": "cards"], body: Body(pack: me, blobs: blobs)) as Ok) != nil {
            UserDefaults.standard.set(stamp, forKey: cardStampKey)
        }
    }

    // MARK: Unterwegs

    /// Ein Punkt der eigenen Runde – höchstens alle 20 Sekunden an die Freunde.
    func walked(to here: CLLocationCoordinate2D, startedAt: Date) {
        LastPlace.save(here)
        guard signedIn, let me = myPack, !list.isEmpty else { return }
        if let lastSent, Date().timeIntervalSince(lastSent) < Self.interval { return }
        lastSent = Date()
        let started = Int(startedAt.timeIntervalSince1970)
        walkStarted = started
        struct Blob: Encodable { let friend: Int; let blob: String }
        struct Body: Encodable { let pack: Int; let started: Int; let blobs: [Blob] }
        let pos = Position(lat: here.latitude, lng: here.longitude)
        let blobs = list.compactMap { f -> Blob? in
            guard let k = key(for: f), let b = try? Sealing.sealBlob(pos, key: k, context: Sealing.friendContext("pos", from: me, to: f.pack)) else { return nil }
            return Blob(friend: f.pack, blob: b)
        }
        Task { let _: Ok? = try? await api.post("friends.php", ["action": "position"], body: Body(pack: me, started: started, blobs: blobs)) }
    }

    /// Die Runde ist vorbei: Der Standort verschwindet sofort vom Server.
    func walkEnded() {
        lastSent = nil
        guard walkStarted != nil, let me = myPack else { return }
        walkStarted = nil
        struct Body: Encodable { let pack: Int }
        Task { let _: Ok? = try? await api.post("friends.php", ["action": "stop"], body: Body(pack: me)) }
    }

    /// Wo Freunde gerade unterwegs sind.
    func refreshLive() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-freunde") { return }
        #endif
        guard signedIn, let me = myPack, !list.isEmpty else { live = []; return }
        struct Item: Decodable { let pack: Int; let blob: String; let updatedAt: Int }
        struct Answer: Decodable { let live: [Item] }
        guard let a: Answer = try? await api.get("friends.php", ["action": "live", "pack": String(me)]) else { return }
        live = a.live.compactMap { item in
            guard let f = list.first(where: { $0.pack == item.pack }), let k = key(for: f),
                  let p = try? Sealing.openBlob(item.blob, as: Position.self, key: k, context: Sealing.friendContext("pos", from: item.pack, to: me))
            else { return nil }
            return Spot(pack: item.pack, coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng),
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(item.updatedAt)))
        }
    }

    // MARK: Check-ins

    /// Ein Check-in geht verschlüsselt an jeden Freund; der Server löscht ihn nach drei Stunden.
    func checkedIn(_ c: CheckIn) {
        guard signedIn, let me = myPack, !list.isEmpty else { return }
        struct Blob: Encodable { let friend: Int; let blob: String }
        struct Body: Encodable { let pack: Int; let blobs: [Blob] }
        let v = CheckInBlob(name: c.name, lat: c.lat, lng: c.lon, at: c.at)
        let blobs = list.compactMap { f -> Blob? in
            guard let k = key(for: f), let b = try? Sealing.sealBlob(v, key: k, context: Sealing.friendContext("checkin", from: me, to: f.pack)) else { return nil }
            return Blob(friend: f.pack, blob: b)
        }
        Task { let _: Ok? = try? await api.post("friends.php", ["action": "checkin"], body: Body(pack: me, blobs: blobs)) }
    }

    /// Wo Freunde in den letzten drei Stunden eingecheckt haben.
    func refreshVisits() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-freunde") { return }
        #endif
        guard signedIn, let me = myPack, !list.isEmpty else { visits = []; return }
        struct Item: Decodable { let pack: Int; let blob: String }
        struct Answer: Decodable { let checkins: [Item] }
        guard let a: Answer = try? await api.get("friends.php", ["action": "checkins", "pack": String(me)]) else { return }
        visits = a.checkins.compactMap { item in
            guard let f = list.first(where: { $0.pack == item.pack }), let k = key(for: f),
                  let v = try? Sealing.openBlob(item.blob, as: CheckInBlob.self, key: k, context: Sealing.friendContext("checkin", from: item.pack, to: me))
            else { return nil }
            return Visit(pack: item.pack, place: v.name, coordinate: CLLocationCoordinate2D(latitude: v.lat, longitude: v.lng), at: Date(timeIntervalSince1970: v.at / 1000))
        }
    }

    /// Freunde, die an diesem Ort eingecheckt haben.
    func visits(at p: Place) -> [Visit] {
        visits.filter { $0.place == p.name || Track.distance($0.coordinate, p.coordinate) < 150 }
    }

    // MARK: In der Nähe

    /// Der Server weckt still, wenn ein Freund losgeht. Ist er nah, zeigt dieses Gerät eine Mitteilung.
    func handleWake(_ info: [AnyHashable: Any]) async {
        guard let friendPack = (info["friend"] as? NSNumber)?.intValue, let blob = info["e"] as? String, let me = myPack else { return }
        if list.isEmpty { await load() }
        guard let f = list.first(where: { $0.pack == friendPack }), let k = key(for: f),
              let p = try? Sealing.openBlob(blob, as: Position.self, key: k, context: Sealing.friendContext("pos", from: friendPack, to: me)),
              let here = LastPlace.load() else { return }
        let meters = CLLocation(latitude: p.lat, longitude: p.lng).distance(from: CLLocation(latitude: here.latitude, longitude: here.longitude))
        guard meters <= Self.nearbyMeters else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(f.name) ist unterwegs")
        content.body = String(localized: "Ganz in eurer Nähe, etwa \(WalkText.distance(meters)). Bei Gassi siehst du, wo.")
        content.sound = .default
        content.userInfo = ["friendNearby": friendPack]
        // Wie eine Nachricht von einer Person: mit dem Foto des befreundeten Hundes.
        let shown = await PersonNotification.content(content, from: f.name, image: f.photo?.jpegData(compressionQuality: 0.8),
                                                     id: "freund-\(friendPack)", conversation: "freund-\(friendPack)")
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "freund-\(friendPack)-\(info["started"] ?? 0)", content: shown, trigger: nil))
    }
}

#if DEBUG
extension Friends {
    /// Für Bildschirmfotos (`-freunde`): zwei erfundene Hunde, einer gerade unterwegs in der Nähe.
    func seedDemo(near here: CLLocationCoordinate2D) {
        list = [Friend(pack: 9001, invite: "demo-1", name: "Bello", photo: nil),
                Friend(pack: 9002, invite: "demo-2", name: "Luna", photo: nil)]
        live = [Spot(pack: 9001, coordinate: CLLocationCoordinate2D(latitude: here.latitude + 0.0021, longitude: here.longitude + 0.0017), updatedAt: Date())]
    }
}
#endif

/// Wo dieses Gerät zuletzt war (nur hier gespeichert) – Bezug für „in der Nähe“, wenn gerade keine Runde läuft.
enum LastPlace {
    private static let key = "letzter.ort"

    static func save(_ c: CLLocationCoordinate2D) {
        UserDefaults.standard.set([c.latitude, c.longitude, Date().timeIntervalSince1970], forKey: key)
    }

    static func load() -> CLLocationCoordinate2D? {
        guard let a = UserDefaults.standard.array(forKey: key) as? [Double], a.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: a[0], longitude: a[1])
    }
}
