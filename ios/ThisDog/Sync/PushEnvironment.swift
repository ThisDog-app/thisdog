import Foundation

/// Welcher Push-Server von Apple zu dieser Fassung passt. Entscheidend ist das Signierprofil, nicht Debug oder
/// Release: Eine Release-Fassung mit Entwicklerprofil (Download-Link) bekommt Sandbox-Kennungen, und die lehnt
/// der Produktionsserver ab – dann kämen weder Mitteilungen noch die Live-Aktivität an.
enum PushEnvironment {
    static let current: String = {
        if let env = fromProfile(Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")) { return env }
        // Kein Profil: App Store (Produktion) oder Simulator.
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        return "production"
        #endif
    }()

    /// Liest `aps-environment` aus dem eingebetteten Profil (signierte CMS-Hülle um eine Plist).
    static func fromProfile(_ url: URL?) -> String? {
        guard let url, let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any],
              let aps = ent["aps-environment"] as? String
        else { return nil }
        return aps == "development" ? "sandbox" : "production"
    }
}
