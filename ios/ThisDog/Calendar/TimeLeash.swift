import SwiftUI

/// Wo auf der Zeitleine was liegt. Getrennt von der Darstellung, damit es sich prüfen lässt.
///
/// Der Abstand folgt der Zeit (`pointsPerDay`), wird aber nie enger, als ein Knoten Platz braucht.
/// Wird ein Abstand dadurch größer als maßstäblich, bleibt die Zeit trotzdem lesbar: An Lücken ab
/// `gapLabelDays` Tagen steht ihre Länge.
struct LeashLayout {
    struct Node: Identifiable {
        let day: Day
        let entries: [CalendarEntry]
        let y: CGFloat
        let height: CGFloat
        var id: String { day.iso }
    }

    struct Gap {
        let days: Int
        let y: CGFloat
    }

    struct Span {
        let kind: EntryKind
        let from: CGFloat
        let to: CGFloat
    }

    let nodes: [Node]
    let gaps: [Gap]
    let spans: [Span]
    let height: CGFloat

    static let gapLabelDays = 4

    init(start: Day, entries: [CalendarEntry], pointsPerDay: CGFloat, dateHeight: CGFloat, rowHeight: CGFloat,
         spacing: CGFloat, maxNodes: Int = 10) {
        var byDay = Dictionary(grouping: entries.filter { $0.start >= start }, by: \.start)
        // Was vorher begonnen hat und noch läuft (Weihnachten am 25.), hängt am ersten Knoten.
        let running = entries.filter { $0.start < start && $0.end >= start }
        if !running.isEmpty { byDay[start] = running + (byDay[start] ?? []) }
        var days = byDay.keys.sorted()
        // Der Anfang der Leine ist immer ein Knoten – auch ohne Termin, damit man dort einen anlegen kann.
        if days.first != start { days.insert(start, at: 0) }
        days = Array(days.prefix(maxNodes))

        var nodes: [Node] = []
        for day in days {
            let list = byDay[day] ?? []
            let h = dateHeight + rowHeight * CGFloat(max(1, list.count))
            let wanted = CGFloat(start.days(until: day)) * pointsPerDay
            let y = nodes.last.map { max(wanted, $0.y + $0.height + spacing) } ?? 0
            nodes.append(Node(day: day, entries: list, y: y, height: h))
        }

        // Tag → Höhe, stückweise zwischen den Knoten; dahinter maßstäblich weiter.
        func yOf(_ d: Day) -> CGFloat {
            guard let first = nodes.first else { return 0 }
            if d <= first.day { return 0 }
            for (a, b) in zip(nodes, nodes.dropFirst()) where d <= b.day {
                let t = CGFloat(a.day.days(until: d)) / CGFloat(max(1, a.day.days(until: b.day)))
                return a.y + (b.y - a.y) * t
            }
            let last = nodes.last!
            return last.y + CGFloat(last.day.days(until: d)) * pointsPerDay
        }

        var gaps: [Gap] = []
        var lastEnd: Day?
        var lastY: CGFloat = 0
        for n in nodes {
            if let lastEnd {
                let d = lastEnd.days(until: n.day)
                if d >= Self.gapLabelDays { gaps.append(Gap(days: d, y: (lastY + n.y) / 2)) }
            }
            lastEnd = max(n.day, n.entries.map(\.end).max() ?? n.day)
            lastY = n.y
        }

        let spans = nodes.flatMap { n in
            n.entries.filter { $0.spanDays > 1 }.map { e in Span(kind: e.kind, from: n.y, to: max(n.y + 8, yOf(e.end))) }
        }

        self.nodes = nodes
        self.gaps = gaps
        self.spans = spans
        self.height = max(nodes.last.map { $0.y + $0.height } ?? 0, spans.map(\.to).max() ?? 0)
    }
}

/// Die Zeitleine: eine locker hängende Leine, an der die Termine wie Knoten sitzen. In langen Pausen
/// macht sie eine Schlinge. Mehrtägiges liegt als breites, weiches Band auf derselben Linie.
struct TimeLeash: View {
    /// Woher die Leine kommt.
    enum Entry {
        /// Von oben, wo der Monat direkt darüber liegt.
        case top
        /// Von der Seite, aus dem Monat in der anderen Spalte, auf der Höhe `y`.
        case side(margin: CGFloat, y: CGFloat)
    }

