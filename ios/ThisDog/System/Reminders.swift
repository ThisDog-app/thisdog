import Foundation
import UserNotifications

/// Erinnerungen an Termine als Mitteilung auf dem Gerät – ohne Server, auch ohne Netz.
///
/// iOS hält höchstens 64 geplante Mitteilungen je App. Geplant werden deshalb die nächsten Vorkommen,
/// neu bei jeder Änderung und bei jedem Start.
@MainActor
final class Reminders {
    static let limit = 60
    /// Ganztägige Termine: an diesem Tag um diese Uhrzeit.
    static let allDayHour = 8
    /// Termine mit Uhrzeit: so viele Minuten vorher.
    static let leadMinutes = 60

    private let center = UNUserNotificationCenter.current()
    private let enabledKey = "erinnerungen.an"

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    func enable() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        return granted
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        center.removeAllPendingNotificationRequests()
    }

    /// Erinnerungen an Impfung und Entwurmung tragen einen Knopf „Erledigt“ – auch auf der Watch.
    nonisolated static let dueCategory = "faellig"
    nonisolated static let doneAction = "erledigt"
    nonisolated static let dueKey = "due"

    static func registerCategories() {
        let done = UNNotificationAction(identifier: doneAction, title: String(localized: "Erledigt"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: dueCategory, actions: [done], intentIdentifiers: []),
        ])
    }

    /// Plant die nächsten Erinnerungen neu. `doneable`: Einträge, die sich aus der Mitteilung abhaken lassen.
    func schedule(_ events: [DogEvent], extra: [CalendarEntry] = [], doneable: Set<String> = [], now: Date = Date()) {
        center.removeAllPendingNotificationRequests()
        guard isEnabled else { return }
        for (when, entry) in Self.upcoming(events, extra: extra, now: now).prefix(Self.limit) {
            let content = UNMutableNotificationContent()
            content.title = entry.title
            content.body = Self.body(entry)
            content.sound = .default
            if doneable.contains(entry.id) {
                content.categoryIdentifier = Self.dueCategory
                content.userInfo = [Self.dueKey: entry.id]
            }
            let comps = Calendar.gregorianLocal.dateComponents([.year, .month, .day, .hour, .minute], from: when)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: "erinnerung.\(entry.id)", content: content, trigger: trigger))
        }
    }

    /// Wann an welches Vorkommen erinnert wird, aufsteigend; nur, was noch bevorsteht.
    /// `extra`: Fälligkeiten aus den Gesundheitsdaten und der Geburtstag – sie erinnern wie ganztägige Termine.
    static func upcoming(_ events: [DogEvent], extra: [CalendarEntry] = [], now: Date) -> [(Date, CalendarEntry)] {
        let today = Day(date: now)
        return (events.flatMap { CalendarBuilder.occurrences(of: $0, today: today) } + extra)
            .compactMap { e -> (Date, CalendarEntry)? in
                let at: Date
                if let (h, m) = SystemCalendar.clock(e.time) {
                    let start = Calendar.gregorianLocal.date(bySettingHour: h, minute: m, second: 0, of: e.start.date)!
                    at = start.addingTimeInterval(TimeInterval(-leadMinutes * 60))
                } else {
                    at = Calendar.gregorianLocal.date(bySettingHour: allDayHour, minute: 0, second: 0, of: e.start.date)!
                }
                return at > now ? (at, e) : nil
            }
            .sorted { $0.0 < $1.0 }
    }

    static func body(_ e: CalendarEntry) -> String {
        if let (h, m) = SystemCalendar.clock(e.time) { return String(format: "Um %d:%02d Uhr", h, m) }
        return e.spanDays > 1 ? String(localized: "Ab heute, \(e.spanDays) Tage") : String(localized: "Heute")
    }
}
