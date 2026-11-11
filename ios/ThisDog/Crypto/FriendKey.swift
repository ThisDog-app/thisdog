import CryptoKit
import Foundation

/// Der Schlüssel einer Hundefreundschaft. Er liegt als Datensatz im Rudel (und damit mit dem Rudel-Schlüssel
/// verschlüsselt), damit alle Mitglieder den Freund sehen; die Kennung ist die der Einladung, die beide Seiten kennen.
struct FriendKey: SyncedItem, Hashable {
    static let kind = "friendkey"
    let id: String
    var key: String
    var u: Double = 0

    var symmetric: SymmetricKey? { Sealing.decode(key) }
}
