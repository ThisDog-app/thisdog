import SwiftUI

/// Was der Hund am Tag braucht: Futter, Leckerli, Wasser. Rechnet mit dem Profil.
struct FeedingSection: View {
    @Environment(DogStore.self) private var store

    var body: some View {
        if store.profile.weightKg == nil {
            Text("Futter und Wasser rechnet ThisDog aus dem Gewicht. Trag es zuerst ein.")
                .font(.subheadline).foregroundStyle(Palette.ink2)
        } else {
            VStack(alignment: .leading, spacing: 36) { food; treats; water; footnote }
        }
    }

    private var useTarget: Bool {
        let p = store.profile
        return store.settings.feedBasis == "target" && p.targetWeightKg != nil && p.targetWeightKg != p.weightKg
    }

    private var energy: Calc.Energy? { Calc.energy(store.profile, useTarget: useTarget) }

    // MARK: Futter

    private var food: some View {
        let s = store.settings
        let e = energy
        let grams = e.flatMap { Calc.grams(kcal: $0.kcal, kcalPer100g: s.kcalPer100g) }
        return VStack(alignment: .leading, spacing: 22) {
            Text("Futtermenge").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(grams.map { Self.n0($0) } ?? "–")
                        .font(.display(96, weight: .bold, width: 75)).foregroundStyle(Palette.accent)
                        .contentTransition(.numericText()).monospacedDigit()
                    Text("g am Tag").font(.display(22, weight: .medium)).foregroundStyle(Palette.ink)
                }
                if let grams, s.meals > 1 {
                    Text("\(s.meals) × \(Self.n0(grams / Double(s.meals))) g")
                        .font(.display(28, weight: .semibold, width: 80)).foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                }
            }
            .animation(.snappy, value: grams)

            VStack(alignment: .leading, spacing: 10) {
                Text("Futter").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
                HStack(spacing: 8) {
                    ForEach(Calc.foodKinds, id: \.0) { kind in
                        chip(kind.0, selected: s.kcalPer100g == kind.1) { update { $0.kcalPer100g = kind.1 } }
                    }
                }
                HStack {
                    Text("Energie je 100 g").foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(Self.n0(s.kcalPer100g)) kcal").monospacedDigit().foregroundStyle(Palette.ink)
                    Stepper("Energie je 100 g", value: Binding(get: { s.kcalPer100g }, set: { v in update { $0.kcalPer100g = v } }),
                            in: 30...600, step: 5).labelsHidden()
                }
                Text("Steht auf der Verpackung, oft als „umsetzbare Energie“.").font(.caption).foregroundStyle(Palette.ink3)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Mahlzeiten am Tag").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
                Picker("Mahlzeiten am Tag", selection: Binding(get: { s.meals }, set: { v in update { $0.meals = v } })) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }

            let p = store.profile
            if let target = p.targetWeightKg, let now = p.weightKg, target != now {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Rechnen mit").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
                    Picker("Rechnen mit", selection: Binding(get: { useTarget ? "target" : "current" }, set: { v in update { $0.feedBasis = v } })) {
                        Text("Gewicht \(DogScreen.kg(now)) kg").tag("current")
                        Text("Wunsch \(DogScreen.kg(target)) kg").tag("target")
                    }
                    .pickerStyle(.segmented)
                    if useTarget {
                        Text("Abnehmen gehört tierärztlich begleitet: Zu schnell schadet.").font(.caption).foregroundStyle(Palette.ink3)
                    }
                }
            }

            if let e {
                Text("Grundumsatz \(Self.n0(e.rer)) kcal × Faktor \(Self.n1(e.factor.value)) (\(e.factor.note)) = \(Self.n0(e.kcal)) kcal, gerechnet auf \(DogScreen.kg(e.kg)) kg.")
                    .font(.footnote).foregroundStyle(Palette.ink2)
            }
        }
        .sensoryFeedback(.selection, trigger: s)
    }

    private func update(_ change: (inout ToolSettings) -> Void) {
        var s = store.settings
        change(&s)
        store.save(s)
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? Palette.accent : Palette.ink)
                .background(selected ? Palette.soft : Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Palette.accent.opacity(0.4) : Palette.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Leckerli

    @ViewBuilder
    private var treats: some View {
        if let e = energy {
            let t = Calc.treats(kcal: e.kcal)
            VStack(alignment: .leading, spacing: 14) {
                Text("Leckerli").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    big(Self.n0(t.kcal), String(localized: "kcal am Tag"))
                    big(Self.n0(t.grams), String(localized: "g Trockenleckerli"))
                }
                // Der Tag als Streifen: neun Teile Hauptfutter, ein Teil Leckerli.
                GeometryReader { g in
                    HStack(spacing: 3) {
                        Capsule().fill(Palette.line).frame(width: (g.size.width - 3) * 0.9)
                        Capsule().fill(Palette.accent)
                    }
                }
                .frame(height: 10)
                Text("Höchstens ein Zehntel der Tagesenergie, sonst kippt die Nährstoffbilanz des Hauptfutters.")
                    .font(.footnote).foregroundStyle(Palette.ink2)
            }
        }
    }

    // MARK: Wasser

    @ViewBuilder
    private var water: some View {
        if let kg = store.profile.weightKg {
            let w = Calc.water(kg)
            VStack(alignment: .leading, spacing: 10) {
                Text("Wasser").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
                big(String(localized: "\(Self.n0(w.lowerBound)) bis \(Self.n0(w.upperBound))"), String(localized: "ml am Tag"))
                Text("Bei Hitze, Sport oder Trockenfutter mehr. Deutlich mehr Trinken über Tage gehört in der Praxis abgeklärt.")
                    .font(.footnote).foregroundStyle(Palette.ink2)
            }
        }
    }

    private var footnote: some View {
        Text("Richtwerte für gesunde Hunde. Bei Krankheit, Trächtigkeit oder Diät gilt die Empfehlung der Tierarztpraxis.")
            .font(.caption).foregroundStyle(Palette.ink3)
    }

    private func big(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.display(36, weight: .bold, width: 75)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(unit).font(.footnote).foregroundStyle(Palette.ink2)
        }
    }

    static func n0(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0)).locale(AppLocale.current)) }
    static func n1(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2)).locale(AppLocale.current)) }
}