    static let lineX: CGFloat = 54

    let start: Day
    let entries: [CalendarEntry]
    var entry: Entry = .top
    var onSelect: (CalendarEntry) -> Void
    var onAdd: (Day) -> Void
    /// Wer den Termin eingetragen hat, wenn es jemand anderes im Rudel war.
    var author: (CalendarEntry) -> (name: String, image: UIImage?)? = { _ in nil }

    @ScaledMetric(relativeTo: .footnote) private var dateHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 46
    @State private var drawn: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let textX: CGFloat = 84
    /// Platz über dem ersten Knoten, in dem die Leine ankommt.
    private let lead: CGFloat = 22

    var body: some View {
        let layout = LeashLayout(start: start, entries: entries.filter { !$0.isPeriod }, pointsPerDay: 13,
                                 dateHeight: dateHeight, rowHeight: rowHeight, spacing: 18)
        ZStack(alignment: .topLeading) {
            LeashShape(points: points(layout))
                .trim(from: 0, to: drawn)
                .stroke(Palette.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .accessibilityHidden(true)
            if case .side(let margin, let from) = entry {
                LeashBranch(from: CGPoint(x: -margin, y: from), to: join(from: from))
                    .stroke(Palette.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .accessibilityHidden(true)
            }
            Canvas { ctx, _ in draw(layout, in: &ctx) }
                .accessibilityHidden(true)
                .transaction { $0.animation = nil }
            ForEach(layout.nodes) { node in
                nodeView(node)
                    .padding(.leading, textX)
                    .offset(y: lead + node.y)
            }
            .transaction { $0.animation = nil }
            ForEach(Array(layout.gaps.enumerated()), id: \.offset) { _, g in
                Text("\(g.days) Tage")
                    .font(.caption2)
                    .foregroundStyle(Palette.ink3)
                    .frame(width: Self.lineX - 16, alignment: .trailing)
                    .offset(y: lead + g.y + dateHeight / 2 + 6)
                    .accessibilityHidden(true)
            }
            .transaction { $0.animation = nil }
        }
        .frame(height: lead + layout.height + 8, alignment: .top)
        .onChange(of: start) {
            guard !reduceMotion else { return }
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { drawn = 0 }
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.6)) { drawn = 1 } }
        }
    }

    // MARK: Zeichnen

    /// Wie weit die Leine bei dieser Höhe von der Mitte abweicht. Fest, damit sie beim Blättern nicht zappelt.
    private func x(_ y: CGFloat, fade: Bool = true) -> CGFloat {
        let swing = sin(y / 47 + 0.8) * 3.6 + sin(y / 113 + 2.1) * 3.2
        // Quadratisch: Oben läuft sie senkrecht los, ohne Knick zur Linie aus dem Monat.
        let ease = min(1, y / 70)
        return Self.lineX + swing * (fade ? ease * ease : 1)
    }

    /// Wo die Linie aus dem Monat in die Zeitleine mündet: von oben, nie gegen die Laufrichtung.
    private func join(from: CGFloat) -> CGPoint {
        let y = max(lead + dateHeight / 2, from + 40)
        return CGPoint(x: x(y), y: y)
    }

    private func points(_ layout: LeashLayout) -> [CGPoint] {
        var out: [CGPoint] = []
        // Mit Linie aus der anderen Spalte beginnt die Zeitleine erst am ersten Knoten.
        if case .side = entry { out.append(CGPoint(x: x(lead + dateHeight / 2), y: lead + dateHeight / 2)) }
        let loops = layout.gaps.filter { $0.days >= 7 }.map { lead + $0.y + dateHeight / 2 + 4 }
        let end = lead + layout.height
        var y: CGFloat = out.last.map { $0.y + 14 } ?? 0
        var done = Set<Int>()
        while y <= end {
            if let i = loops.firstIndex(where: { abs($0 - y) < 16 }) {
                if !done.contains(i) {
                    done.insert(i)
                    let c = CGPoint(x: x(loops[i]), y: loops[i])
                    out += LeashShape.loop(center: c, along: CGVector(dx: 0, dy: 1), radius: 7, side: -1)
                }
            } else {
                out.append(CGPoint(x: x(y), y: y))
            }
            y += 14
        }
        return out
    }

    private func draw(_ layout: LeashLayout, in ctx: inout GraphicsContext) {
        for s in layout.spans {
            let from = lead + s.from + dateHeight / 2, to = lead + s.to + dateHeight / 2
            var pts: [CGPoint] = []
            var y = from
            while y < to { pts.append(CGPoint(x: x(y), y: y)); y += 8 }
            pts.append(CGPoint(x: x(to), y: to))
            ctx.stroke(LeashShape.curve(pts), with: .color(Palette.kind(s.kind).opacity(0.2)),
                       style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        }
        for n in layout.nodes {
            let cy = lead + n.y + dateHeight / 2, cx = x(cy)
            if n.day == .today {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12)), with: .color(Palette.accent))
            } else {
                let color = n.entries.first.map { Palette.kind($0.kind) } ?? Palette.ink3
                let r = CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10)
                ctx.fill(Path(ellipseIn: r), with: .color(Palette.paper))
                ctx.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 1.8)
            }
        }
    }

    // MARK: Knoten

    private func nodeView(_ node: LeashLayout.Node) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dateLabel(node.day))
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.ink3)
                .frame(height: dateHeight, alignment: .center)
            if node.entries.isEmpty {
                Button {
                    onAdd(node.day)
                } label: {
                    Label("Termin anlegen", icon: "plus")
                        .font(.body)
                        .foregroundStyle(Palette.accent)
                }
                .frame(height: rowHeight, alignment: .center)
            }
            ForEach(node.entries) { e in
                Button {
                    onSelect(e)
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.plainTitle)
                                .font(.display(17, weight: .medium, relativeTo: .body))
                                .foregroundStyle(e.isEditable ? Palette.ink : Palette.ink2)
                            if !meta(e).isEmpty {
                                Text(meta(e)).font(.footnote).foregroundStyle(Palette.ink2)
                            }
                        }
                        Spacer(minLength: 0)
                        if let who = author(e) {
                            AvatarView(image: who.image, name: who.name, size: 22)
                                .accessibilityLabel("eingetragen von \(who.name)")
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!e.isEditable)
                .accessibilityLabel("\(dateLabel(node.day)), \(e.plainTitle), \(meta(e))")
            }
        }
    }

    /// Wann der Termin ist: Wochentag, Datum und, wenn es eine gibt, die Uhrzeit.
    static func dateLine(_ e: CalendarEntry) -> String {
        let day = "\(Day.weekdayShort[e.start.weekdayFromMonday]) \(e.start.shortText)"
        return [day, e.timeText, e.untilText].compactMap { $0 }.joined(separator: ", ")
    }

    private func dateLabel(_ d: Day) -> String {
        let n = Day.today.days(until: d)
        switch n {
        case 0: return String(localized: "Heute")
        case 1: return String(localized: "Morgen")
        case 2: return String(localized: "Übermorgen")
        default:
            let wd = Day.weekdayShort[d.weekdayFromMonday]
            return "\(wd) \(d.shortText)"
        }
    }

    private func meta(_ e: CalendarEntry) -> String {
        var parts: [String] = []
        if let t = e.timeText { parts.append(t) }
        if let u = e.untilText { parts.append(u) }
        if let r = e.repetition { parts.append(r.label.lowercasedFirst) }
        if parts.isEmpty, !e.isEditable { parts.append(e.kind.label) }
        return parts.joined(separator: ", ")
    }
}

/// Die Linie aus dem Monat in der anderen Spalte: läuft waagerecht los und mündet senkrecht in die Zeitleine.
private struct LeashBranch: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addCurve(to: to, control1: CGPoint(x: from.x + (to.x - from.x) * 0.7, y: from.y),
                   control2: CGPoint(x: to.x, y: to.y - abs(to.y - from.y) * 0.6 - 10))
        return p
    }
}
