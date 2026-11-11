import SwiftUI

/// „Draußen“ auf der Startseite: wie es jetzt ist, was die nächste Stunde bringt und wie warm der Belag ist.
/// Nur mit echtem Wetter; ohne bleibt der Platz leer.
struct OutsideBlock: View {
    @Environment(HeatService.self) private var heat
    @Environment(Router.self) private var router

    var body: some View {
        TimelineView(.periodic(from: .now, by: 300)) { ctx in
            if let air = heat.current, let c = heat.conditions, let surface = heat.surface(at: ctx.date) {
                content(air: air, conditions: c, surface: surface, now: ctx.date)
            }
        }
        .task {
            if let spot = LastPlace.load() { await heat.refresh(at: spot) }
        }
    }

    private func content(air: Double, conditions c: Asphalt.Conditions, surface: Double, now: Date) -> some View {
        let paws = Asphalt.paws(surface: surface)
        let color: Color = switch paws { case .ok: Palette.kind(.seasonal); case .warn: Palette.kind(.warning); case .bad: Palette.kind(.health) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Draußen").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
            Button { router.tab = .gassi } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: heat.sky?.symbol ?? "cloud.sun")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Palette.accent)
                            .font(.system(size: 30))
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(heat.sky.map { "\(Self.n0(air)) °C, \($0.text)" } ?? "\(Self.n0(air)) °C")
                                .font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                            if let next = heat.nextHour {
                                Text(Self.forecast(next, now: now)).font(.subheadline).foregroundStyle(Palette.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        LineIcon("chevron-rechts", size: 16).foregroundStyle(Palette.ink3)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(color).frame(width: 10, height: 10)
                        Text("Asphalt etwa \(Self.n0(surface)) °C").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text(paws.label).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                    }
                    if paws != .ok {
                        Text(Asphalt.advice(paws)).font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Öffnet Gassi"))
            WeatherCredit()
        }
    }

    /// „Die nächste Stunde bleibt trocken. Dann 6 °C.“
    static func forecast(_ next: NextHour, now: Date) -> String {
        let line = next.line(now: now)
        guard let t = next.temperature else { return line }
        return line + " " + String(localized: "Dann \(n0(t)) °C.")
    }

    private static func n0(_ v: Double) -> String { FeedingSection.n0(v) }
}
