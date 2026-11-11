import SwiftUI

/// Der Monat als Raster. Heute ist ausgefüllt, ein anderer gewählter Tag dunkel.
/// Vom gewählten Tag läuft die Leine in einem Bogen hinter den Zahlen zur Zeitleine.
/// Mehrtägiges liegt als Band hinter den Tagen, einzelne Termine sind Punkte unter der Zahl.
struct MonthGrid: View {
    /// Wo die Leine den Monat verlässt.
    enum Exit {
        /// Nach unten, wo die Zeitleine direkt anschließt.
        case bottom(x: CGFloat)
        /// Zur Seite, über den Rand der Spalte (`margin`) hinaus.
        case side(margin: CGFloat)
    }

    let month: Day
    @Binding var selected: Day
    let entries: [CalendarEntry]
    /// Aufgeklappt und auf dem iPad sind die Zellen höher.
    var roomy = false
    /// iPhone quer: wenig Höhe, sechs Wochen müssen trotzdem hineinpassen.
    var dense = false
    var exit: Exit = .side(margin: 0)
    /// Auf welcher Höhe im Fenster die Leine den Monat verlässt, damit die andere Spalte dort weitermacht.
    var onExit: ((CGFloat) -> Void)? = nil

    private var today: Day { .today }
    @Namespace private var ring
    @State private var drawn: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cellHeight: CGFloat { dense ? 39 : roomy ? 62 : 48 }
    private var disc: CGFloat { dense ? 31 : roomy ? 42 : 36 }
    private var rowGap: CGFloat { dense ? 0 : roomy ? 6 : 2 }
    private var first: Day { month.firstOfMonth }
    private var last: Day { Day(month.year, month.month, Day.daysIn(year: month.year, month: month.month)) }

    /// Alle Tage des Rasters, auch die angrenzenden, damit es ganze Wochen sind.
    private var cells: [Day] {
        let lead = first.weekdayFromMonday
        var out = (0..<lead).reversed().map { first.adding(days: -($0 + 1)) }
        out += (1...Day.daysIn(year: month.year, month: month.month)).map { Day(month.year, month.month, $0) }
        var next = last
        while out.count % 7 != 0 { next = next.adding(days: 1); out.append(next) }
        return out
    }

