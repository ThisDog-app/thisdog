import SwiftUI

/// Der Kalender. Zugeklappt eine Spalte: Monat, darunter der gewählte Tag und was demnächst ansteht.
/// Aufgeklappt und auf dem iPad zwei Hälften, getrennt auf dem Knick: links der Monat, rechts der Tag.
struct CalendarScreen: View {
    @Environment(DogStore.self) private var store
    @Environment(Account.self) private var account
    @Environment(\.horizontalSizeClass) private var hClass
    /// Kompakt nur beim iPhone im Querformat: wenig Höhe, viel Breite.
    @Environment(\.verticalSizeClass) private var vClass

    @State private var selected: Day = .today
    @State private var editing: DogEvent?
    @State private var showsSettings = false
    @State private var showsAccount = false
    /// Richtung des letzten Monatswechsels, damit der neue Monat von der richtigen Seite kommt.
    @State private var forward = true
    /// Der obere der gezeigten Monate. Auf dem iPad hat die linke Hälfte Platz für zwei.
    @State private var month: Day = Day.today.firstOfMonth
    @State private var twoMonths = false
    /// Wo die Leine den Monat verlässt und wo die Zeitleine beginnt, beide im Fenster gemessen.
    @State private var leashExit: CGFloat = 0
    @State private var leashTop: CGFloat = 0

    /// Wählt einen Tag; liegt er außerhalb der gezeigten Monate, wird sein Monat der obere.
    private func select(_ d: Day) {
        let last = twoMonths ? month.adding(months: 1) : month
        if d.firstOfMonth < month || d.firstOfMonth > last {
            forward = d.firstOfMonth > month
            month = d.firstOfMonth
        }
        selected = d
    }

