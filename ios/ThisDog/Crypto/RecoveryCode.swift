import CryptoKit
import Foundation

/// Der Wiederherstellungsschlüssel: der Schlüssel des Rudels als Text, den man aufbewahren und abtippen kann.
///
/// Sind alle Geräte weg, ist er der einzige Weg zurück zu den Daten; der Server kennt ihn nicht.
/// Crockford-Base32 kennt keine leicht verwechselbaren Zeichen (kein I, L, O, U), zwei Prüfbytes fangen
/// Tippfehler ab, bevor etwas beim Server ankommt. Das Format hängt nicht an Apple und taugt auch für Android.
enum RecoveryCode {
    enum Failure: Error, Equatable {
        /// Tippfehler: falsche Länge, falsche Zeichen oder falsche Prüfsumme.
        case invalid
        /// Richtig geschrieben, öffnet aber die Daten dieses Rudels nicht.
        case wrongPack
    }

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let checkBytes = 2
    /// 34 Bytes (32 Schlüssel, 2 Prüfung) sind 272 Bit, also 55 Zeichen zu je 5 Bit.
    private static let length = 55

    static func encode(_ key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        let bytes = raw + check(raw)
        var chars: [Character] = []
        var buffer = 0, bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { chars.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return stride(from: 0, to: chars.count, by: 5)
            .map { String(chars[$0..<min($0 + 5, chars.count)]) }
            .joined(separator: "-")
    }

    /// Großschreibung, Leerzeichen und Bindestriche sind egal; O gilt als 0, I und L als 1.
    static func decode(_ text: String) -> SymmetricKey? {
        let clean = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }.map { c -> Character in
            switch c {
            case "O": "0"
            case "I", "L": "1"
            default: c
            }
        }
        guard clean.count == length else { return nil }
        var out = Data()
        var buffer = 0, bits = 0
        for c in clean {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 255))
            }
            buffer &= (1 << bits) - 1
        }
        // Die letzte Stelle hat drei ungenutzte Bits. Sie müssen null sein, sonst bliebe ein Tippfehler dort unbemerkt.
        guard out.count == 32 + checkBytes, buffer == 0 else { return nil }
        let raw = out.prefix(32)
        guard Data(out.suffix(checkBytes)) == check(Data(raw)) else { return nil }
        return SymmetricKey(data: raw)
    }

    private static func check(_ raw: Data) -> Data {
        Data(SHA256.hash(data: Data("thisdog/recovery".utf8) + raw).prefix(checkBytes))
    }

    /// Passt der Schlüssel zu den Daten des Rudels? Ja, wenn er etwas öffnet oder noch nichts verschlüsselt ist.
    static func fits(_ key: SymmetricKey, records: [SyncRecord], pack: Int) -> Bool {
        let sealed = records.filter { Sealing.isSealed($0.payload) }
        guard !sealed.isEmpty else { return true }
        return sealed.contains { r in
            guard let payload = r.payload else { return false }
            return (try? Sealing.open(payload, key: key, context: Sealing.recordContext(pack: pack, kind: r.kind, id: r.id))) != nil
        }
    }
}
