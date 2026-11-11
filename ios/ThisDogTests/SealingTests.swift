import CryptoKit
import CoreImage
import Foundation
import UIKit
import Testing
@testable import ThisDog

@Suite("Ende-zu-Ende-Verschlüsselung")
struct SealingTests {
    let value: JSONValue = .object(["title": .string("Tierarzt"), "start": .string("2026-10-20")])

    @Test("Verschlüsselt und wieder geöffnet ist es derselbe Datensatz; der Klartext steht nirgends im Geheimtext")
    func roundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try Sealing.seal(value, key: key, context: "a")
        #expect(Sealing.isSealed(sealed))
        let text = String(data: try JSONEncoder().encode(sealed), encoding: .utf8)!
        #expect(!text.contains("Tierarzt"))
        #expect(try Sealing.open(sealed, key: key, context: "a") == value)
    }

    @Test("Mit fremdem Schlüssel, an anderem Platz oder verändert lässt sich nichts öffnen")
    func tamper() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try Sealing.seal(value, key: key, context: "thisdog/record/1/event/a")
        #expect(throws: Sealing.Failure.cannotOpen) { try Sealing.open(sealed, key: SymmetricKey(size: .bits256), context: "thisdog/record/1/event/a") }
        #expect(throws: Sealing.Failure.cannotOpen) { try Sealing.open(sealed, key: key, context: "thisdog/record/1/event/b") }
        guard case .object(let o) = sealed, case .string(let b64)? = o["e"] else { Issue.record(); return }
        var bytes = Data(base64Encoded: b64)!
        bytes[bytes.count / 2] ^= 0x01
        let broken: JSONValue = .object(["e": .string(bytes.base64EncodedString())])
        #expect(throws: Sealing.Failure.cannotOpen) { try Sealing.open(broken, key: key, context: "thisdog/record/1/event/a") }
        #expect(throws: Sealing.Failure.notSealed) { try Sealing.open(value, key: key, context: "x") }
    }

    @Test("Der Schlüssel übersteht den Weg durch den Link (#k=…)")
    func keyInLink() throws {
        let key = SymmetricKey(size: .bits256)
        let url = URL(string: "https://thisdog.app/rudel/abc#k=\(Sealing.encode(key))")!
        let back = try #require(Sealing.key(fromFragment: url))
        #expect(back.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
        #expect(Sealing.key(fromFragment: URL(string: "https://thisdog.app/rudel/abc")!) == nil)
        #expect(Sealing.key(fromFragment: URL(string: "https://thisdog.app/rudel/abc#k=kurz")!) == nil)
    }
}

@Suite("Wiederherstellungsschlüssel")
struct RecoveryCodeTests {
    private func bytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    @Test("Der Schlüssel übersteht den Weg als Text, egal wie er getippt ist")
    func roundTrip() throws {
        for _ in 0..<50 {
            let key = SymmetricKey(size: .bits256)
            let code = RecoveryCode.encode(key)
            #expect(try bytes(#require(RecoveryCode.decode(code))) == bytes(key))
            let sloppy = code.lowercased().replacingOccurrences(of: "-", with: " ")
            #expect(try bytes(#require(RecoveryCode.decode(sloppy))) == bytes(key))
        }
    }

    @Test("Das Format ist auf iPhone und Android dasselbe")
    func sameOnAndroid() throws {
        let key = SymmetricKey(data: Data(0..<32))
        let code = "000G4-0R40M-30E20-9185G-R38E1-W8124-GK2GA-HC5RR-34D1P-70X3R-FSCSG"
        #expect(RecoveryCode.encode(key) == code)
        #expect(try bytes(#require(RecoveryCode.decode(code))) == bytes(key))
    }

    @Test("O wird als 0 gelesen, I und L als 1")
    func lookalikes() throws {
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))
        let code = RecoveryCode.encode(key)
        #expect(code.contains("0"))
        #expect(try bytes(#require(RecoveryCode.decode(code.replacingOccurrences(of: "0", with: "O")))) == bytes(key))
    }

    @Test("Vertippt, zu kurz oder mit falschen Zeichen wird nichts angenommen")
    func typos() {
        let code = RecoveryCode.encode(SymmetricKey(size: .bits256))
        #expect(RecoveryCode.decode(String(code.dropLast())) == nil)
        #expect(RecoveryCode.decode(code + "A") == nil)
        #expect(RecoveryCode.decode("") == nil)
        #expect(RecoveryCode.decode(code.replacingCharacters(in: code.startIndex...code.startIndex, with: "U")) == nil)
        // Jedes einzeln veränderte Zeichen fällt auf, auch an der letzten Stelle mit ihren ungenutzten Bits.
        var missed = 0
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        // Fester Schlüssel: Zufällig könnten die Prüfbytes passen (1 zu 65536), das wäre kein Fehler.
        let chars = Array(RecoveryCode.encode(SymmetricKey(data: Data(0..<32))))
        for i in chars.indices where chars[i] != "-" {
            for other in alphabet where other != chars[i] {
                var c = chars
                c[i] = other
                if RecoveryCode.decode(String(c)) != nil { missed += 1 }
            }
        }
        #expect(missed == 0)
    }

    @Test("Er passt nur zum Rudel, dessen Daten er öffnet")
    func fits() throws {
        let key = SymmetricKey(size: .bits256)
        let payload = try Sealing.seal(.string("Tierarzt"), key: key, context: Sealing.recordContext(pack: 7, kind: "event", id: "a"))
        let records = [SyncRecord(kind: "event", id: "a", updatedAt: 1, payload: payload)]
        #expect(RecoveryCode.fits(key, records: records, pack: 7))
        #expect(!RecoveryCode.fits(SymmetricKey(size: .bits256), records: records, pack: 7))
        #expect(!RecoveryCode.fits(key, records: records, pack: 8))
        #expect(RecoveryCode.fits(key, records: [], pack: 7))
    }
}

@Suite("Hund in der Nähe")
struct NearbyTests {
    @Test("Der QR-Code enthält den ganzen Einladungslink samt Schlüssel")
    func qrCode() throws {
        let link = "https://thisdog.app/freund/abc123#k=\(Sealing.encode(SymmetricKey(size: .bits256)))"
        let image = try #require(NearbySheet.qrImage(link))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil))
        let found = detector.features(in: try #require(CIImage(image: image))).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [link])
    }
}

