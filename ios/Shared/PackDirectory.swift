import Foundation
import UIKit

/// Namen und Bilder der Rudelmitglieder für die Mitteilungs-Erweiterung, im gemeinsamen Ordner der App-Gruppe.
///
/// Alles bleibt auf dem Gerät: Die Mitteilung vom Server trägt nur die Kennung, wer etwas geändert hat; den
/// Namen und das Bild holt die Erweiterung von hier, damit iOS die Mitteilung wie die einer Person zeigt.
enum PackDirectory {
    static let group = "group.app.thisDog"

    struct Person: Codable { let id: Int; let name: String }

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appending(path: "rudel", directoryHint: .isDirectory)
    }

    static func save(people: [Person], images: [Int: Data]) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(people).write(to: folder.appending(path: "mitglieder.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        for p in people {
            let file = folder.appending(path: "bild-\(p.id).jpg")
            if let data = images[p.id] { try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            else { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func person(_ id: Int) -> (name: String, image: Data?)? {
        guard let folder, let data = try? Data(contentsOf: folder.appending(path: "mitglieder.json")),
              let people = try? JSONDecoder().decode([Person].self, from: data),
              let p = people.first(where: { $0.id == id }) else { return nil }
        return (p.name, try? Data(contentsOf: folder.appending(path: "bild-\(id).jpg")))
    }

    static func clear() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
}
