import CryptoKit
import Foundation

/// Inhalte, die die App mitbringt und vom Server aktualisiert: Saisonhinweise, später Food und Tipps.
///
/// Fehler in einem Text sollen sich beheben lassen, ohne eine neue Fassung der App zu verteilen.
/// Deshalb gilt in dieser Reihenfolge: zuletzt geladene Fassung vom Server, sonst die mitgelieferte.
/// Eine Datei vom Server wird erst übernommen, wenn sie sich vollständig lesen lässt – eine kaputte
/// Datei auf dem Server darf die App nie leeren.
@MainActor
final class ContentStore {
    static let server = URL(string: "https://thisdog.app/data/")!
    /// So oft wird höchstens nachgefragt; der Server antwortet ohnehin nur bei Änderungen mit Inhalt.
    static let minInterval: TimeInterval = 6 * 3600

    enum File: String, CaseIterable {
        case publicEvents = "public_events"
        case foods
        case tips
    }

    private let folder: URL
    private let defaults = UserDefaults.standard

    init() {
        folder = URL.applicationSupportDirectory.appending(path: "Inhalte", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        forgetOutdatedDownloads()
    }

    /// Bringt ein Update der App eine andere Fassung mit als beim letzten Start, ist die früher vom Server
    /// geladene vermutlich älter: Sie wird verworfen und beim nächsten Abgleich sofort neu gefragt. Sonst
    /// verdeckte eine alte Liste vom Server die neue mitgelieferte, bis zu sechs Stunden lang.
    private func forgetOutdatedDownloads() {
        for file in File.allCases {
            guard let url = Bundle.main.url(forResource: file.rawValue, withExtension: "json"), let bundled = try? Data(contentsOf: url) else { continue }
            let key = "inhalt.\(file.rawValue)"
            let hash = SHA256.hash(data: bundled).map { String(format: "%02x", $0) }.joined()
            guard defaults.string(forKey: key + ".mitgeliefert") != hash else { continue }
            try? FileManager.default.removeItem(at: localURL(file))
            defaults.removeObject(forKey: key + ".etag")
            defaults.removeObject(forKey: key + ".geprueft")
            defaults.set(hash, forKey: key + ".mitgeliefert")
        }
    }

    /// Die aktuelle Fassung einer Datei: geladen, sonst mitgeliefert.
    func data(_ file: File) -> Data? {
        // Vom Server kommen bisher nur die deutschen Inhalte; in anderen Sprachen gilt, was mitgeliefert ist.
        if AppLocale.isGerman, let d = try? Data(contentsOf: localURL(file)) { return d }
        // Übersetzte Inhalte liegen als foods.en.json neben foods.json; fehlt die Sprache, bleibt es Deutsch.
        let translated = Bundle.main.url(forResource: "\(file.rawValue).\(AppLocale.language)", withExtension: "json")
        guard let url = translated ?? Bundle.main.url(forResource: file.rawValue, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    func seasonalHints() -> [SeasonalHint] {
        data(.publicEvents).flatMap { try? JSONDecoder().decode([SeasonalHint].self, from: $0) } ?? []
    }

    /// Fragt beim Server nach neuen Fassungen. Gibt zurück, welche Dateien sich geändert haben.
    @discardableResult
    func refresh(force: Bool = false) async -> Set<File> {
        var changed = Set<File>()
        for file in File.allCases {
            let key = "inhalt.\(file.rawValue)"
            let last = defaults.double(forKey: key + ".geprueft")
            if !force, Date().timeIntervalSince1970 - last < Self.minInterval { continue }

            var req = URLRequest(url: Self.server.appending(path: file.rawValue + ".json"))
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            if let etag = defaults.string(forKey: key + ".etag") { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }

            guard let (body, response) = try? await URLSession.shared.data(for: req),
                  let http = response as? HTTPURLResponse
            else { continue }
            defaults.set(Date().timeIntervalSince1970, forKey: key + ".geprueft")
            guard http.statusCode == 200, Self.isReadable(body, as: file) else { continue }

            do {
                try body.write(to: localURL(file), options: .atomic)
                defaults.set(http.value(forHTTPHeaderField: "ETag"), forKey: key + ".etag")
                changed.insert(file)
            } catch {
                continue
            }
        }
        return changed
    }

    /// Nur eine Datei, die sich als Liste lesen lässt und nicht leer ist, ersetzt die vorhandene.
    static func isReadable(_ data: Data, as file: File) -> Bool {
        switch file {
        case .publicEvents:
            guard let list = try? JSONDecoder().decode([SeasonalHint].self, from: data) else { return false }
            return !list.isEmpty
        case .foods:
            guard let list = try? JSONDecoder().decode([Food].self, from: data) else { return false }
            return list.count >= 50   // eine stark geschrumpfte Liste ist eher ein Fehler als eine Korrektur
        case .tips:
            guard let list = try? JSONDecoder().decode([Tip].self, from: data) else { return false }
            return !list.isEmpty
        }
    }

    private func localURL(_ file: File) -> URL { folder.appending(path: file.rawValue + ".json") }
}
