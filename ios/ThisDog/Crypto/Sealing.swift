import CryptoKit
import Foundation
import Security

/// Ende-zu-Ende-Verschlüsselung: Der Server bekommt jeden Datensatz nur verschlüsselt und hat keinen Schlüssel.
///
/// Jedes Rudel hat einen eigenen Schlüssel (AES-GCM, 256 Bit). Er liegt im Schlüsselbund und wird über iCloud
/// zwischen den eigenen Geräten abgeglichen; neue Mitglieder bekommen ihn über den Einladungslink – im Teil
/// hinter dem `#`, den weder Browser noch App an den Server schicken.
///
/// Zusätzlich ist jeder Datensatz an seinen Platz gebunden (Rudel, Art, Kennung als „additional authenticated
/// data“): Wer auf dem Server einen verschlüsselten Datensatz umkopiert oder vertauscht, macht ihn unlesbar.
enum Sealing {
    enum Failure: Error, Equatable { case notSealed, cannotOpen }

    /// Ein Datensatz auf dem Server: `{"e": "<Base64 aus Nonce, Geheimtext, Prüfsumme>"}`.
    static func seal(_ value: JSONValue, key: SymmetricKey, context: String) throws -> JSONValue {
        let plain = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(plain, using: key, authenticating: Data(context.utf8))
        return .object(["e": .string(box.combined!.base64EncodedString())])
    }

    static func open(_ sealed: JSONValue, key: SymmetricKey, context: String) throws -> JSONValue {
        guard case .object(let o) = sealed, case .string(let b64)? = o["e"], let data = Data(base64Encoded: b64) else {
            throw Failure.notSealed
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
            return try JSONDecoder().decode(JSONValue.self, from: plain)
        } catch {
            throw Failure.cannotOpen
        }
    }

    /// Für Pakete an Freunde: ein Codable-Wert verschlüsselt als Base64 (ohne Hülle).
    static func sealBlob(_ value: some Encodable, key: SymmetricKey, context: String) throws -> String {
        try AES.GCM.seal(JSONEncoder().encode(value), using: key, authenticating: Data(context.utf8)).combined!.base64EncodedString()
    }

    static func openBlob<T: Decodable>(_ blob: String, as type: T.Type, key: SymmetricKey, context: String) throws -> T {
        guard let data = Data(base64Encoded: blob) else { throw Failure.notSealed }
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
            return try JSONDecoder().decode(T.self, from: plain)
        } catch { throw Failure.cannotOpen }
    }

    static func friendContext(_ what: String, from: Int, to: Int) -> String { "thisdog/friend/\(what)/\(from)/\(to)" }

    static func isSealed(_ value: JSONValue?) -> Bool {
        if case .object(let o)? = value, o.count == 1, case .string? = o["e"] { return true }
        return false
    }

    /// Bindet einen Datensatz an Rudel, Art und Kennung.
    static func recordContext(pack: Int, kind: String, id: String) -> String { "thisdog/record/\(pack)/\(kind)/\(id)" }

    // MARK: Schlüssel als Text (für den Einladungslink)

    static func encode(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> SymmetricKey? {
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// `#k=<Schlüssel>` aus einem Link.
    static func key(fromFragment url: URL) -> SymmetricKey? {
        guard let fragment = url.fragment(percentEncoded: false) else { return nil }
        for part in fragment.split(separator: "&") where part.hasPrefix("k=") {
            return decode(String(part.dropFirst(2)))
        }
        return nil
    }
}

/// Die Rudel-Schlüssel im Schlüsselbund – über iCloud auf allen eigenen Geräten, lesbar auch im Hintergrund
/// (für Mitteilungen bei gesperrtem Bildschirm), aber erst nach dem ersten Entsperren seit dem Start.
enum KeyStore {
    static let service = "app.thisDog.rudel"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanTrue!]
    }

    static func packKey(_ pack: Int) -> SymmetricKey? {
        var q = query("pack-\(pack)")
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func setPackKey(_ key: SymmetricKey, for pack: Int) {
        let data = key.withUnsafeBytes { Data($0) }
        let q = query("pack-\(pack)")
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = String(localized: "ThisDog: Schlüssel für Rudel \(pack)")
        SecItemAdd(add as CFDictionary, nil)
    }

    static func removePackKey(_ pack: Int) {
        SecItemDelete(query("pack-\(pack)") as CFDictionary)
    }
}
