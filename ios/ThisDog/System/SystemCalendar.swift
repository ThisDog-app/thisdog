import EventKit
import Foundation

/// Trägt die eigenen Termine in einen eigenen Kalender „ThisDog“ im Systemkalender ein.
///
/// Die App bleibt die Quelle: Sie legt an, ändert und löscht dort, was sie selbst eingetragen hat.
/// Was jemand im Systemkalender an diesen Einträgen ändert, wird beim nächsten Abgleich überschrieben.
/// Serien werden als Serie eingetragen (mit Regel), nicht als einzelne Vorkommen.
@MainActor
final class SystemCalendar {
    static let calendarTitle = String(localized: "ThisDog")

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard
    private let enabledKey = "kalender.eintragen"
    private let linksKey = "kalender.verknuepfungen"
    /// Termin → `calendarItemExternalIdentifier` (Kennung beim Kalenderdienst, übersteht ein Neuladen eher).
    private let externalKey = "kalender.extern"
    private let calendarKey = "kalender.kennung"

    var isEnabled: Bool { defaults.bool(forKey: enabledKey) }
    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Schaltet das Eintragen ein; fragt dafür einmal nach dem Zugriff.
    func enable() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        defaults.set(granted, forKey: enabledKey)
        return granted
    }

    /// Schaltet aus und entfernt den Kalender „ThisDog“ samt Einträgen.
    func disable() {
        defaults.set(false, forKey: enabledKey)
        if hasAccess, let cal = ownCalendar(create: false) { try? store.removeCalendar(cal, commit: true) }
        defaults.removeObject(forKey: linksKey)
        defaults.removeObject(forKey: externalKey)
        defaults.removeObject(forKey: calendarKey)
    }

    /// Bringt den Kalender „ThisDog“ auf den Stand der Termine.
    ///
    /// Verknüpft ist über die Kennung des Eintrags (`eventIdentifier`). Die kann sich ändern (etwa wenn iCloud den
    /// Kalender neu lädt); dann helfen die Kennung beim Kalenderdienst und die Marke `thisdog://event/<id>` an
    /// jedem Eintrag. Ohne diese Rückfallwege entstünde bei jeder verlorenen Kennung ein doppelter Eintrag.
    func sync(_ events: [DogEvent]) {
        guard isEnabled, hasAccess, let cal = ownCalendar(create: true) else { return }
        var links = defaults.dictionary(forKey: linksKey) as? [String: String] ?? [:]
        var external = defaults.dictionary(forKey: externalKey) as? [String: String] ?? [:]
        let wanted = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        var marked = markedEvents(in: cal, around: events, linked: Set(links.values))

        /// Der Eintrag zu einem Termin: über die Kennung, die Kennung beim Kalenderdienst oder die Marke.
        func find(_ id: String) -> EKEvent? {
            if let ekID = links[id], let ek = store.event(withIdentifier: ekID), belongs(ek, to: id, in: cal) { return ek }
            if let extID = external[id],
               let ek = store.calendarItems(withExternalIdentifier: extID).compactMap({ $0 as? EKEvent }).first(where: { belongs($0, to: id, in: cal) }) {
                return master(ek)
            }
            return marked[id].flatMap { store.event(withIdentifier: $0) }
        }

        // Entfernen, was es in der App nicht mehr gibt – erst nachdem alle Wege gesucht haben. Klappt das Löschen
        // nicht, bleibt die Verknüpfung für den nächsten Versuch.
        for id in Set(links.keys).union(external.keys).union(marked.keys) where wanted[id] == nil {
            if let ek = find(id) {
                guard (try? store.remove(ek, span: .futureEvents, commit: false)) != nil else { continue }
            }
            links[id] = nil
            external[id] = nil
            marked[id] = nil
        }

        for ev in events {
            guard let start = ev.startDay else { continue }
            let ek = find(ev.id) ?? EKEvent(eventStore: store)
            ek.calendar = cal
            ek.title = ev.title
            ek.notes = ev.notes.isEmpty ? nil : ev.notes
            ek.url = Self.marker(for: ev.id)

            if let (h, m) = Self.clock(ev.time) {
                ek.isAllDay = false
                ek.startDate = Calendar.gregorianLocal.date(bySettingHour: h, minute: m, second: 0, of: start.date)!
                // Ende mit Tag und Uhrzeit, wenn es eins gibt; sonst eine Stunde.
                let last = ev.endDay ?? start
                if let (eh, em) = Self.clock(ev.endTime),
                   let e = Calendar.gregorianLocal.date(bySettingHour: eh, minute: em, second: 0, of: last.date), e > ek.startDate {
                    ek.endDate = e
                } else {
                    ek.endDate = Calendar.gregorianLocal.date(bySettingHour: h, minute: m, second: 0, of: last.date)!.addingTimeInterval(last == start ? 3600 : 0)
                }
            } else {
                ek.isAllDay = true
                ek.startDate = start.date
                // Bei ganztägigen Einträgen gilt das Ende einschließlich des letzten Tages.
                ek.endDate = (ev.endDay ?? start).date
            }
            ek.recurrenceRules = ev.rule.map { [Self.recurrence($0, until: ev.untilDay)] }

            do {
                try store.save(ek, span: .futureEvents, commit: false)
                links[ev.id] = ek.eventIdentifier
                if let ext = ek.calendarItemExternalIdentifier { external[ev.id] = ext }
            } catch {
                continue
            }
        }
        try? store.commit()
        defaults.set(links, forKey: linksKey)
        defaults.set(external, forKey: externalKey)
    }

    /// Gehört der Eintrag im Kalender „ThisDog“ zu diesem Termin? Einträge ohne Marke stammen aus älteren Fassungen.
    private func belongs(_ ek: EKEvent, to id: String, in cal: EKCalendar) -> Bool {
        guard ek.calendar?.calendarIdentifier == cal.calendarIdentifier else { return false }
        guard let url = ek.url else { return true }
        return Self.eventID(fromMarker: url) == id
    }

    /// Bei einer Serie das erste Vorkommen: Gespeichert und gelöscht wird immer die ganze Serie.
    private func master(_ ek: EKEvent) -> EKEvent {
        ek.eventIdentifier.flatMap { store.event(withIdentifier: $0) } ?? ek
    }

    /// Alle Einträge mit Marke im Kalender „ThisDog“: Termin → Kennung des Eintrags. Gesucht wird in Abschnitten von
    /// höchstens vier Jahren (mehr lässt EventKit nicht zu) über die Spanne der Termine. Doppelte Einträge mit
    /// derselben Marke – Überbleibsel verlorener Kennungen – werden dabei entfernt.
    private func markedEvents(in cal: EKCalendar, around events: [DogEvent], linked: Set<String>) -> [String: String] {
        let cal0 = Calendar.gregorianLocal
        let now = Date()
        let days = events.compactMap(\.startDay).map(\.date)
        var from = min(days.min() ?? now, cal0.date(byAdding: .year, value: -2, to: now)!)
        let to = max(days.max() ?? now, cal0.date(byAdding: .year, value: 2, to: now)!)
        // Mehr als zwanzig Jahre zurück sucht niemand.
        from = max(from, cal0.date(byAdding: .year, value: -20, to: now)!)
        var found: [String: String] = [:]
        var extra: [String: EKEvent] = [:]
        while from < to {
            let next = min(cal0.date(byAdding: .year, value: 3, to: from)!, cal0.date(byAdding: .day, value: 1, to: to)!)
            for ek in store.events(matching: store.predicateForEvents(withStart: from, end: next, calendars: [cal])) {
                guard let url = ek.url, let id = Self.eventID(fromMarker: url), let ekID = ek.eventIdentifier else { continue }
                guard let known = found[id] else { found[id] = ekID; continue }
                guard known != ekID else { continue }
                // Der verknüpfte Eintrag bleibt, der andere geht.
                if linked.contains(ekID) {
                    extra[known] = extra[known] ?? store.event(withIdentifier: known)
                    found[id] = ekID
                } else {
                    extra[ekID] = extra[ekID] ?? ek
                }
            }
            from = next
        }
        for ek in extra.values { try? store.remove(master(ek), span: .futureEvents, commit: false) }
        return found
    }

    /// Die Marke an jedem Eintrag: thisdog://event/<id>.
    nonisolated static func marker(for id: String) -> URL? {
        var c = URLComponents()
        c.scheme = "thisdog"
        c.host = "event"
        c.path = "/" + id
        return c.url
    }

    nonisolated static func eventID(fromMarker url: URL) -> String? {
        guard url.scheme == "thisdog", url.host() == "event" else { return nil }
        let id = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }

    private func ownCalendar(create: Bool) -> EKCalendar? {
        if let id = defaults.string(forKey: calendarKey), let cal = store.calendar(withIdentifier: id) { return cal }
        if let cal = store.calendars(for: .event).first(where: { $0.title == Self.calendarTitle && $0.allowsContentModifications }) {
            defaults.set(cal.calendarIdentifier, forKey: calendarKey)
            return cal
        }
        guard create else { return nil }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = Self.calendarTitle
        cal.cgColor = Palette.calendarColor
        // Dort, wo neue Termine sonst auch landen (meist iCloud), damit der Kalender auf allen Geräten erscheint.
        cal.source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .local }
        guard cal.source != nil, (try? store.saveCalendar(cal, commit: true)) != nil else { return nil }
        defaults.set(cal.calendarIdentifier, forKey: calendarKey)
        return cal
    }

    static func recurrence(_ r: Repetition, until: Day?) -> EKRecurrenceRule {
        let (freq, interval): (EKRecurrenceFrequency, Int) = switch r {
        case .weekly: (.weekly, 1)
        case .biweekly: (.weekly, 2)
        case .monthly: (.monthly, 1)
        case .quarterly: (.monthly, 3)
        case .halfyearly: (.monthly, 6)
        case .yearly: (.yearly, 1)
        }
        // Das Ende der Serie gilt einschließlich: bis zum Ende dieses Tages.
        let end = until.map { EKRecurrenceEnd(end: $0.adding(days: 1).date.addingTimeInterval(-1)) }
        return EKRecurrenceRule(recurrenceWith: freq, interval: interval, end: end)
    }

    /// „09:30“ → (9, 30); leer oder ungültig → nil.
    nonisolated static func clock(_ s: String) -> (Int, Int)? {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }
}
