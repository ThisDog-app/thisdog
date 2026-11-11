import Foundation
import MultipeerConnectivity
import Observation
import UIKit

/// Ein `MCPeerID` ändert sich nach dem Anlegen nicht mehr.
extension MCPeerID: @retroactive @unchecked Sendable {}

/// „Hund in der Nähe“: Zwei Telefone finden sich direkt, ohne Server und ohne Standort.
///
/// Gesucht wird nur, solange die Ansicht offen ist, und nur der Hundename ist dabei für andere sichtbar.
/// Erst wenn eine Seite anfragt und die andere annimmt, entsteht eine verschlüsselte Verbindung. Darüber
/// geht der Einladungslink samt Freundschaftsschlüssel, ohne dass der Server den Schlüssel je sieht.
@MainActor
@Observable
final class NearbyShare: NSObject {
    struct Peer: Identifiable, Equatable {
        let id: MCPeerID
        let name: String
    }

    struct Request: Identifiable {
        let id = UUID()
        let peer: MCPeerID
        let name: String
        let photo: UIImage?
        let reply: (Bool, MCSession?) -> Void
    }

    enum Phase: Equatable {
        case searching
        case connecting(String)
        case friends(String)
        case failed(String)
    }

    private(set) var peers: [Peer] = []
    private(set) var request: Request?
    private(set) var phase: Phase = .searching

    /// Erstellt den Link, den die andere Seite bekommt.
    @ObservationIgnored var makeLink: (() async throws -> URL)?
    /// Nimmt einen Link der anderen Seite an.
    @ObservationIgnored var acceptLink: ((URL) -> Void)?

    static let service = "thisdog-hund"

    @ObservationIgnored private let me = MCPeerID(displayName: UUID().uuidString.prefix(8).description)
    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var dogName = ""
    @ObservationIgnored private var thumbnail: Data?
    @ObservationIgnored private var isInviter = false
    @ObservationIgnored private var otherName = ""

    func start(dogName: String, photo: UIImage?) {
        self.dogName = dogName
        thumbnail = photo.flatMap(Self.thumbnail)
        phase = .searching
        peers = []
        let session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        let advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["hund": String(dogName.prefix(40))], serviceType: Self.service)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        let browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.service)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        peers = []
        request = nil
    }

    /// Diese Seite fragt an: Name und kleines Bild gehen mit, damit die andere weiß, wer fragt.
    func ask(_ peer: Peer) {
        guard let session, let browser else { return }
        isInviter = true
        otherName = peer.name
        phase = .connecting(peer.name)
        let hello = Hello(name: dogName, photo: thumbnail)
        browser.invitePeer(peer.id, to: session, withContext: try? JSONEncoder().encode(hello), timeout: 30)
    }

    func answer(_ yes: Bool) {
        guard let request else { return }
        if yes {
            isInviter = false
            otherName = request.name
            phase = .connecting(request.name)
        }
        request.reply(yes, yes ? session : nil)
        self.request = nil
    }

    private struct Hello: Codable { let name: String; let photo: Data? }

    private static func thumbnail(_ image: UIImage) -> Data? {
        let size = CGSize(width: 96, height: 96)
        return UIGraphicsImageRenderer(size: size, format: .photo).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.6)
    }

    private func connected(_ peer: MCPeerID) {
        // Die anfragende Seite schickt den Link. So entsteht genau eine Einladung.
        guard isInviter else { return }
        Task {
            do {
                guard let makeLink else { return }
                let url = try await makeLink()
                try session?.send(Data(url.absoluteString.utf8), toPeers: [peer], with: .reliable)
                phase = .friends(otherName)
            } catch {
                phase = .failed(String(localized: "Das hat nicht geklappt. Zeig stattdessen den QR-Code."))
            }
        }
    }

    private func received(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), let url = URL(string: text) else {
            phase = .failed(String(localized: "Das hat nicht geklappt. Zeig stattdessen den QR-Code."))
            return
        }
        acceptLink?(url)
        phase = .friends(otherName)
    }

    private func lost(_ peer: MCPeerID) {
        if case .connecting = phase { phase = .failed(String(localized: "Die Verbindung ist abgerissen. Versucht es noch einmal oder nehmt den QR-Code.")) }
    }
}

extension NearbyShare: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let name = info?["hund"] ?? String(localized: "Ein Hund")
        Task { @MainActor in
            if !self.peers.contains(where: { $0.id == peerID }) { self.peers.append(Peer(id: peerID, name: name)) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.peers.removeAll { $0.id == peerID } }
    }
}

extension NearbyShare: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let hello = context.flatMap { try? JSONDecoder().decode(Hello.self, from: $0) }
        let name = hello?.name ?? String(localized: "Ein Hund")
        let photo = hello?.photo
        nonisolated(unsafe) let reply = invitationHandler
        Task { @MainActor in
            self.request = Request(peer: peerID, name: name, photo: photo.flatMap(UIImage.init(data:)), reply: reply)
        }
    }
}

extension NearbyShare: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected: self.connected(peerID)
            case .notConnected: self.lost(peerID)
            default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.received(data) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
