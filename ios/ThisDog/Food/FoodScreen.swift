import SwiftUI

extension Palette {
    /// Urteile im Food-Check: Hier trägt die Ampel die Bedeutung, deshalb Grün für „erlaubt“.
    static func verdict(_ v: Food.Verdict) -> Color {
        switch v {
        case .ok: Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x5CC995) : UIColor(rgb: 0x2F9E6B) })
        case .warn: kind(.warning)
        case .bad: kind(.health)
        }
    }

    static func verdictSymbol(_ v: Food.Verdict) -> String {
        switch v { case .ok: "haken"; case .warn: "ausruf"; case .bad: "kreuz" }
    }
}

/// Wissen: Food-Check und Ratgeber.
struct KnowledgeScreen: View {
    @Environment(\.horizontalSizeClass) private var hClass
    @Environment(\.verticalSizeClass) private var vClass
    /// In der Entwicklerfassung: `-ratgeber` öffnet den Ratgeber.
    @State private var part = ProcessInfo.processInfo.arguments.contains("-ratgeber") ? "tips" : "food"

    var body: some View {
        NavigationStack {
            Group {
                if part == "food" { FoodCheck() } else { TipsScreen() }
            }
            .background(Palette.paper)
            .clearsTabDock()
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .top, spacing: 0) {
                // Aufgeklappt links oben in der linken Hälfte – nicht mittig über dem Knick.
                BarSegments(items: [(String(localized: "Food-Check"), "food"), (String(localized: "Ratgeber"), "tips")], selection: $part)
                    .onChange(of: part) { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .frame(maxWidth: .infinity, alignment: hClass == .regular || vClass == .compact ? .leading : .center)
                    .padding(.horizontal, vClass == .compact ? 4 : 16).padding(.top, 10).padding(.bottom, 6)
            }
        }
    }
}

/// „Darf mein Hund …?“ – Suche mit Antwort, sobald es einen klaren Treffer gibt.
struct FoodCheck: View {
    @Environment(DogStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hClass
    /// Kompakt nur beim iPhone im Querformat: wenig Höhe, viel Breite.
    @Environment(\.verticalSizeClass) private var vClass
    @State private var query = FoodCheck.startQuery
    @State private var picked: Food?
    @State private var category: String?
    @State private var scanning = false
    /// Was ein Foto ergeben hat. Die Vorschläge bleiben sichtbar, solange einer davon gesucht wird.
    @State private var photoTerms: [String] = []
    @FocusState private var focused: Bool

    /// In der Entwicklerfassung lässt sich ein Suchbegriff mitgeben: `-suche Trauben`.
    private static var startQuery: String {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-suche"), i + 1 < a.count { return a[i + 1] }
        #endif
        return ""
    }

    private var hits: [FoodSearch.Hit] { store.foodSearch.search(query, limit: 12) }

    /// Vorführung für Werbevideos (nur Entwicklerfassung): `-tippe Weintrauben|Banane` tippt Buchstabe für Buchstabe
    /// und leert das Feld am Ende wieder.
    private func demoTyping() async {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-tippe"), i + 1 < a.count else { return }
        try? await Task.sleep(for: .seconds(1.2))
        for word in a[i + 1].split(separator: "|") {
            query = ""
            for ch in word {
                query.append(ch)
                try? await Task.sleep(for: .milliseconds(170))
            }
            try? await Task.sleep(for: .seconds(2.4))
        }
        // Zum Schluss wieder leer – wie am Anfang, damit das Video nahtlos von vorn beginnt.
        query = ""
        #endif
    }
    /// Die Antwort: was angetippt wurde, sonst der beste Treffer.
    private var answer: Food? { picked ?? hits.first?.food }

    var body: some View {
        content
            .task { await demoTyping() }
            .sheet(isPresented: $scanning) {
                FoodScanner { terms in
                    photoTerms = terms
                    query = terms.first ?? ""
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if vClass == .compact {
            // iPhone quer: links suchen, rechts die Antwort. Die Tastatur lässt hier nur die linke Spalte brauchbar.
            HStack(alignment: .top, spacing: 24) {
                ScrollView { VStack(alignment: .leading, spacing: 16) { searchField; list }.padding(.vertical, 8) }
                    .scrollIndicators(.hidden)
                    .frame(width: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let answer { AnswerCard(food: answer) }
                        frequent
                    }
                    .padding(.vertical, 8).padding(.bottom, 16)
                }
            }
            .padding(.horizontal, 4)
        } else if hClass == .regular {
            FoldSplit {
                ScrollViewReader { proxy in
                    ScrollView { VStack(alignment: .leading, spacing: 22) { searchField.id(Self.top); list }.padding(28) }
                        .onChange(of: category) { scrollUp(proxy) }
                }
            } trailing: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        if let answer { AnswerCard(food: answer) }
                        frequent
                        overview
                    }
                    .padding(28)
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        searchField.id(Self.top)
                        if let answer, !query.isEmpty || picked != nil { AnswerCard(food: answer) }
                        if query.isEmpty && category == nil { frequent }
                        list
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                // Eine Kategorie oder ein Lebensmittel gewählt: nach oben, dort stehen Liste bzw. Antwort.
                .onChange(of: category) { scrollUp(proxy) }
                .onChange(of: picked) { if picked != nil { scrollUp(proxy) } }
            }
        }
    }

