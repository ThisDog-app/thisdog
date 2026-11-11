import Foundation

/// Schreibweisen für Tage in der Sprache der App. Deutsch steht fest, damit es so bleibt, wie wir es wollen
/// („Sept.“, „März“); andere Sprachen kommen aus dem System.
extension Day {
    private static let symbols: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = AppLocale.current
        return c
    }()

    /// Der Kalender beginnt bei Sonntag, unsere Listen bei Montag.
    private static func fromMonday(_ list: [String]) -> [String] { Array(list.dropFirst()) + [list[0]] }

    static let monthNames = AppLocale.isGerman
        ? ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
        : symbols.standaloneMonthSymbols
    static let monthShort = AppLocale.isGerman
        ? ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez."]
        : symbols.shortMonthSymbols
    static let weekdayNames = AppLocale.isGerman
        ? ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
        : fromMonday(symbols.standaloneWeekdaySymbols)
    static let weekdayShort = AppLocale.isGerman
        ? ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
        : fromMonday(symbols.veryShortStandaloneWeekdaySymbols.count == 7 ? symbols.shortStandaloneWeekdaySymbols : symbols.shortWeekdaySymbols)

    var monthName: String { Day.monthNames[month - 1] }

    /// „Freitag, 17. Oktober“
    var longText: String { String(localized: "\(Day.weekdayNames[weekdayFromMonday]), \(day). \(monthName)") }

    /// „17. Okt.“, mit Jahr, wenn es nicht das laufende ist.
    var shortText: String {
        let short = Day.monthShort[month - 1]
        return year == Day.today.year ? String(localized: "\(day). \(short)") : String(localized: "\(day). \(short) \(String(year))")
    }

    /// „Heute“, „Morgen“, „In 5 Tagen“, „Vor 3 Tagen“ – darüber hinaus das Datum.
    func relativeText(from today: Day = .today) -> String {
        let n = today.days(until: self)
        switch n {
        case 0: return String(localized: "Heute")
        case 1: return String(localized: "Morgen")
        case -1: return String(localized: "Gestern")
        case 2...30: return String(localized: "In \(n) Tagen")
        case -30 ... -2: return String(localized: "Vor \(-n) Tagen")
        default: return shortText
        }
    }
}

extension String {
    /// „Jede Woche“ → „jede Woche“, für Angaben mitten im Satz.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
