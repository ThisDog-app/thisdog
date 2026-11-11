import Charts
import SwiftUI

/// Der Hund: wer er ist und was er erlebt hat; darunter drei Reiter für den Überblick, die Gesundheit und das Futter.
struct DogScreen: View {
    @Environment(DogStore.self) private var store
    @Environment(Account.self) private var account
    @Environment(\.horizontalSizeClass) private var hClass
    /// Kompakt nur beim iPhone im Querformat: wenig Höhe, viel Breite.
    @Environment(\.verticalSizeClass) private var vClass
    @Environment(\.tabDockClearance) private var dockClearance

    @State private var reiter = DogScreen.startReiter
    @State private var editsProfile = false
    @State private var editing: HealthEditor.Item?
    @State private var addsWeight = false
    @State private var showsEmergency = ProcessInfo.processInfo.arguments.contains("-notfall")

    var body: some View {
        NavigationStack {
            Group {
                if !store.hasProfile {
                    empty
                } else if vClass == .compact {
                    landscape
                } else if hClass == .regular {
                    // Links, wer der Hund ist; rechts die Reiter.
                    FoldSplit {
                        ScrollView { who.padding(.horizontal, 32).padding(.vertical, 24) }
                    } trailing: {
                        VStack(spacing: 8) {
                            reiterLeiste.padding(.horizontal, 32).padding(.top, 24)
                            ScrollView { reiterContent.padding(.horizontal, 32).padding(.vertical, 16) }
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20, pinnedViews: .sectionHeaders) {
                            hero.padding(.horizontal, 20).padding(.top, 8)
                            Section {
                                VStack(alignment: .leading, spacing: 36) {
                                    reiterContent
                                    if reiter == .stella { extras }
                                }
                                .padding(.horizontal, 20).padding(.bottom, 24)
                            } header: {
                                reiterLeiste.padding(.horizontal, 20).padding(.vertical, 6).background(Palette.paper)
                            }
                        }
                    }
                }
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
            .clearsTabDock()
            #if DEBUG
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-hundfoto"), i + 1 < args.count, let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])) {
                    store.setAvatar(Avatar.dog, photo: data)
                }
            }
            #endif
            .sheet(isPresented: $editsProfile) { ProfileEditor(profile: store.profile) }
            .sheet(item: $editing) { HealthEditor(item: $0) }
            .sheet(isPresented: $addsWeight) { WeightEditor() }
            .ownView(isPresented: $showsEmergency, regular: hClass == .regular) { EmergencyPassScreen() }
        }
    }

    /// iPhones ohne Platz für die Leiste an der Seite: Sie liegt auch quer unten, die linke Spalte ist niedriger.
    private var tight: Bool { vClass == .compact && dockClearance > 0 }

    /// iPhone quer: Stella steht fest links, rechts laufen die Reiter an ihr vorbei.
    private var landscape: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView { who.padding(.vertical, 10) }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 320)
            VStack(spacing: 4) {
                reiterLeiste.padding(.top, 10)
                ScrollView { reiterContent.padding(.vertical, 10).padding(.bottom, 14) }
            }
        }
        .padding(.horizontal, 4)
    }

    /// Die feste Spalte in der Breite: Stella und die Wege zu Notfallpass und Rudel.
    private var who: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            extras
        }
    }

    // MARK: Reiter

    enum Reiter: String, CaseIterable, Identifiable {
        case stella, gesundheit, futter
        var id: String { rawValue }
    }

    private static var startReiter: Reiter {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-hundreiter"), i + 1 < args.count, let r = Reiter(rawValue: args[i + 1]) { return r }
        #endif
        return .stella
    }

    private func reiterTitle(_ r: Reiter) -> String {
        switch r {
        case .stella: store.profile.name
        case .gesundheit: String(localized: "Gesundheit")
        case .futter: String(localized: "Futter")
        }
    }

    private var reiterLeiste: some View {
        HStack(spacing: 2) {
            ForEach(Reiter.allCases) { r in
                ReiterButton(title: reiterTitle(r), on: reiter == r) {
                    withAnimation(.snappy) { reiter = r }
                }
            }
        }
        .padding(3)
        .background(Palette.surface, in: Capsule())
        .sensoryFeedback(.selection, trigger: reiter)
    }

    @ViewBuilder
    private var reiterContent: some View {
        switch reiter {
        case .stella:
            VStack(alignment: .leading, spacing: 36) {
                dueRings
                if vClass == .compact { weightSideBySide } else { weight }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .gesundheit:
            VStack(alignment: .leading, spacing: 36) {
                health
                HealthDiarySection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .futter:
            FeedingSection().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Wer ist dein Hund?").font(.display(44)).foregroundStyle(Palette.ink)
            Text("Name, Geburtstag und Gewicht genügen für den Anfang. Daraus entstehen Alter, Geburtstag im Kalender und die Futtermenge.")
                .font(.body).foregroundStyle(Palette.ink2)
            Button { editsProfile = true } label: { Text("Hund anlegen").font(.headline).frame(maxWidth: .infinity, minHeight: 34) }
                .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
            Spacer()
        }
        .frame(maxWidth: 520)
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    // MARK: Wer

    /// Wer Stella ist, und an der Leine, die an ihrem Foto hängt, was sie schon erlebt hat.
    private var hero: some View {
        let p = store.profile
        let who = [p.breed.isEmpty ? nil : p.breed, p.sexLabel].compactMap { $0 }.joined(separator: ", ")
        let age = [p.age(), p.stage()?.lowercased()].compactMap { $0 }.joined(separator: ", ")
        // Der Spruch ist eine Randnotiz: gleiche Schrift und gleiche Kante wie Rasse und Alter.
        let facts = [who.isEmpty ? nil : who, age.isEmpty ? nil : age, Self.funFact(for: p)].compactMap { $0 }
        let photo: CGFloat = tight ? 84 : vClass == .compact ? 92 : 112
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                AvatarPicker(id: Avatar.dog, size: photo, isDog: true, label: String(localized: "Foto von \(p.name)"))
                VStack(alignment: .leading, spacing: 4) {
                    // Nur der Name weicht dem Stift aus; darunter steht die volle Breite zur Verfügung.
                    Text(p.name).font(.display(vClass == .compact ? 32 : 40)).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .padding(.trailing, 44)
                    if !facts.isEmpty {
                        Text(facts.joined(separator: "\n")).font(.subheadline).foregroundStyle(Palette.ink2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topTrailing) {
                Button { editsProfile = true } label: {
                    LineIcon("stift", size: 24)
                        .foregroundStyle(Palette.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Profil bearbeiten"))
            }
            .zIndex(1)
            LeashTally(photo: photo, items: [
                (store.walks.count, String(localized: "Runden")),
                (Int((store.walks.reduce(0) { $0 + $1.meters } / 1000).rounded()), String(localized: "Kilometer")),
                (Revier(store.checkIns).spots.count, String(localized: "Orte")),
            ])
        }
    }

    /// Die Zeile zum Schmunzeln: der nahe Geburtstag, sonst das Alter in Menschenjahren.
    static func funFact(for p: DogProfile, on today: Day = .today) -> String? {
        guard let birth = p.birthDay, birth <= today else { return nil }
        var next = birth
        while next < today { next = next.adding(years: 1) }
        let days = today.days(until: next)
        if birth != today, days == 0 { return String(localized: "Heute ist Geburtstag! Alles Gute, \(p.name)!") }
        if birth != today, days == 1 { return String(localized: "Morgen ist Geburtstag. Schon was besorgt?") }
        if birth != today, days <= 60 { return String(localized: "Noch \(days) Tage bis zum Geburtstag.") }
        let years = humanYears(months: Double(birth.days(until: today)) / 30.44, weightKg: p.weightKg)
        return String(localized: "In Menschenjahren etwa \(years).")
    }

    /// Grobe Faustregel: Das erste Jahr zählt 15, das zweite 9, danach je nach Größe 4 bis 7.
    static func humanYears(months: Double, weightKg: Double?) -> Int {
        let perYear: Double = switch weightKg ?? 15 {
        case ..<11: 4
        case ..<26: 5
        default: 7
        }
        let years = months / 12
        let human = years <= 1 ? years * 15 : years <= 2 ? 15 + (years - 1) * 9 : 24 + (years - 2) * perYear
        return Int(human.rounded())
    }

    private func title(_ t: String) -> some View {
        Text(t).font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
    }

    // MARK: Was ansteht

    @ViewBuilder
    private var dueRings: some View {
        let today = Day.today
        let upcoming = store.dues.filter { $0.due >= today.adding(days: -60) }.prefix(3)
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                title(String(localized: "Was ansteht"))
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(upcoming)) { d in
                        DueRing(due: d, onDone: store.canMarkDone(d) ? { withAnimation(.snappy) { store.markDone(d.id) } } : nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(0..<(3 - upcoming.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }

    // MARK: Gewicht

    private var weightList: [WeightEntry] { store.weights.sorted { $0.d < $1.d } }

    /// Hochkant: Zahl über der Kurve.
    private var weight: some View {
        let list = weightList
        return VStack(alignment: .leading, spacing: 12) {
            weightHeader
            if let last = list.last {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    weightValue(last, size: 44)
                    if let trend = trend(list) { Text(trend).font(.subheadline).foregroundStyle(Palette.ink2) }
                }
                if list.count > 1 { weightChart(list).frame(height: 160) }
                weightTarget
            } else {
                weightEmpty
            }
        }
    }

    /// Quer: Zahl neben der Kurve, damit beide zugleich auf den niedrigen Bildschirm passen.
    private var weightSideBySide: some View {
        let list = weightList
        return VStack(alignment: .leading, spacing: 12) {
            weightHeader
            if let last = list.last {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        weightValue(last, size: 44)
                        if let trend = trend(list) { Text(trend).font(.footnote).foregroundStyle(Palette.ink2) }
                        weightTarget
                    }
                    .frame(width: 124, alignment: .leading)
                    if list.count > 1 { weightChart(list).frame(height: 120) }
                }
            } else {
                weightEmpty
            }
        }
    }

    private var weightHeader: some View {
        HStack {
            title(String(localized: "Gewicht"))
            Spacer()
            Button { addsWeight = true } label: {
                LineIcon("plus", size: 22).foregroundStyle(Palette.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Gewicht eintragen"))
        }
    }

    private func weightValue(_ last: WeightEntry, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.kg(last.kg)).font(.display(size, weight: .bold, width: 75)).foregroundStyle(Palette.ink)
            Text("kg").font(.display(22, weight: .medium)).foregroundStyle(Palette.ink2)
        }
    }

    @ViewBuilder
    private var weightTarget: some View {
        if let target = store.profile.targetWeightKg {
            Text("Wunschgewicht \(Self.kg(target)) kg").font(.footnote).foregroundStyle(Palette.ink3)
        }
    }

    private var weightEmpty: some View {
        Text("Noch kein Gewicht eingetragen.").font(.subheadline).foregroundStyle(Palette.ink3)
    }

    private func weightChart(_ list: [WeightEntry]) -> some View {
        Chart {
            if let target = store.profile.targetWeightKg {
                RectangleMark(yStart: .value("von", target * 0.97), yEnd: .value("bis", target * 1.03))
                    .foregroundStyle(Palette.soft)
            }
            ForEach(list, id: \.d) { w in
                LineMark(x: .value(String(localized: "Tag"), Day(iso: w.d)?.date ?? .now), y: .value("kg", w.kg))
                    .foregroundStyle(Palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = list.last, let d = Day(iso: last.d) {
                PointMark(x: .value(String(localized: "Tag"), d.date), y: .value("kg", last.kg)).foregroundStyle(Palette.accent).symbolSize(70)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
    }

    private func trend(_ list: [WeightEntry]) -> String? {
        guard list.count > 1, let last = list.last, let first = list.dropLast().last(where: { Day(iso: $0.d).map { $0 <= Day.today.adding(months: -1) } ?? false }) ?? list.first,
              first.d != last.d, let since = Day(iso: first.d) else { return nil }
        let diff = last.kg - first.kg
        if abs(diff) < 0.05 { return String(localized: "gleich seit \(since.shortText)") }
        return String(localized: "\(diff > 0 ? "+" : "−")\(Self.kg(abs(diff))) kg seit \(since.shortText)")
    }

    static func kg(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1)).locale(AppLocale.current)) }

    // MARK: Gesundheit

    /// Impfungen, Entwurmungen und Medikamente in einer Liste: was zuerst fällig wird, steht oben.
    private var health: some View {
        let items = healthItems
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                // Die Überschrift steht schon im Reiter; hier nur, was dazugehört.
                Text("Impfungen, Entwurmungen, Medikamente").font(.subheadline).foregroundStyle(Palette.ink2)
                Spacer(minLength: 8)
                Menu {
                    Button { editing = .vaccination(Vaccination(id: newHealthID("vaccinations"))) } label: { Label { Text("Impfung") } icon: { Image("icon-spritze") } }
                    Button { editing = .deworming(Deworming(id: newHealthID("deworming"))) } label: { Label { Text("Entwurmung") } icon: { Image("icon-tablette") } }
                    Button { editing = .medication(Medication(id: newHealthID("meds"))) } label: { Label { Text("Medikament") } icon: { Image("icon-flaeschchen") } }
                } label: {
                    LineIcon("plus", size: 22).foregroundStyle(Palette.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(.hoverEffect, Circle())
                        .hoverEffect(.highlight)
                }
                .accessibilityLabel("Eintragen")
            }
            if items.isEmpty {
                Text("Impfungen, Entwurmungen und Medikamente stehen hier, sortiert nach dem, was zuerst fällig wird.")
                    .font(.subheadline).foregroundStyle(Palette.ink3)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Button(action: item.open) {
                            HStack(spacing: 14) {
                                LineIcon(item.symbol, size: 26).foregroundStyle(Palette.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                    Text(item.detail).font(.subheadline).foregroundStyle(Palette.ink2).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let who = item.author {
                                    AvatarView(image: who.image, name: who.name, size: 22)
                                        .accessibilityLabel("eingetragen von \(who.name)")
                                }
                                if let due = Day(iso: item.due) { DueChip(due: due) }
                            }
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if item.id != items.last?.id { Divider().overlay(Palette.line).padding(.leading, 40) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private struct HealthItem: Identifiable {
        let id: String, symbol: String, title: String, detail: String, due: String
        var author: (name: String, image: UIImage?)? = nil
        let open: () -> Void
    }

    private var healthItems: [HealthItem] {
        // Mit Fälligkeit zeigt der Chip das Wichtige; das letzte Datum nur, wenn nichts fällig ist.
        func detail(_ kind: String, _ date: String, _ extra: String) -> String {
            [kind, Day(iso: date)?.shortText, extra.isEmpty ? nil : extra].compactMap { $0 }.joined(separator: ", ")
        }
        var out: [HealthItem] = []
        for v in store.vaccinations {
            out.append(HealthItem(id: v.id, symbol: "spritze", title: v.name.isEmpty ? String(localized: "Impfung") : v.name,
                                  detail: detail(String(localized: "Impfung"), v.next.isEmpty ? v.date : "", ""), due: v.next, author: account.author(of: v)) { editing = .vaccination(v) })
        }
        for d in store.dewormings {
            out.append(HealthItem(id: d.id, symbol: "tablette", title: d.product.isEmpty ? String(localized: "Entwurmung") : d.product,
                                  detail: detail(String(localized: "Entwurmung"), d.next.isEmpty ? d.date : "", ""), due: d.next, author: account.author(of: d)) { editing = .deworming(d) })
        }
        for m in store.meds {
            out.append(HealthItem(id: m.id, symbol: "flaeschchen", title: m.name.isEmpty ? String(localized: "Medikament") : m.name,
                                  detail: [String(localized: "Medikament"), m.dose.isEmpty ? nil : m.dose].compactMap { $0 }.joined(separator: ", "), due: m.to, author: account.author(of: m)) { editing = .medication(m) })
        }
        // Mit Fälligkeit zuerst, die nächste oben; ohne Fälligkeit danach.
        return out.sorted { a, b in
            switch (Day(iso: a.due), Day(iso: b.due)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.title < b.title
            }
        }
    }

    // MARK: Notfallpass und Rudel

    private var extras: some View {
        VStack(alignment: .leading, spacing: 0) {
            extraRow(icon: "notfall", title: String(localized: "Notfallpass"), line: String(localized: "QR-Code fürs Halsband, falls jemand \(store.profile.name) findet")) { showsEmergency = true }
            extraRow(icon: "rudel", title: String(localized: "Rudel"), line: packLine) { account.presentsPack = true }
        }
    }

    private func extraRow(icon: String, title: String, line: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LineIcon(icon, size: 26).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(line).font(.footnote).foregroundStyle(Palette.ink2).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14, style: .continuous))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
    }

    private var packLine: String {
        guard let members = account.currentPack?.members, members.count > 1 else { return String(localized: "Teile \(store.profile.name) mit deinen Menschen") }
        return members.map(\.name).joined(separator: ", ")
    }
}

/// Die Bilanz an einer Leine: Sie hängt am Foto und läuft durch alles, was der Hund schon erlebt hat.
/// Die Zahlen stehen frei auf der Linie und folgen ihrem Auf und Ab.
private struct LeashTally: View {
    let photo: CGFloat
    let items: [(Int, String)]

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            // Sie darf ruhig wild sein: So sind die meisten Hunde.
            let stops = [CGPoint(x: w * 0.09, y: 72), CGPoint(x: w * 0.40, y: 54), CGPoint(x: w * 0.71, y: 74)]
            let points = [
                // Beginnt hinter dem Foto, damit es so aussieht, als hinge die Leine am Halsband.
                CGPoint(x: photo * 0.22, y: -photo * 0.2), CGPoint(x: 6, y: 14), CGPoint(x: 3, y: 42),
                stops[0], CGPoint(x: w * 0.25, y: 78), stops[1], CGPoint(x: w * 0.56, y: 50), stops[2],
                // Am Ende eine Locke wie im Logo.
                CGPoint(x: w * 0.88, y: 72), CGPoint(x: w - 3, y: 56), CGPoint(x: w - 8, y: 43),
                CGPoint(x: w - 20, y: 41), CGPoint(x: w - 25, y: 51), CGPoint(x: w - 18, y: 56),
            ]
            ZStack(alignment: .topLeading) {
                LeashShape(points: points)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                Circle().fill(Palette.accent).frame(width: 9, height: 9).position(points[points.count - 1])
                ForEach(items.indices, id: \.self) { i in
                    Circle().fill(Palette.accent).frame(width: 11, height: 11).position(stops[i])
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(items[i].0)").font(.display(23, weight: .bold)).foregroundStyle(Palette.ink).monospacedDigit()
                        Text(items[i].1).font(.footnote.weight(.medium)).foregroundStyle(Palette.ink2)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: stops[i].x - 5, y: stops[i].y - 37)
                }
            }
        }
        .frame(height: 88)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    }
}

/// Eine Fälligkeit als Ring: Wie viel vom Abstand seit dem letzten Mal vergangen ist.
struct DueRing: View {
    let due: HealthDue
    /// Abhaken (Impfung, Entwurmung, bald fällig); `nil`: kein Knopf.
    var onDone: (() -> Void)? = nil

    var body: some View {
        let today = Day.today
        let overdue = due.due < today
        let color = overdue ? Palette.kind(.health) : Palette.accent
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                // Um die halbe Linienbreite eingerückt, sonst ragt der Ring aus dem Rahmen und wird am Rand abgeschnitten.
                Circle().inset(by: 3).stroke(color.opacity(0.16), lineWidth: 6)
                Circle().inset(by: 3).trim(from: 0, to: due.progress() ?? (overdue ? 1 : 0.02))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(DueChip.short(due.due))
                    .font(.display(15, weight: .bold, width: 80, relativeTo: .footnote))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 0) {
                Text(due.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(due.kind).font(.caption).foregroundStyle(Palette.ink2)
            }
            .accessibilityElement(children: .combine)
            if let onDone {
                Button("Erledigt", action: onDone)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.mini).tint(Palette.accent)
            }
        }
    }
}

/// „in 4 Mon.“, „in 12 T.“, „überfällig“.
struct DueChip: View {
    let due: Day

    var body: some View {
        let overdue = due < .today
        let soon = !overdue && Day.today.days(until: due) <= 30
        Text(overdue ? String(localized: "überfällig") : Self.short(due).replacingOccurrences(of: "\n", with: " "))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(overdue ? Palette.kind(.health) : soon ? Palette.accent : Palette.ink2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(overdue ? Palette.kind(.health).opacity(0.12) : soon ? Palette.soft : Palette.line.opacity(0.6), in: Capsule())
    }

    static func short(_ due: Day) -> String {
        let n = Day.today.days(until: due)
        switch n {
        case ..<0: return String(localized: "über-\nfällig")
        case 0: return String(localized: "heute")
        case 1: return String(localized: "morgen")
        case 2..<45: return String(localized: "in \(n)\nTagen")
        case 45..<365: return String(localized: "in \(n / 30)\nMon.")
        default: return n / 365 == 1 ? String(localized: "in 1\nJahr") : String(localized: "in \(n / 365)\nJahren")
        }
    }
}