    private static let top = "oben"

    private func scrollUp(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy) { proxy.scrollTo(Self.top, anchor: .top) }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Darf mein Hund …?")
                .font(.display(hClass == .regular ? 40 : 32)).foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 10) {
                LineIcon("lupe", size: 24).foregroundStyle(Palette.ink3)
                TextField("z. B. Trauben, Käse, Banane", text: $query)
                    .font(.title3)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onChange(of: query) { _, _ in picked = nil; category = nil }
                if !query.isEmpty {
                    Button("Leeren", icon: "kreuz-kreis") { query = ""; picked = nil }
                        .labelStyle(.iconOnly).foregroundStyle(Palette.ink3)
                }
                Button("Foto oder Strichcode", icon: "kamera") { focused = false; scanning = true }
                    .labelStyle(.iconOnly).foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if photoTerms.count > 1, photoTerms.contains(query) { photoChoices }
        }
    }

    /// Nach einem Foto: Was die Bilderkennung sonst noch für möglich hält.
    private var photoChoices: some View {
        FlowLayout(spacing: 8) {
            Text("Auf dem Foto:").font(.subheadline).foregroundStyle(Palette.ink2)
            ForEach(photoTerms, id: \.self) { t in
                let on = t == query
                Button { query = t } label: {
                    Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(on ? Palette.soft : Palette.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Palette.accent.opacity(0.4) : Palette.line))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Liste

    @ViewBuilder
    private var list: some View {
        if !query.isEmpty {
            if hits.isEmpty {
                Text("„\(query)“ steht nicht in der Liste. Im Zweifel nicht füttern und in der Praxis fragen.")
                    .font(.subheadline).foregroundStyle(Palette.ink2)
            } else {
                foodRows(hits.map(\.food), highlight: answer)
            }
        } else if let category {
            VStack(alignment: .leading, spacing: 8) {
                Button { self.category = nil } label: { Label("Alle Kategorien", icon: "chevron-links").font(.subheadline) }
                Text(category).font(.display(24, weight: .semibold)).foregroundStyle(Palette.ink)
                foodRows(store.foods.filter { $0.category == category }.sorted { order($0, $1) }, highlight: picked)
            }
        } else {
            if hClass != .regular { overview }
            categories
        }
    }

    private func order(_ a: Food, _ b: Food) -> Bool {
        let rank: [Food.Verdict: Int] = [.bad: 0, .warn: 1, .ok: 2]
        return (rank[a.verdict]!, a.name) < (rank[b.verdict]!, b.name)
    }

    private func foodRows(_ foods: [Food], highlight: Food?) -> some View {
        VStack(spacing: 0) {
            ForEach(foods) { f in
                Button { withAnimation(.snappy) { picked = f } } label: {
                    HStack(spacing: 12) {
                        Circle().fill(Palette.verdict(f.verdict)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                            Text(f.verdictLabel).font(.subheadline).foregroundStyle(Palette.ink2)
                        }
                        Spacer()
                        if store.isFavorite(f) { LineIcon("herz", size: 16).foregroundStyle(Palette.accent) }
                    }
                    .padding(.vertical, 9).padding(.horizontal, 10)
                    .background(highlight?.id == f.id && hClass == .regular ? Palette.soft : .clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Oft gefragt

    /// Was am häufigsten gefragt wird – ein Tipp, und die Antwort steht da. Genaue Namen aus `foods.json`.
    static let frequentNames = [String(localized: "Schokolade"), String(localized: "Trauben"), String(localized: "Xylit"), String(localized: "Zwiebel"), String(localized: "Knoblauch"), String(localized: "Käse (hart, laktosearm)"), String(localized: "Banane"),
                                String(localized: "Apfel (ohne Kerne)"), String(localized: "Karotte (roh oder gekocht)"), String(localized: "Gurke"), String(localized: "Erdbeeren"), String(localized: "Huhn (gekocht)"), String(localized: "Reis (gekocht)")]

    private var frequentFoods: [Food] {
        Self.frequentNames.compactMap { name in store.foods.first { $0.name == name } }
    }

    /// „Käse (hart, laktosearm)“ → „Käse“: Auf dem Chip genügt das Wort, die Antwort nennt den Rest.
    static func short(_ name: String) -> String {
        name.components(separatedBy: " (").first ?? name
    }

    @ViewBuilder
    private var frequent: some View {
        let foods = frequentFoods
        if !foods.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Oft gefragt").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
                FlowLayout(spacing: 8) {
                    ForEach(foods) { f in
                        let on = picked?.id == f.id
                        Button { withAnimation(.snappy) { picked = on ? nil : f } } label: {
                            HStack(spacing: 7) {
                                Circle().fill(Palette.verdict(f.verdict)).frame(width: 8, height: 8)
                                Text(Self.short(f.name)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            }
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(on ? Palette.soft : Palette.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Palette.accent.opacity(0.4) : Palette.line))
                            .contentShape(.hoverEffect, Capsule())
                            .hoverEffect(.highlight)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(f.name), \(f.verdictLabel)")
                    }
                }
            }
        }
    }

    // MARK: Überblick

    @ViewBuilder
    private var overview: some View {
        let favs = store.foods.filter { store.isFavorite($0) }
        if !favs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Merkliste").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
                foodRows(favs, highlight: nil)
            }
        } else if hClass == .regular {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(store.foods.count) Lebensmittel").font(.display(40, weight: .bold, width: 80)).foregroundStyle(Palette.ink)
                VerdictBar(foods: store.foods).frame(height: 12)
                HStack(spacing: 18) {
                    ForEach([Food.Verdict.ok, .warn, .bad], id: \.self) { v in
                        let n = store.foods.filter { $0.verdict == v }.count
                        HStack(spacing: 6) {
                            Circle().fill(Palette.verdict(v)).frame(width: 8, height: 8)
                            Text("\(n) \(v == .ok ? "erlaubt" : v == .warn ? "mit Vorsicht" : "nicht geeignet")")
                                .font(.subheadline).foregroundStyle(Palette.ink2)
                        }
                    }
                }
            }
        }
    }

    /// Jede Kategorie mit einem Streifen: wie viel darin erlaubt, mit Vorsicht, nicht geeignet ist.
    private var categories: some View {
        let groups = Dictionary(grouping: store.foods, by: \.category).sorted { $0.value.count > $1.value.count }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Kategorien").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink).padding(.bottom, 6)
            ForEach(groups, id: \.key) { name, foods in
                Button { withAnimation(.snappy) { category = name } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(name).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                            Spacer()
                            Text("\(foods.count)").font(.subheadline).monospacedDigit().foregroundStyle(Palette.ink3)
                        }
                        VerdictBar(foods: foods).frame(height: 6)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Die Antwort: Zeichen, Urteil, Begründung.
struct AnswerCard: View {
    @Environment(DogStore.self) private var store
    let food: Food

    var body: some View {
        let color = Palette.verdict(food.verdict)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                LineIcon(Palette.verdictSymbol(food.verdict), size: 35)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(color, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(food.verdictLabel).font(.display(28, weight: .bold, width: 85)).foregroundStyle(color)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(food.name).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                }
                Spacer()
                Button(store.isFavorite(food) ? String(localized: "Von der Merkliste nehmen") : String(localized: "Auf die Merkliste"), icon: store.isFavorite(food) ? "herz" : "herz") {
                    store.toggleFavorite(food)
                }
                .labelStyle(.iconOnly)
                // Keine gefüllte Form im Linien-Stil: Gemerkt ist an der Farbe zu erkennen.
                .foregroundStyle(store.isFavorite(food) ? Palette.accent : Palette.ink3)
                .sensoryFeedback(.selection, trigger: store.isFavorite(food))
            }
            Text(food.reason).font(.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            if let a = food.aliases, !a.isEmpty {
                Text("Auch: \(a.joined(separator: ", "))").font(.footnote).foregroundStyle(Palette.ink2)
            }
            Text(food.category).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink3)
        }
        .padding(20)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.snappy, value: food)
        .accessibilityElement(children: .combine)
    }
}

/// Anteile erlaubt, mit Vorsicht, nicht geeignet als ein Streifen.
struct VerdictBar: View {
    let foods: [Food]

    var body: some View {
        let total = max(1, foods.count)
        let parts = [Food.Verdict.ok, .warn, .bad].map { v in (v, foods.filter { $0.verdict == v }.count) }.filter { $0.1 > 0 }
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(parts, id: \.0) { v, n in
                    Capsule().fill(Palette.verdict(v))
                        .frame(width: max(4, (g.size.width - CGFloat(parts.count - 1) * 2) * CGFloat(n) / CGFloat(total)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
