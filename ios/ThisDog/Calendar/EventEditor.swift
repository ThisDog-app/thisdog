import SwiftUI

/// Termin anlegen oder bearbeiten.
struct EventEditor: View {
    @Environment(DogStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    @State private var title: String
    @State private var allDay: Bool
    /// Beginn und Ende mit Tag und Uhrzeit; ganztägig zählen nur die Tage.
    @State private var start: Date
    @State private var end: Date
    @State private var repetition: Repetition?
    @State private var hasUntil: Bool
    @State private var until: Date
    @State private var notes: String
    @State private var confirmsDelete = false
    private let original: DogEvent

    init(event: DogEvent, isNew: Bool) {
        original = event
        self.isNew = isNew
        let range = EventTimes(event: event, isNew: isNew)
        _title = State(initialValue: event.title)
        _allDay = State(initialValue: range.allDay)
        _start = State(initialValue: range.start)
        _end = State(initialValue: range.end)
        _repetition = State(initialValue: event.rule)
        _hasUntil = State(initialValue: event.untilDay != nil)
        _until = State(initialValue: (event.untilDay ?? Day(date: range.start).adding(years: 1)).date)
        _notes = State(initialValue: event.notes)
    }

    private var startDay: Day { Day(date: start) }
    private var problem: String? {
        if allDay ? Day(date: end) < startDay : end < start { return String(localized: "Das Ende liegt vor dem Beginn.") }
        if repetition != nil, hasUntil, Day(date: until) < startDay { return String(localized: "Die Serie endet vor ihrem Beginn.") }
        return nil
    }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && problem == nil }
    private var parts: DatePickerComponents { allDay ? .date : [.date, .hourAndMinute] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel, z. B. Tierarzt", text: $title)
                        .font(.body.weight(.semibold))
                }
                Section {
                    Toggle("Ganztägig", isOn: $allDay.animation())
                    DatePicker("Beginn", selection: $start, displayedComponents: parts)
                        // Das Ende wandert mit: Wer den Beginn verschiebt, behält die Dauer.
                        .onChange(of: start) { old, new in end = end.addingTimeInterval(new.timeIntervalSince(old)) }
                    DatePicker("Ende", selection: $end, in: (allDay ? Calendar.gregorianLocal.startOfDay(for: start) : start)..., displayedComponents: parts)
                } footer: {
                    if let span = EventTimes.spanText(start: start, end: end, allDay: allDay) { Text(span) }
                }
                Section {
                    Picker("Wiederholung", selection: $repetition.animation()) {
                        Text("Einmalig").tag(Repetition?.none)
                        ForEach(Repetition.allCases, id: \.self) { r in
                            Text(r.label).tag(Repetition?.some(r))
                        }
                    }
                    if repetition != nil {
                        Toggle("Endet", isOn: $hasUntil.animation())
                        if hasUntil {
                            DatePicker("Am", selection: $until, in: start..., displayedComponents: .date)
                        }
                    }
                } footer: {
                    if !isNew, original.rule != nil { Text("Änderungen gelten für alle Termine dieser Serie.") }
                }
                Section("Notizen") {
                    TextField("Details zum Termin", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(Palette.kind(.health)) }
                }
                if !isNew {
                    Section {
                        Button(original.rule == nil ? String(localized: "Termin löschen") : String(localized: "Serie löschen"), role: .destructive) {
                            confirmsDelete = true
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(isNew ? String(localized: "Neuer Termin") : String(localized: "Termin bearbeiten")) {
                BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                BarTextItem(title: String(localized: "Speichern"), disabled: !canSave) { save() }
            }
            .confirmationDialog(original.rule == nil ? String(localized: "Termin löschen?") : String(localized: "Serie löschen?"),
                                isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    store.delete(id: original.id)
                    dismiss()
                }
            } message: {
                Text(original.rule == nil ? String(localized: "„\(original.title)“ wird entfernt.") : String(localized: "„\(original.title)“ wird mit allen Wiederholungen entfernt."))
            }
        }
        .tint(Palette.accent)
    }

    private func save() {
        var ev = EventTimes(allDay: allDay, start: start, end: end).applied(to: original)
        ev.title = title.trimmingCharacters(in: .whitespaces)
        ev.repetition = repetition?.rawValue ?? ""
        ev.repeatUntil = repetition != nil && hasUntil ? Day(date: until).iso : ""
        ev.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(ev)
        dismiss()
    }
}

/// Beginn und Ende eines Termins, wie der Editor sie zeigt – und wie sie gespeichert werden.
struct EventTimes: Equatable {
    var allDay: Bool
    var start: Date
    var end: Date

    init(allDay: Bool, start: Date, end: Date) { self.allDay = allDay; self.start = start; self.end = end }

    /// Neu: die nächste volle Stunde des gewählten Tages (heute: ab jetzt), eine Stunde lang.
    /// Bestehend: ganztägig ohne Uhrzeit, sonst mit Ende (fehlt es: eine Stunde nach Beginn).
    init(event: DogEvent, isNew: Bool, now: Date = Date()) {
        let cal = Calendar.gregorianLocal
        // Eine Stunde später, aber nicht über Mitternacht – sonst würde aus Öffnen und Sichern ein zweitägiger Termin.
        func hourLater(_ d: Date) -> Date { min(d.addingTimeInterval(3600), cal.date(bySettingHour: 23, minute: 59, second: 0, of: d)!) }
        let first = event.startDay ?? Day(date: now)
        let last = max(event.endDay ?? first, first)
        if let (h, m) = SystemCalendar.clock(event.time) {
            allDay = false
            start = cal.date(bySettingHour: h, minute: m, second: 0, of: first.date)!
            if let (eh, em) = SystemCalendar.clock(event.endTime) {
                end = max(start, cal.date(bySettingHour: eh, minute: em, second: 0, of: last.date)!)
            } else {
                end = last == first ? hourLater(start) : cal.date(bySettingHour: h, minute: m, second: 0, of: last.date)!
            }
        } else if isNew {
            allDay = false
            let hour = first == Day(date: now) ? min(cal.component(.hour, from: now) + 1, 23) : 10
            start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: first.date)!
            end = hourLater(start)
        } else {
            allDay = true
            start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: first.date)!
            end = cal.date(bySettingHour: 11, minute: 0, second: 0, of: last.date)!
        }
    }

    func applied(to event: DogEvent) -> DogEvent {
        var ev = event
        let first = Day(date: start), last = Day(date: end)
        ev.start = first.iso
        ev.end = last > first ? last.iso : ""
        if allDay {
            ev.time = ""
            ev.endTime = ""
        } else {
            ev.time = Self.clock(start)
            ev.endTime = end > start ? Self.clock(end) : ""
        }
        return ev
    }

    static func clock(_ d: Date) -> String {
        let c = Calendar.gregorianLocal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// „2 Tage“, „1 Std. 30 Min.“ – damit man die Dauer sieht, ohne zu rechnen.
    static func spanText(start: Date, end: Date, allDay: Bool) -> String? {
        if allDay {
            let n = Day(date: start).days(until: Day(date: end)) + 1
            return n > 1 ? String(localized: "\(n) Tage") : nil
        }
        guard end > start else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .short
        f.calendar = Calendar.gregorianLocal
        return f.string(from: start, to: end).map { String(localized: "Dauer: \($0)") }
    }
}
