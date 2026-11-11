import CoreLocation
import SwiftUI
import WeatherKit

/// Wie warm es gerade ist, für die Hitzewarnung vor der Runde. Kommt von Apple Wetter, höchstens alle
/// halbe Stunde und nur neu, wenn man weit gefahren ist. Ohne Wetter (kein Netz, WeatherKit aus) bleibt
/// es still – dann gibt es eben keine Warnung, nur den Rechner.
@MainActor
@Observable
final class HeatService {
    private(set) var air: Double?
    private(set) var daylight = true
    /// Alles, was der Belag braucht: Luft, Wolken, Wind und wo.
    private(set) var conditions: Asphalt.Conditions?
    /// Wie es gerade ist („Bewölkt“) und das passende SF-Symbol.
    private(set) var sky: (text: String, symbol: String)?
    /// Was die nächste Stunde bringt.
    private(set) var nextHour: NextHour?
    private(set) var at: Date?
    /// Apples Bedingung für die Wetterdaten: Hinweis auf Apple Wetter mit Link zu den Rechtsangaben.
    private(set) var legalPage: URL?

    @ObservationIgnored private var spot: CLLocation?
    @ObservationIgnored private var loading = false

    init() {
        #if DEBUG
        // Zum Ansehen ohne Wetter: `-hitze 33`.
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-hitze"), i + 1 < a.count, let t = Double(a[i + 1]) {
            air = t; at = Date()
            conditions = .init(air: t, cloud: 0, wind: 2, lat: 48.21, lon: 16.37)
            sky = ("Heiter", "sun.max.fill")
            let now = Date()
            nextHour = NextHour(now: now, minutes: nil,
                                hours: [.init(date: now.addingTimeInterval(1800), chance: 0.1, snow: false, temperature: t + 1)], raining: false)
        }
        #endif
    }

    /// Die Temperatur, solange sie höchstens zwei Stunden alt ist – älter gilt nicht mehr als „jetzt“.
    var current: Double? {
        guard let air, let at, Date().timeIntervalSince(at) < 2 * 3600 else { return nil }
        return air
    }

    /// Wie warm der Belag jetzt etwa ist; `nil` ohne aktuelles Wetter.
    func surface(at date: Date = Date()) -> Double? {
        guard current != nil, let conditions else { return nil }
        return Asphalt.surface(conditions, at: date)
    }

    var warning: Asphalt.Paws? {
        guard current != nil, let conditions else { return nil }
        return Asphalt.warning(conditions, at: Date())
    }

    /// Holt das Wetter, wenn es alt ist oder man weit weg ist. Gibt zurück, ob es neu ist.
    @discardableResult
    func refresh(at c: CLLocationCoordinate2D) async -> Bool {
        // Auf etwa einen Kilometer gerundet: Für die Temperatur genügt das, und Apple erfährt nicht, wo genau man ist.
        let here = CLLocation(latitude: (c.latitude * 100).rounded() / 100, longitude: (c.longitude * 100).rounded() / 100)
        if loading { return false }
        if let at, Date().timeIntervalSince(at) < 30 * 60, let spot, spot.distance(from: here) < 5000 { return false }
        loading = true
        defer { loading = false }
        guard let (w, hours, minutes) = try? await WeatherService.shared.weather(for: here, including: .current, .hourly, .minute)
        else { return false }
        sky = (w.condition.description, w.symbolName)
        nextHour = NextHour(now: Date(),
                            minutes: minutes?.forecast.map { .init(date: $0.date, chance: $0.precipitationChance, intensity: $0.precipitationIntensity.value) },
                            hours: hours.forecast.map { .init(date: $0.date, chance: $0.precipitationChance, snow: $0.precipitation == .snow,
                                                              temperature: $0.temperature.converted(to: .celsius).value) },
                            raining: w.precipitationIntensity.value > 0.1)
        let t = w.temperature.converted(to: .celsius).value
        air = t
        daylight = w.isDaylight
        conditions = .init(air: t, cloud: w.cloudCover, wind: w.wind.speed.converted(to: .metersPerSecond).value,
                           lat: here.coordinate.latitude, lon: here.coordinate.longitude)
        at = Date()
        spot = here
        if legalPage == nil { legalPage = try? await WeatherService.shared.attribution.legalPageURL }
        return true
    }
}