    var body: some View {
        let days = cells
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<($0 + 7)]) }
        let byDay = dotsByDay()
        let banded = bandedDays()
        VStack(spacing: dense ? 4 : 8) {
            HStack(spacing: 0) {
                ForEach(Day.weekdayShort, id: \.self) { d in
                    Text(d)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.ink3)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: rowGap) {
                ForEach(weeks.indices, id: \.self) { w in
                    HStack(spacing: 0) {
                        ForEach(weeks[w], id: \.self) { day in
                            cell(day, dots: byDay[day] ?? [], inBand: banded.contains(day))
                        }
                    }
                }
            }
            .background { GeometryReader { g in lines(days: days, size: g.size) } }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            guard abs(v.translation.width) > abs(v.translation.height) else { return }
            let target = month.adding(months: v.translation.width < 0 ? 1 : -1)
            withAnimation(.snappy) { selected = target == today.firstOfMonth ? today : target }
        })
        .onChange(of: selected) {
            guard !reduceMotion else { return }
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { drawn = 0 }
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.55)) { drawn = 1 } }
        }
    }

    // MARK: Tag

    private func cell(_ day: Day, dots: [EntryKind], inBand: Bool) -> some View {
        let inMonth = day >= first && day <= last
        let isToday = day == today && inMonth
        let isSelected = day == selected && inMonth
        return Button {
            withAnimation(.snappy(duration: 0.28)) { selected = day }
        } label: {
            VStack(spacing: 3) {
                Text("\(day.day)")
                    .font(.display(dense ? 15 : roomy ? 18 : 17, weight: isToday || isSelected ? .semibold : .regular, relativeTo: .body))
                    .monospacedDigit()
                    .foregroundStyle(color(day, inMonth: inMonth, isToday: isToday, isSelected: isSelected))
                    .frame(width: disc, height: disc)
                    .background {
                        if isSelected {
                            Circle().fill(isToday ? Palette.accent : Palette.ink)
                                .matchedGeometryEffect(id: "auswahl", in: ring)
                        } else if !inBand {
                            // Die Leine läuft hinter der Zahl vorbei, nicht durch sie hindurch.
                            Circle().fill(Palette.paper).padding(4)
                        }
                    }
                HStack(spacing: 3) {
                    if inMonth {
                        ForEach(Array(dots.prefix(3).enumerated()), id: \.offset) { _, k in
                            Circle().fill(Palette.kind(k)).frame(width: 5, height: 5)
                        }
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: cellHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility(day, dots: dots))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func color(_ day: Day, inMonth: Bool, isToday: Bool, isSelected: Bool) -> Color {
        if isSelected { return isToday ? .white : Palette.paper }
        if isToday { return Palette.accent }
        if !inMonth { return Palette.ink3.opacity(0.55) }
        return day < today ? Palette.ink3 : Palette.ink
    }

    // MARK: Leine und Bänder

    private func center(_ day: Day, days: [Day], size: CGSize) -> CGPoint? {
        guard let i = days.firstIndex(of: day) else { return nil }
        let w = size.width / 7
        return CGPoint(x: (CGFloat(i % 7) + 0.5) * w, y: CGFloat(i / 7) * (cellHeight + rowGap) + disc / 2)
    }

    @ViewBuilder
    private func lines(days: [Day], size: CGSize) -> some View {
        Canvas { ctx, _ in
            for e in entries where !e.isPeriod && e.spanDays > 1 && e.end >= first && e.start <= last {
                var runStart = max(e.start, first)
                let end = min(e.end, last)
                while runStart <= end {
                    let toWeekEnd = 6 - runStart.weekdayFromMonday
                    let runEnd = min(runStart.adding(days: toWeekEnd), end)
                    if let a = center(runStart, days: days, size: size), let b = center(runEnd, days: days, size: size) {
                        let r = CGRect(x: a.x - disc / 2, y: a.y - disc / 2, width: b.x - a.x + disc, height: disc)
                        ctx.fill(Path(roundedRect: r, cornerRadius: disc / 2), with: .color(Palette.kind(e.kind).opacity(0.14)))
                    }
                    runStart = runEnd.adding(days: 1)
                }
            }
        }
        let points = leashPoints(days: days, size: size)
        if points.count > 1 {
            LeashShape(points: points)
                .trim(from: 0, to: drawn)
                .stroke(Palette.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let exitY = points[points.count - 1].y
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY + exitY } action: { onExit?($0) }
        }
    }

    /// Ein einziger ruhiger Bogen vom gewählten Tag zur Zeitleine. Mehr Linie macht das Raster unruhig.
    private func leashPoints(days: [Day], size: CGSize) -> [CGPoint] {
        guard selected >= first, selected <= last, let c = center(selected, days: days, size: size) else { return [] }
        let to: CGPoint, c1: CGPoint, c2: CGPoint
        switch exit {
        case .bottom(let x):
            to = CGPoint(x: x, y: size.height + 1)
            let drop = to.y - c.y
            c1 = CGPoint(x: c.x + 10, y: c.y + drop * 0.55)
            c2 = CGPoint(x: x, y: to.y - drop * 0.45)
        case .side(let margin):
            to = CGPoint(x: size.width + margin, y: min(c.y + cellHeight, size.height))
            let run = to.x - c.x
            c1 = CGPoint(x: c.x + run * 0.2, y: c.y + cellHeight * 1.1)
            c2 = CGPoint(x: to.x - run * 0.4, y: to.y + 6)
        }
        return (0...24).map { i in
            let u = CGFloat(i) / 24, v = 1 - u
            return CGPoint(x: v * v * v * c.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * to.x,
                           y: v * v * v * c.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * to.y)
        }
    }

    // MARK: Inhalt

    /// Nur einzelne Tage bekommen Punkte, Mehrtägiges liegt als Band dahinter.
    private func dotsByDay() -> [Day: [EntryKind]] {
        var out: [Day: [EntryKind]] = [:]
        for e in entries where !e.isPeriod && e.spanDays == 1 && e.start >= first && e.start <= last {
            if !(out[e.start]?.contains(e.kind) ?? false) { out[e.start, default: []].append(e.kind) }
        }
        return out
    }

    private func bandedDays() -> Set<Day> {
        var out = Set<Day>()
        for e in entries where !e.isPeriod && e.spanDays > 1 && e.end >= first && e.start <= last {
            var d = max(e.start, first)
            while d <= min(e.end, last) { out.insert(d); d = d.adding(days: 1) }
        }
        return out
    }

    private func accessibility(_ day: Day, dots: [EntryKind]) -> String {
        var s = day.longText
        if day == today { s = String(localized: "Heute, ") + s }
        if !dots.isEmpty { s += ", \(dots.count == 1 ? "ein Termin" : "Termine")" }
        return s
    }
}
