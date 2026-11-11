import SwiftUI

/// Das Revier im Panel über der Karte: Zahlen, Abzeichen und die letzten Check-ins als Leine.
/// Die Orte selbst liegen auf der großen Karte (`WalkMap.revier`).
struct RevierPanel: View {
    @Environment(DogStore.self) private var store
    @Environment(Account.self) private var account

    var body: some View {
        let r = Revier(store.checkIns)
        VStack(alignment: .leading, spacing: 0) {
            Text(CheckIns.revierTitle(store.profile.name)).font(.display(28)).foregroundStyle(Palette.ink)
            HStack(spacing: 16) {
                stat(r.spots.count, r.spots.count == 1 ? String(localized: "Ort") : String(localized: "Orte"))
                stat(r.total, r.total == 1 ? String(localized: "Besuch") : String(localized: "Besuche"))
            }
            .padding(.top, 4)

            if !r.badges.isEmpty || r.next != nil { badges(r).padding(.top, 16) }

            Text("Zuletzt").font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink).padding(.top, 26).padding(.bottom, 10)
            if r.recent.isEmpty {
                Text("Noch leer. Wer beim Gassi an einem Ort eincheckt, sammelt ihn hier.").font(.subheadline).foregroundStyle(Palette.ink2)
            } else {
                leash(Array(r.recent.prefix(12)))
            }
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        (Text("\(n) ").font(.display(22, weight: .bold)).foregroundStyle(Palette.accent) + Text(label).foregroundStyle(Palette.ink2))
    }

    private func badges(_ r: Revier) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(r.badges) { b in badge(b, earned: true) }
                if let n = r.next { badge(n, earned: false) }
            }
        }
    }

    private func badge(_ b: Revier.Badge, earned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LineIcon(b.symbol, size: 30).foregroundStyle(earned ? Palette.accent : Palette.ink3)
            Text(b.title).font(.subheadline.weight(.semibold)).foregroundStyle(earned ? Palette.ink : Palette.ink2)
            Text(b.detail).font(.caption).foregroundStyle(Palette.ink2).lineLimit(2)
        }
        .frame(width: 130, alignment: .leading)
        .padding(12)
        .background(earned ? Palette.surface : Palette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { if !earned { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(earned ? String(localized: "Abzeichen \(b.title), \(b.detail)") : String(localized: "Nächstes Abzeichen \(b.title), \(b.detail)"))
    }

    /// Die letzten Check-ins an einer Leine: Locke oben, ein Punkt je Besuch.
    private func leash(_ list: [CheckIn]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle().fill(i == 0 ? Palette.accent : Palette.paper)
                            .overlay(Circle().strokeBorder(Palette.accent, lineWidth: 2))
                            .frame(width: 12, height: 12).padding(.top, 4)
                        if i < list.count - 1 { Rectangle().fill(Palette.line).frame(width: 1.4).frame(maxHeight: .infinity) }
                    }
                    .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CheckIns.whenText(c.date).capitalizedFirst).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink2)
                        Text(c.name).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        if let who = account.name(of: store.changer(of: c)) { Text("mit \(who)").font(.subheadline).foregroundStyle(Palette.ink2) }
                    }
                    .padding(.bottom, 14)
                    Spacer()
                }
                .contextMenu {
                    Button("Check-in löschen", menuIcon: "muell", role: .destructive) { store.removeCheckIn(c) }
                }
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