/// Der Hinweis vor dem Losgehen, nur wenn es für die Pfoten knapp wird.
struct HeatBanner: View {
    @Environment(HeatService.self) private var heat

    var body: some View {
        if let paws = heat.warning, let air = heat.air, let surface = heat.surface() {
            let color = paws == .bad ? Palette.kind(.health) : Palette.kind(.warning)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LineIcon("sonne", size: 20).foregroundStyle(color)
                    Text("\(Int(air.rounded())) °C – Asphalt etwa \(Int(surface.rounded())) °C")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                }
                Text(Asphalt.advice(paws)).font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                WeatherCredit()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}

/// „Wetter:  Wetter“ mit Link – überall, wo Werte von Apple Wetter stehen.
struct WeatherCredit: View {
    @Environment(HeatService.self) private var heat

    var body: some View {
        if let url = heat.legalPage {
            Link(destination: url) {
                Text("Wetterdaten:  Wetter").font(.caption2).foregroundStyle(Palette.ink3).underline()
            }
        }
    }
}

/// Die nächste Stunde in einem Satz: Regen, ja oder nein, und wann. Mit Minutenvorhersage, wo Apple sie hat,
/// sonst aus der Stundenvorhersage.
struct NextHour: Equatable, Sendable {
    struct Minute: Equatable, Sendable { var date: Date; var chance: Double; var intensity: Double }
    struct Hour: Equatable, Sendable { var date: Date; var chance: Double; var snow: Bool; var temperature: Double }

    /// Ab wann es regnet (oder aufhört), `nil`: bleibt, wie es ist.
    var change: Date?
    /// Regnet es gerade?
    var raining: Bool
    /// Wahrscheinlichkeit für Niederschlag in der nächsten Stunde (0…1).
    var chance: Double
    var snow: Bool
    /// Temperatur in einer Stunde.
    var temperature: Double?
    /// Wann das galt.
    var at: Date

    init(now: Date, minutes: [Minute]?, hours: [Hour], raining: Bool) {
        at = now
        self.raining = raining
        let hour = hours.first { $0.date > now }
        // Die laufende Stunde (beginnt vor jetzt) und die nächste zählen.
        let window = hours.filter { $0.date > now.addingTimeInterval(-3600) && $0.date <= now.addingTimeInterval(3600) }
        snow = window.contains { $0.snow }
        temperature = hour?.temperature
        if let minutes, !minutes.isEmpty {
            let ahead = minutes.filter { $0.date > now && $0.date <= now.addingTimeInterval(3600) }
            let wet = { (m: Minute) in m.chance >= 0.5 && m.intensity > 0.1 }
            change = raining ? ahead.first { !wet($0) }?.date : ahead.first(where: wet)?.date
            chance = ahead.map(\.chance).max() ?? 0
        } else {
            change = nil
            chance = window.map(\.chance).max() ?? 0
        }
    }

    /// „Ab etwa 14:20 Regen.“ / „Die nächste Stunde bleibt trocken.“
    func line(now: Date = Date()) -> String {
        let what = snow ? String(localized: "Schnee") : String(localized: "Regen")
        if let change {
            let t = change.formatted(.dateTime.hour().minute())
            return raining ? String(localized: "\(what) hört gegen \(t) auf.") : String(localized: "Ab etwa \(t) \(what).")
        }
        if raining { return String(localized: "\(what) hält die nächste Stunde an.") }
        let p = Int((chance * 100 / 10).rounded()) * 10
        if chance >= 0.5 { return String(localized: "\(what) wahrscheinlich, \(p) %.") }
        if chance >= 0.2 { return String(localized: "Vielleicht ein paar Tropfen, \(p) %.") }
        return String(localized: "Die nächste Stunde bleibt trocken.")
    }
}
