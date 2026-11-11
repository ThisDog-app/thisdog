import SwiftUI

/// Der Ratgeber: oben, was gerade passt (Jahreszeit, Lebensphase), darunter alle Tipps nach Kategorie.
struct TipsScreen: View {
    @Environment(DogStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hClass
    /// Kompakt nur beim iPhone im Querformat: wenig Höhe, viel Breite.
    @Environment(\.verticalSizeClass) private var vClass
    @State private var category: String?
    @State private var opened: Tip?

    private var season: Season { .of(.today) }
    private var stage: String? { TipRanking.stageKey(store.profile.stage()) }

    private var recommended: [Tip] {
        let season = self.season, stage = self.stage
        let scored: [(tip: Tip, score: Double)] = store.tips.map { (tip: $0, score: TipRanking.score($0, season: season, stage: stage)) }
        let fitting = scored.filter { $0.score >= 3 }
        let sorted = fitting.sorted { a, b in a.score != b.score ? a.score > b.score : a.tip.id < b.tip.id }
        return sorted.prefix(3).map { $0.tip }
    }

    private var shown: [Tip] { store.tips.filter { category == nil || $0.category == category } }

    /// Was rechts zu lesen ist: das Gewählte, sonst das, was gerade am besten passt.
    private var current: Tip? { opened ?? recommended.first ?? store.tips.first }

    var body: some View {
        if vClass == .compact {
            landscape
        } else if hClass == .regular {
            FoldSplit {
                ScrollView { overview.padding(28) }
            } trailing: {
                ScrollView {
                    if let tip = current { TipDetail(tip: tip).padding(28).id(tip.id) }
                }
            }
        } else {
            ScrollView { overview.padding(.horizontal, 16).padding(.vertical, 12) }
                .sheet(item: $opened) { tip in
                    NavigationStack { ScrollView { TipDetail(tip: tip).padding(20) }.background(Palette.paper) }
                        .presentationDragIndicator(.visible)
                }
        }
    }

    /// iPhone quer: Im Ratgeber wird gelesen. Links die Auswahl, rechts der Text, ohne eigenes Fenster.
    private var landscape: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView { picker.padding(.vertical, 8) }
                .scrollIndicators(.hidden)
                .frame(width: 300)
            if let tip = current {
                // Eigene Kennung, damit ein neuer Tipp oben beginnt.
                ScrollView { TipDetail(tip: tip).padding(.vertical, 8).padding(.bottom, 16) }
                    .id(tip.id)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Die Auswahl quer: Zuerst, was gerade passt, darunter der Rest, ohne etwas doppelt zu zeigen.
    private var picker: some View {
        let top = recommended
        let name = store.profile.name
        let rest = category == nil ? shown.filter { t in !top.contains { $0.id == t.id } } : shown
        return VStack(alignment: .leading, spacing: 14) {
            if category == nil, !top.isEmpty {
                Text(name.isEmpty ? String(localized: "Passend zum \(season.label)") : String(localized: "Für \(name) im \(season.label)"))
                    .font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
                rows(top)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { chips }
            }
            rows(rest)
        }
    }

    private func rows(_ tips: [Tip]) -> some View {
        VStack(spacing: 0) {
            ForEach(tips) { tip in
                Button { withAnimation(.snappy) { opened = tip } } label: { TipRow(tip: tip, selected: current?.id == tip.id) }
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        chip(String(localized: "Alle"), selected: category == nil) { category = nil }
        ForEach(Array(Set(store.tips.map(\.category))).sorted(), id: \.self) { c in
            chip(c, selected: category == c) { category = c }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 26) {
            let name = store.profile.name
            Text(name.isEmpty ? String(localized: "Passend zum \(season.label)") : String(localized: "Für \(name) im \(season.label)"))
                .font(.display(hClass == .regular ? 40 : 32)).foregroundStyle(Palette.ink)
                .lineLimit(2).minimumScaleFactor(0.8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(recommended) { tip in
                        Button { withAnimation(.snappy) { opened = tip } } label: { TipCard(tip: tip) }.buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { chips }
            }
            VStack(spacing: 0) {
                ForEach(shown) { tip in
                    Button { withAnimation(.snappy) { opened = tip } } label: { TipRow(tip: tip, selected: opened?.id == tip.id && hClass == .regular) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Text(label).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? Palette.accent : Palette.ink)
                .background(selected ? Palette.soft : Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Palette.accent.opacity(0.4) : Palette.line))
        }
        .buttonStyle(.plain)
    }
}

/// Das Bild eines Tipps: mitgeliefert oder vom Server.
struct TipImage: View {
    let tip: Tip

    var body: some View {
        if let img = tip.bundledImage {
            Image(uiImage: img).resizable().scaledToFill()
        } else if let url = tip.remoteImage {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Palette.soft }
        } else {
            Palette.soft
        }
    }
}

struct TipCard: View {
    let tip: Tip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TipImage(tip: tip)
                .frame(width: 240, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(tip.title).font(.headline).foregroundStyle(Palette.ink).lineLimit(2, reservesSpace: true)
            Text("\(tip.category), \(tip.minutes) Min.").font(.footnote).foregroundStyle(Palette.ink2)
        }
        .frame(width: 240, alignment: .leading)
    }
}

struct TipRow: View {
    @Environment(DogStore.self) private var store
    let tip: Tip
    var selected = false

    var body: some View {
        HStack(spacing: 14) {
            TipImage(tip: tip).frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(2)
                Text("\(tip.category), \(tip.minutes) Min.").font(.subheadline).foregroundStyle(Palette.ink2)
            }
            Spacer()
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(selected ? Palette.soft : .clear, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }
}

/// Ein Tipp: Bild und Text.
struct TipDetail: View {
    @Environment(DogStore.self) private var store
    @Environment(\.verticalSizeClass) private var vClass
    let tip: Tip

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if vClass == .compact {
                // Quer ist wenig Höhe: Das Bild steht neben dem Titel, damit gleich Text zu sehen ist.
                HStack(alignment: .top, spacing: 16) {
                    TipImage(tip: tip)
                        .frame(width: 132, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tip.title).font(.display(26)).foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        tags
                    }
                }
            } else {
                TipImage(tip: tip)
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                Text(tip.title).font(.display(34)).foregroundStyle(Palette.ink)
                tags
            }
            ForEach(Array(TipText.blocks(tip.content).enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let t):
                    Text(t).font(.display(21, weight: .semibold)).foregroundStyle(Palette.ink).padding(.top, 6)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Palette.accent).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                        Text(TipText.inline(t)).foregroundStyle(Palette.ink)
                    }
                case .paragraph(let t):
                    Text(TipText.inline(t)).foregroundStyle(Palette.ink).lineSpacing(3)
                }
            }
        }
    }

    private var tags: some View {
        FlowLayout(spacing: 8) {
            tag(tip.category)
            ForEach((tip.season ?? []).compactMap(Season.init(rawValue:)), id: \.self) { tag($0.label) }
            tag(String(localized: "\(tip.minutes) Min."))
        }
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Palette.line.opacity(0.6), in: Capsule())
    }
}
