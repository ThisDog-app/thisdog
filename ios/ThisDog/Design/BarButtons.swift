import SwiftUI

/// „Fertig“, „Abbrechen“, „Sichern“ … als Glaskapsel. `cancel` steht links, alles andere rechts.
struct BarTextItem: View {
    let title: String
    var cancel = false
    var role: ButtonRole?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.body.weight(cancel ? .regular : .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Capsule())
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Palette.kind(.health) : cancel ? Palette.ink : Palette.accent)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .glassEffect(.regular, in: Capsule())
        .layoutValue(key: BarLeading.self, value: cancel)
    }
}

/// Der Wechsel zwischen zwei Bereichen (Food-Check, Ratgeber): eine Kapsel, der gewählte Bereich getönt.
struct BarSegments<Value: Hashable>: View {
    let items: [(title: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        // Beide Hälften gleich breit: Sonst ist die Markierung je nach Seite breiter oder schmaler.
        EqualWidths(spacing: 4) {
            ForEach(items, id: \.value) { item in
                let on = item.value == selection
                Button { withAnimation(.snappy) { selection = item.value } } label: {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Palette.accent : Palette.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background { if on { SelectionPill() } }
                        .contentShape(Capsule())
                        .contentShape(.hoverEffect, Capsule())
                        .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(5)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Nebeneinander, jedes so breit wie das breiteste.
private struct EqualWidths: Layout {
    var spacing: CGFloat

    private func cell(_ subviews: Subviews) -> CGSize {
        subviews.reduce(.zero) { s, v in
            let f = v.sizeThatFits(.unspecified)
            return CGSize(width: max(s.width, f.width), height: max(s.height, f.height))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let c = cell(subviews), n = CGFloat(subviews.count)
        return CGSize(width: c.width * n + spacing * max(n - 1, 0), height: c.height)
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let c = cell(subviews)
        for (i, v) in subviews.enumerated() {
            v.place(at: CGPoint(x: b.minX + CGFloat(i) * (c.width + spacing), y: b.minY),
                    proposal: ProposedViewSize(width: c.width, height: c.height))
        }
    }
}

private struct BarLeading: LayoutValueKey { static let defaultValue = false }

/// Legt `cancel`-Einträge nach links und alles andere nach rechts; mehrere rechts stehen nebeneinander.
private struct BarRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let h = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: h)
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX
        for s in subviews where s[BarLeading.self] {
            s.place(at: CGPoint(x: x, y: b.midY), anchor: .leading, proposal: .unspecified)
            x += s.sizeThatFits(.unspecified).width + spacing
        }
        var r = b.maxX
        for s in subviews.reversed() where !s[BarLeading.self] {
            s.place(at: CGPoint(x: r, y: b.midY), anchor: .trailing, proposal: .unspecified)
            r -= s.sizeThatFits(.unspecified).width + spacing
        }
    }
}

extension View {
    /// Die Kopfzeile einer Ansicht: Titel in der Mitte, Buttons links und rechts.
    func glassBar<Items: View>(_ title: String? = nil, @ViewBuilder items: () -> Items) -> some View {
        let row = items()
        return toolbar(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .top, spacing: 0) {
                ZStack {
                    if let title {
                        Text(title).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                            .padding(.horizontal, 110)
                            .accessibilityAddTraits(.isHeader)
                    }
                    BarRow { row }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
    }
}

/// Wo man gerade ist und wie man zurückkommt: „‹ Wohin heute? › Hundezone“.
struct Breadcrumb: View {
    let parent: String
    let current: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                HStack(spacing: 4) {
                    LineIcon("chevron-links", size: 16)
                    Text(parent).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .foregroundStyle(Palette.accent)
                .frame(minHeight: 44)
                .padding(.horizontal, 8)
                .contentShape(Capsule())
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect(.highlight)
            }
            .buttonStyle(.plain)
            .padding(.leading, -8)
            LineIcon("chevron-rechts", size: 12).foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)
            Text(current).font(.subheadline).foregroundStyle(Palette.ink2).lineLimit(1)
        }
    }
}

/// Eine eigene Ansicht mit zwei Spalten (Duo, iPad: links Inhalt und Vorschau, rechts bearbeiten, getrennt auf dem
/// Knick); auf dem iPhone stehen beide untereinander.
struct TwoPane<Left: View, Right: View>: View {
    @Environment(\.horizontalSizeClass) private var hClass
    @Environment(\.verticalSizeClass) private var vClass
    let parent: String
    let title: String
    /// Untereinander zuerst die rechte Spalte, wenn dort das Wichtigste steht.
    var rightFirst = false
    let close: () -> Void
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        Group {
            if hClass == .regular || vClass == .compact {
                FoldSplit {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Breadcrumb(parent: parent, current: title, back: close)
                            left
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32).padding(.vertical, 16)
                    }
                } trailing: {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) { right }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 32).padding(.top, 76).padding(.bottom, 24)
                    }
                }
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if rightFirst {
                                Text(title).font(.display(38)).foregroundStyle(Palette.ink)
                                right
                                left
                            } else {
                                left
                                right
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 24)
                    }
                    .glassBar { BarTextItem(title: String(localized: "Fertig"), action: close) }
                }
            }
        }
        .background(Palette.paper)
        .tint(Palette.accent)
    }
}

extension View {
    /// Zeigt eine `TwoPane`-Ansicht: auf Duo und iPad bildschirmfüllend, auf dem iPhone als Blatt.
    @ViewBuilder
    func ownView<V: View>(isPresented: Binding<Bool>, regular: Bool, @ViewBuilder content: @escaping () -> V) -> some View {
        if regular {
            fullScreenCover(isPresented: isPresented, content: content)
        } else {
            sheet(isPresented: isPresented, content: content)
        }
    }
}
