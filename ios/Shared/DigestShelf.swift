import Foundation
import WidgetKit

/// Die Zusammenfassung (Woche, Fälligkeiten, Wetter) in der App-Gruppe: Das iPhone legt sie für sein Widget ab,
/// die Watch für ihre Komplikation.
enum DigestShelf {
    static let group = "group.app.thisDog"
    private static let key = "digest"

    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    static func load() -> WatchLink.Digest {
        guard let data = defaults.data(forKey: key), let d = try? JSONDecoder().decode(WatchLink.Digest.self, from: data) else { return .init() }
        return d
    }

    /// Legt ab und lässt Widgets neu zeichnen, wenn sich etwas geändert hat.
    static func save(_ d: WatchLink.Digest) {
        guard d != load(), let data = try? JSONEncoder().encode(d) else { return }
        defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
