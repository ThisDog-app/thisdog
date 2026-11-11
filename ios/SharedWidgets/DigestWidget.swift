import SwiftUI
import WidgetKit

/// Widget (iPhone) und Komplikation (Watch): die Woche auf einen Blick, dazu Hitze oder was beim Hund ansteht.
/// Liegt in beiden Erweiterungen; die Daten legt die jeweilige App in der App-Gruppe ab (`DigestShelf`).
struct DigestEntry: TimelineEntry {
    let date: Date
    let digest: WatchLink.Digest
}

struct DigestProvider: TimelineProvider {
    func placeholder(in context: Context) -> DigestEntry { DigestEntry(date: .now, digest: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (DigestEntry) -> Void) {
        let d = DigestShelf.load()
        completion(DigestEntry(date: .now, digest: context.isPreview && d.weekWalks == 0 ? Self.sample : d))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DigestEntry>) -> Void) {
        let now = Date.now
        // Um Mitternacht beginnt vielleicht eine neue Woche, und „in 3 Tagen“ wird zu „in 2 Tagen“.
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400 + 60)
        completion(Timeline(entries: [DigestEntry(date: now, digest: DigestShelf.load())], policy: .after(min(midnight, now.addingTimeInterval(3600)))))
    }

    static let sample: WatchLink.Digest = {
        var d = WatchLink.Digest()
        d.dogName = String(localized: "Stella")
        d.weekMeters = 12_400
        d.weekWalks = 6
        return d
    }()
}

private let mandarine = Color(red: 0xEE / 255, green: 0x6A / 255, blue: 0x24 / 255)

struct DigestWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "thisdog.woche", provider: DigestProvider()) { entry in
            DigestWidgetView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Gassi diese Woche")
        .description("Strecke der Woche, Hitze und was beim Hund ansteht.")
        #if os(watchOS)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        #endif
    }
}

struct DigestWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DigestEntry

    private var d: WatchLink.Digest { entry.digest }
    private var km: String { WalkText.km(d.weekMeters) }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(km) km diese Woche", systemImage: "pawprint.fill")
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: d.heat(at: entry.date) != nil ? "sun.max.fill" : "pawprint.fill").font(.caption)
                Text(km).font(.system(.headline, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6)
                Text("km").font(.caption2)
            }
            .widgetAccentable()
        #if os(watchOS)
        case .accessoryCorner:
            Image(systemName: "pawprint.fill").font(.title3).widgetAccentable()
                .widgetLabel { Text("\(km) km") }
        #endif
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Diese Woche", systemImage: "pawprint.fill").font(.caption2.weight(.semibold)).widgetAccentable()
                Text("\(km) km").font(.system(.headline, design: .rounded)).monospacedDigit()
                Text(note ?? walksLine).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                week
                VStack(alignment: .leading, spacing: 8) {
                    if let heat { heatView(heat) }
                    if let due = d.dues.first { dueView(due) }
                    if heat == nil && d.dues.isEmpty { Text(walksLine).font(.subheadline).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                week
                Spacer(minLength: 0)
                if let note { Text(note).font(.caption.weight(.semibold)).foregroundStyle(heat != nil ? .red : mandarine).lineLimit(2) }
            }
        }
    }

    private var heat: Asphalt.Paws? { d.heat(at: entry.date) }

    private var walksLine: String {
        d.weekWalks == 1 ? String(localized: "1 Runde seit Montag") : String(localized: "\(d.weekWalks) Runden seit Montag")
    }

    /// Das Wichtigste neben der Strecke: erst Hitze, dann die nächste Fälligkeit.
    private var note: String? {
        if heat != nil, let air = d.air { return String(localized: "\(Int(air.rounded())) °C – Asphalt heiß") }
        if let due = d.dues.first { return Self.dueLine(due, now: entry.date) }
        return nil
    }

    private var week: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(d.dogName.isEmpty ? String(localized: "Gassi") : d.dogName, systemImage: "pawprint.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(mandarine)
            Text(km).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6)
            Text("km diese Woche").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func heatView(_ p: Asphalt.Paws) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("\(Int((d.air ?? 0).rounded())) °C", systemImage: "sun.max.fill").font(.subheadline.weight(.semibold))
                .foregroundStyle(p == .bad ? .red : .orange)
            Text("Asphalt etwa \(Int((d.surface(at: entry.date) ?? 0).rounded())) °C").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func dueView(_ due: WatchLink.Digest.Due) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(due.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(Self.dueLine(due, now: entry.date)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    static func dueLine(_ due: WatchLink.Digest.Due, now: Date) -> String {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due.due)).day ?? 0
        if n < 0 { return String(localized: "\(due.kind), seit \(-n) Tagen fällig") }
        if n == 0 { return String(localized: "\(due.kind), heute fällig") }
        return n == 1 ? String(localized: "\(due.kind), in 1 Tag fällig") : String(localized: "\(due.kind), in \(n) Tagen fällig")
    }
}