    var body: some View {
        NavigationStack {
            Group {
                if vClass == .compact {
                    landscape
                } else if hClass == .regular {
                    // Quer darf der Monat schmaler sein: Die Termine rechts brauchen den Platz.
                    FoldSplit(landscapeShare: 0.4) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 40) {
                                monthPane(roomy: true, margin: 24, exit: .side(margin: 24))
                                if twoMonths { secondMonth }
                            }
                            .padding(.vertical, 24)
                        }
                        // Zwei Monate, wenn beide ganz hineinpassen (iPad hochkant), sonst einer.
                        .onGeometryChange(for: Bool.self) { $0.size.height > 1000 } action: { twoMonths = $0 }
                    } trailing: {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                header(size: 52)
                                sideDayPane(margin: 24)
                            }
                            .padding(24)
                        }
                    }
                } else {
                    ScrollView {
                        // Ohne Abstand: Die Leine läuft aus dem Monat direkt in die Zeitleine.
                        VStack(alignment: .leading, spacing: 0) {
                            header(size: 44).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 28)
                            monthPane(roomy: false, margin: 16, exit: .bottom(x: TimeLeash.lineX))
                            dayPane(entry: .top).padding(.horizontal, 16)
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(Palette.paper)
            .clearsTabDock()
            .toolbar(.hidden, for: .navigationBar)
            .sensoryFeedback(.selection, trigger: selected)
            .task { await demo() }
            .sheet(item: $editing) { ev in
                EventEditor(event: ev, isNew: store.event(id: ev.id) == nil)
            }
            .sheet(isPresented: $showsSettings) { CalendarSettings() }
            .sheet(isPresented: $showsAccount) { SettingsScreen() }
        }
    }

    /// iPhone quer: Der ganze Monat steht links, rechts läuft die Leine mit den Terminen weiter.
    private var landscape: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                monthPane(roomy: false, dense: true, margin: 12, exit: .side(margin: 12)).padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 340)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(size: 36)
                    sideDayPane(margin: 12)
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 16)
            }
        }
    }

    /// Die Zeitleine, wenn der Monat in der anderen Spalte steht.
    private func sideDayPane(margin: CGFloat) -> some View {
        dayPane(entry: .side(margin: margin, y: leashExit - leashTop))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { leashTop = $0 }
    }

    // MARK: Kopf

    /// Was als Nächstes ansteht: die wichtigste Antwort der Seite, darum auch der größte Text.
    /// Rechts oben, an immer derselben Stelle, das laute Plus und klein die selten gebrauchte Glocke.
    private func header(size: CGFloat) -> some View {
        Group {
            if let entry = NextUp.pick(from: store.entries) {
                Button {
                    withAnimation(.snappy) { select(entry.start) }
                } label: {
                    NextUp(entry: entry, size: size, reservedTrailing: 96)
                }
                .buttonStyle(.plain)
            } else {
                Text("Gerade steht nichts an.")
                    .font(.display(size * 0.56, weight: .medium, relativeTo: .title3))
                    .foregroundStyle(Palette.ink2)
                    .padding(.trailing, 96)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Button { showsSettings = true } label: {
                    LineIcon("glocke", size: 22)
                        .foregroundStyle(Palette.ink3)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                        .contentShape(.hoverEffect, Circle())
                        .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Erinnerungen und Kalender"))
                addButton(side: 46)
            }
        }
    }

    /// Neuer Termin am gewählten Tag.
    private func addButton(side: CGFloat) -> some View {
        Button { editing = DogEvent(title: "", start: selected) } label: {
            LineIcon("plus", size: side * 0.5)
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(Palette.accent, in: Circle())
                .contentShape(Circle())
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.lift)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Neuer Termin"))
    }

    // MARK: Monat

    private func monthPane(roomy: Bool, dense: Bool = false, margin: CGFloat, exit: MonthGrid.Exit) -> some View {
        VStack(alignment: .leading, spacing: dense ? 6 : 16) {
            // Der längste Monatsname („September“) muss auch in eine Hälfte passen: lieber kleiner als abgeschnitten.
            ViewThatFits(in: .horizontal) {
                ForEach(dense ? [26, 24, 22] : roomy ? [36, 32, 28] : [34, 30, 26], id: \.self) { size in
                    monthHeader(size: CGFloat(size))
                }
            }
            .tint(Palette.ink)

            ForEach(periods(in: month)) { p in
                PeriodLine(entry: p)
            }

            MonthGrid(month: month, selected: selection, entries: store.entries, roomy: roomy, dense: dense, exit: exit) { leashExit = $0 }
                .id(month)
                .transition(.push(from: forward ? .trailing : .leading))
        }
        .padding(.horizontal, margin)
        .clipped()
    }

    /// Der Monat darunter: nur Name und Raster, geblättert wird oben.
    private var secondMonth: some View {
        let next = month.adding(months: 1)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(next.monthName).font(.display(28, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1).fixedSize()
                Text(String(next.year)).font(.display(28, weight: .regular)).foregroundStyle(Palette.ink3)
            }
            .id(next)
            .transition(.push(from: forward ? .trailing : .leading).combined(with: .opacity))
            ForEach(periods(in: next)) { p in
                PeriodLine(entry: p)
            }
            MonthGrid(month: next, selected: selection, entries: store.entries, roomy: true, exit: .side(margin: 24)) { leashExit = $0 }
                .id(next)
                .transition(.push(from: forward ? .trailing : .leading))
        }
        .padding(.horizontal, 24)
        .clipped()
    }

    private func monthHeader(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(month.monthName)
                .font(.display(size, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .fixedSize()
                .id(month)
                .transition(.push(from: forward ? .trailing : .leading).combined(with: .opacity))
            Text(String(month.year))
                .font(.display(size, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .contentTransition(.numericText(countsDown: !forward))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            if month != Day.today.firstOfMonth {
                Button("Heute") {
                    forward = Day.today > month
                    withAnimation(.snappy) { select(.today) }
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
                .fixedSize()
            }
            Button("Vorheriger Monat", icon: "chevron-links") { shift(-1) }
                .labelStyle(.iconOnly)
                .frame(width: 36, height: 44)
            Button("Nächster Monat", icon: "chevron-rechts") { shift(1) }
                .labelStyle(.iconOnly)
                .frame(width: 36, height: 44)
        }
        .buttonStyle(.borderless)
        .tint(Palette.ink2)
    }

    /// Zeiträume, die in den gezeigten Monat fallen.
    private func periods(in month: Day) -> [CalendarEntry] {
        let first = month.firstOfMonth
        let last = Day(month.year, month.month, Day.daysIn(year: month.year, month: month.month))
        return store.entries.filter { $0.isPeriod && $0.start <= last && $0.end >= first }
    }

    private func shift(_ n: Int) {
        let target = month.adding(months: n)
        forward = n > 0
        withAnimation(.snappy) {
            month = target
            selected = target == Day.today.firstOfMonth ? .today : target
        }
    }

    /// Vorführung für Werbevideos (nur Entwicklerfassung, `-vorfuehrung`): die Auswahl wandert über die
    /// Tage mit Terminen, dann einen Monat vor und zurück.
    private func demo() async {
        #if DEBUG
        // Zum Ansehen: `-tag 2` wählt einen Tag in zwei Tagen.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tag"), i + 1 < args.count, let n = Int(args[i + 1]) { select(Day.today.adding(days: n)) }
        // Zum Ansehen: `-einstellungen` öffnet die Einstellungen.
        if ProcessInfo.processInfo.arguments.contains("-einstellungen") { showsAccount = true }
        guard ProcessInfo.processInfo.arguments.contains("-vorfuehrung") else { return }
        let today = Day.today
        let days = Array(Set(store.entries.filter { $0.start >= today && $0.start.firstOfMonth == today.firstOfMonth }.map(\.start))).sorted()
        try? await Task.sleep(for: .seconds(1.5))
        for d in days.prefix(4) {
            withAnimation(.snappy(duration: 0.35)) { select(d) }
            try? await Task.sleep(for: .seconds(1.6))
        }
        shift(1)
        try? await Task.sleep(for: .seconds(1.8))
        shift(-1)
        try? await Task.sleep(for: .seconds(1.2))
        withAnimation(.snappy) { select(today) }
        #endif
    }

    /// Die Auswahl, die auch die Richtung des Monatswechsels setzt – vor dem Wechsel, sonst
    /// käme der neue Monat beim ersten Mal von der falschen Seite.
    private var selection: Binding<Day> {
        Binding(get: { selected }, set: { select($0) })
    }

    // MARK: Restzeit und Zeitleine

    /// Die Leine beginnt am gewählten Tag.
    private func dayPane(entry: TimeLeash.Entry) -> some View {
        TimeLeash(start: selected, entries: store.entries, entry: entry) { e in
            if let id = e.eventID, let ev = store.event(id: id) { editing = ev }
        } onAdd: { day in
            editing = DogEvent(title: "", start: day)
        } author: { e in
            e.eventID.flatMap { store.event(id: $0) }.flatMap { account.author(of: $0) }
        }
    }
}

/// Ein Zeitraum über dem Monat, etwa die Zecken-Saison.
private struct PeriodLine: View {
    let entry: CalendarEntry

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.kind(entry.kind)).frame(width: 6, height: 6)
            Text(entry.plainTitle).font(.footnote.weight(.medium)).foregroundStyle(Palette.ink2)
            Text(range).font(.footnote).foregroundStyle(Palette.ink3)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var range: String {
        entry.covers(.today) ? String(localized: "bis \(entry.end.shortText)") : String(localized: "\(entry.start.shortText) bis \(entry.end.shortText)")
    }
}
