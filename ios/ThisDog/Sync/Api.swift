import Foundation

/// Die Schnittstelle unter thisdog.app/api. Angemeldet wird über das Sitzungs-Cookie, das
/// `URLSession` selbst aufbewahrt – auch über einen Neustart der App hinweg.
struct Api: Sendable {
    static let base = URL(string: "https://thisdog.app/api/")!

    enum Failure: Error, Equatable {
        case notSignedIn
        case server(String)
        case offline
    }

    var session: URLSession = .shared

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        try await send(path, query: query, method: "GET", body: nil)
    }

    func post<T: Decodable>(_ path: String, _ query: [String: String] = [:], body: some Encodable) async throws -> T {
        try await send(path, query: query, method: "POST", body: try JSONEncoder().encode(body))
    }

    /// Ein Bild mit weiteren Feldern als multipart/form-data (Fotos von Orten).
    func upload<T: Decodable>(_ path: String, _ query: [String: String] = [:], fields: [String: String], file: String, jpeg: Data) async throws -> T {
        let boundary = "thisdog-" + UUID().uuidString
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields {
            add(String(localized: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"))
        }
        add(String(localized: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file)\"; filename=\"foto.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        body.append(jpeg)
        add("\r\n--\(boundary)--\r\n")
        return try await send(path, query: query, method: "POST", body: body, contentType: String(localized: "multipart/form-data; boundary=\(boundary)"), timeout: 60)
    }

    private func send<T: Decodable>(_ path: String, query: [String: String], method: String, body: Data?,
                                    contentType: String = "application/json", timeout: TimeInterval = 20) async throws -> T {
        var url = Self.base.appending(path: path)
        url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.httpBody = body
        if body != nil { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Failure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.notSignedIn }
        guard (200..<300).contains(status) else {
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "status_\(status)"
            throw Failure.server(code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct ErrorBody: Decodable { let error: String }
}

// MARK: Antworten

struct Me: Decodable { let signedIn: Bool; let email: String? }
struct Ok: Decodable { let ok: Bool? }

struct PackList: Decodable {
    let me: Int
    let packs: [Pack]
}

struct Pack: Decodable, Identifiable, Hashable {
    let id: Int
    let members: [Member]
    /// Das Rudel ist Ende-zu-Ende verschlüsselt (der Server nimmt nur noch Verschlüsseltes an).
    var sealed: Bool? = nil
    /// Wie viele Einladungslinks noch gelten (nur für Besitzer von Belang). Ältere Server: `nil`.
    var openInvites: Int? = nil
}

struct Member: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let joinedAt: Int
    /// „owner“ (Besitzer) oder „sitter“ (Hundesitter). Ältere Server kennen keine Rollen: dann Besitzer.
    var role: String? = nil
    /// Welche Mitteilungen dieses Mitglied bekommen darf (Besitzer legen es fest) und will (es selbst).
    var notifyAllowed: [String]? = nil
    var notifyWanted: [String]? = nil

    var isOwner: Bool { role != "sitter" }
    var roleLabel: String { isOwner ? String(localized: "Besitzer") : String(localized: "Hundesitter") }
    /// Was es tatsächlich bekommt: erlaubt und gewollt.
    var notifies: [NotifyKind] { NotifyKind.allCases.filter { (notifyAllowed ?? []).contains($0.rawValue) && (notifyWanted ?? []).contains($0.rawValue) } }
}

/// Wofür es sichtbare Mitteilungen gibt (wie NOTIFY_KINDS auf dem Server).
enum NotifyKind: String, CaseIterable, Identifiable {
    case termine, gesundheit, tagebuch, notfall
    var id: String { rawValue }
    var title: String {
        switch self {
        case .termine: String(localized: "Termine")
        case .gesundheit: String(localized: "Gesundheit")
        case .tagebuch: String(localized: "Tagebuch")
        case .notfall: String(localized: "Notfall")
        }
    }
    var detail: String {
        switch self {
        case .termine: String(localized: "Ein Termin wird eingetragen, geändert oder gelöscht.")
        case .gesundheit: String(localized: "Impfung, Entwurmung, Medikament oder Gewicht.")
        case .tagebuch: String(localized: "Ein neuer Eintrag im Gesundheitstagebuch.")
        case .notfall: String(localized: "Jemand öffnet den Notfallpass, oder der Hund ist entlaufen.")
        }
    }
}

struct Invite: Decodable { let url: URL; let expiresAt: Double }
struct JoinResult: Decodable { let pack: Int; let already: Bool }

/// Ein Datensatz im Abgleich – dasselbe Format wie in der Web-App.
struct SyncRecord: Codable, Sendable {
    let kind: String
    let id: String
    let updatedAt: Double
    var by: Int? = nil
    let payload: JSONValue?
}

struct SyncResponse: Decodable {
    let pack: Int?
    let rev: Int
    let records: [SyncRecord]
    /// Die Seite war voll (5000 Datensätze): Mit `since = rev` kommt der Rest. Ältere Server: `nil`.
    var more: Bool? = nil
}

/// Beliebiges JSON, damit Datensätze unverändert durchgereicht werden können.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// Wandelt einen Codable-Wert in JSON und zurück.
    static func from(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}
