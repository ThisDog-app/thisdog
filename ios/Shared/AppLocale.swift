import Foundation

/// Die Sprache, in der die App gerade wirklich läuft. Nicht `Locale.current`: Steht das System auf Französisch und es
/// gibt keine französische Übersetzung, zeigt die App Deutsch, und dann sollen auch Datum und Zahlen deutsch sein.
enum AppLocale {
    static let language = Bundle.main.preferredLocalizations.first.flatMap { $0 == "Base" ? nil : $0 } ?? "de"
    static let current = Locale(identifier: language)
    static var isGerman: Bool { language.hasPrefix("de") }
}
