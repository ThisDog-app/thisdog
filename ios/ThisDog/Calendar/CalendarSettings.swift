import SwiftUI

/// Erinnerungen und Systemkalender ein- und ausschalten.
struct CalendarSettings: View {
    @Environment(DogStore.self) private var store
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var remindersOn = false
    @State private var calendarOn = false
    @State private var refused: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Erinnerungen", isOn: Binding(get: { remindersOn }, set: { on in Task { await setReminders(on) } }))
                } footer: {
                    Text("Ganztägige Termine um \(Reminders.allDayHour) Uhr am Tag selbst, Termine mit Uhrzeit eine Stunde vorher.")
                }
                Section {
                    Toggle("Im iPhone-Kalender", isOn: Binding(get: { calendarOn }, set: { on in Task { await setCalendar(on) } }))
                } footer: {
                    Text("Deine Termine stehen dort in einem eigenen Kalender „\(SystemCalendar.calendarTitle)“. Ausschalten entfernt ihn wieder.")
                }
                if let refused {
                    Section { Text(refused).foregroundStyle(Palette.ink2) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(String(localized: "Erinnerungen und Kalender")) { BarTextItem(title: String(localized: "Fertig")) { dismiss() } }
        }
        .tint(Palette.accent)
        .onAppear {
            remindersOn = services.reminders.isEnabled
            calendarOn = services.calendar.isEnabled && services.calendar.hasAccess
        }
    }

    private func setReminders(_ on: Bool) async {
        if on {
            remindersOn = await services.reminders.enable()
            refused = remindersOn ? nil : String(localized: "Mitteilungen sind für ThisDog ausgeschaltet. Einschalten unter Einstellungen › Mitteilungen › ThisDog.")
        } else {
            services.reminders.disable()
            remindersOn = false
        }
        services.apply(store)
    }

    private func setCalendar(_ on: Bool) async {
        if on {
            calendarOn = await services.calendar.enable()
            refused = calendarOn ? nil : String(localized: "ThisDog hat keinen Zugriff auf den Kalender. Erlauben unter Einstellungen › Apps › ThisDog › Kalender.")
        } else {
            services.calendar.disable()
            calendarOn = false
        }
        services.apply(store)
    }
}