/// Die Temperatur des Belags auf einer Linie von 20 bis 80 °C, mit den Grenzen 43 und 52 °C.
private struct AsphaltLine: View {
    let surface: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            let x = { (t: Double) in CGFloat((min(80, max(20, t)) - 20) / 60) * g.size.width }
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line).frame(height: 4).offset(y: 0)
                ForEach([43.0, 52.0], id: \.self) { t in
                    Rectangle().fill(Palette.ink3).frame(width: 1.5, height: 14).offset(x: x(t))
                    Text("\(Int(t))°").font(.caption2).foregroundStyle(Palette.ink3).offset(x: x(t) - 8, y: 16)
                }
                Circle().fill(color).frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .offset(x: x(surface) - 8)
                    .animation(.snappy, value: surface)
            }
            .frame(height: 20)
        }
        .frame(height: 36)
        .accessibilityHidden(true)
    }
}

/// Wie heiß der Belag gerade ist: die Frage vor dem Rausgehen. Nur mit echtem Wetter – eine geschätzte Zahl ohne
/// Sonne und Wolken stimmt im Herbst nicht und im Sommer nur mittags, deshalb gibt es ohne Wetter keine.
struct AsphaltSection: View {
    @Environment(HeatService.self) private var heat

    var body: some View {
        // Die Sonne wandert: alle paar Minuten neu rechnen.
        TimelineView(.periodic(from: .now, by: 300)) { ctx in
            if let air = heat.current, let c = heat.conditions, let surface = heat.surface(at: ctx.date) {
                content(air: air, surface: surface, reason: Asphalt.reason(c, at: ctx.date))
            }
        }
        // Das Wetter holen, wenn es fehlt oder alt ist.
        .task {
            if let spot = LastPlace.load() { await heat.refresh(at: spot) }
        }
    }

    private func content(air: Double, surface: Double, reason: String) -> some View {
        let paws = Calc.paws(surface: surface)
        let color: Color = switch paws { case .ok: Palette.kind(.seasonal); case .warn: Palette.kind(.warning); case .bad: Palette.kind(.health) }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Asphalt").font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(Self.n0(surface)) °C").font(.display(36, weight: .bold, width: 75)).foregroundStyle(color)
                    .contentTransition(.numericText()).monospacedDigit()
                VStack(alignment: .leading, spacing: 0) {
                    Text(paws.label).font(.headline).foregroundStyle(color)
                    Text("Belag jetzt bei \(Self.n0(air)) °C Luft, \(reason)")
                        .font(.subheadline).foregroundStyle(Palette.ink2)
                }
            }
            .animation(.snappy, value: Int(surface))
            AsphaltLine(surface: surface, color: color)
            Text(Self.advice(paws)).font(.footnote).foregroundStyle(Palette.ink2)
            WeatherCredit()
        }
    }

    static func advice(_ p: Calc.Paws) -> String { Asphalt.advice(p) }

    private static func n0(_ v: Double) -> String { FeedingSection.n0(v) }
}
