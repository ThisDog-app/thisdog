import SwiftUI
import UIKit

/// Farben von ThisDog, Richtung „Mandarine“: Orange auf kühlem Hellgrau, Tinte in Pflaumengrau.
/// Die Terminarten bilden eine Familie – warm für Eigenes und Gesundheit, Blau als einziger Gegenpol
/// für Saisonhinweise –, damit der Monat ruhig bleibt und doch lesbar ist.
///
/// Gemerkt als zweite Richtung: „Melanzani“ (dunkles Lila #3A1D4A, heute in Aprikose #F08A5D).
enum Palette {
    static let paper = dynamic(light: 0xF6F6F8, dark: 0x16141A)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x211E26)
    static let ink = dynamic(light: 0x241E2B, dark: 0xF1EEF4)
    static let ink2 = dynamic(light: 0x69627A, dark: 0xB3ACBF)
    static let ink3 = dynamic(light: 0xA29CAF, dark: 0x7F788B)
    static let line = dynamic(light: 0xE8E6EE, dark: 0x302B37)

    /// Mandarine: Hauptfarbe für Buttons, die große Restzeit und „heute“.
    static let accent = dynamic(light: 0xEE6A24, dark: 0xFF8746)
    /// Zarte Tönung dahinter (heute, gewählter Tag, aktiver Tab).
    static let soft = dynamic(light: 0xFDEADF, dark: 0x3A2519)

    static func kind(_ k: EntryKind) -> Color {
        switch k {
        case .personal: accent
        case .health: dynamic(light: 0xC8473D, dark: 0xF07A6E)
        case .seasonal: dynamic(light: 0x6F86D6, dark: 0x8FA4EA)
        case .warning: dynamic(light: 0xEFAE3A, dark: 0xF4BE55)
        case .birthday: dynamic(light: 0xD9608F, dark: 0xEE86AE)
        }
    }

    /// Farbe des Kalenders „ThisDog“ im Systemkalender.
    static var calendarColor: CGColor { UIColor(rgb: 0xEE6A24).cgColor }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// Bricolage Grotesque für Überschriften und Zahlen, sonst die Systemschrift.
    /// `width` unter 100 nutzt die Breitenachse der Schrift (bis 75 = schmal).
    static func display(_ size: CGFloat, weight: Font.Weight = .bold, width: CGFloat = 100,
                        relativeTo style: Font.TextStyle = .title) -> Font {
        if width >= 100 { return .custom(String(localized: "Bricolage Grotesque"), size: size, relativeTo: style).weight(weight) }
        return Font(BricolageFont.make(size: size, weight: weight, width: width))
    }
}

/// Bricolage mit gesetzter Breitenachse – SwiftUI kennt für eigene Schriften keine Breite.
enum BricolageFont {
    static func make(size: CGFloat, weight: Font.Weight, width: CGFloat) -> UIFont {
        let wght: CGFloat = switch weight {
        case .ultraLight: 200
        case .thin, .light: 300
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        default: 800
        }
        let axes: [Int: CGFloat] = [0x7767_6874: wght, 0x7764_7468: width] // „wght“, „wdth“
        let desc = UIFontDescriptor(fontAttributes: [
            .family: String(localized: "Bricolage Grotesque"),
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes,
        ])
        return UIFont(descriptor: desc, size: UIFontMetrics.default.scaledValue(for: size))
    }
}
