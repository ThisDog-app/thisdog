import SwiftUI
import UIKit

/// Die Bereiche der App.
enum AppTab: String, CaseIterable, Identifiable {
    case heute, kalender, gassi, hund, wissen
    var id: String { rawValue }

    var title: String {
        switch self { case .heute: String(localized: "Heute"); case .kalender: String(localized: "Kalender"); case .gassi: String(localized: "Gassi"); case .hund: String(localized: "Hund"); case .wissen: String(localized: "Wissen") }
    }

    /// Name des Icons im Stil des Logos.
    var icon: String { rawValue }
}

/// Die schwebende Leiste unten: Icons im Strich des Logos, nur der aktive Bereich zeigt seinen Namen.
/// So braucht sie auf keinem Gerät eine eigene Spalte und bleibt auch auf dem schmalen Duo kurz.
struct TabDock: View {
    /// Knopfhöhe, Innenabstand und der kleine Abstand nach unten.
    static let clearance: CGFloat = 46 + 2 * 5 + 2

    @Binding var tab: AppTab
    /// Senkrecht in der Spalte, die das Duo auf der Kameraseite freihält – dort, wo iOS die Tabs erwartet.
    var vertical = false
    @Namespace private var ns

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(AppTab.allCases) { t in
                let on = t == tab
                Button {
                    withAnimation(.spring(duration: 0.38, bounce: 0.22)) { tab = t }
                } label: {
                    HStack(spacing: 7) {
                        LineIcon(t.icon, size: 24)
                        if on && !vertical {
                            Text(t.title).font(.subheadline.weight(.semibold)).fixedSize()
                                .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .leading)))
                        }
                    }
                    .foregroundStyle(on ? Palette.accent : Palette.ink)
                    .padding(.horizontal, vertical ? 0 : on ? 16 : 14)
                    .frame(width: vertical ? 46 : nil, height: 46)
                    .background {
                        if on { SelectionPill().matchedGeometryEffect(id: "aktiv", in: ns) }
                    }
                    .contentShape(Capsule())
                    .contentShape(.hoverEffect, Capsule())
                    .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(5)
        .glassEffect(.regular, in: Capsule())
        .sensoryFeedback(.selection, trigger: tab)
    }
}

extension EnvironmentValues {
    /// Wie viel Platz die schwebende Leiste unten braucht; 0, wenn sie in der Seitenspalte des Duo steht.
    @Entry var tabDockClearance: CGFloat = 0
}

private struct ClearsTabDock: ViewModifier {
    @Environment(\.tabDockClearance) private var clearance

    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, clearance)
    }
}

extension View {
    /// Hält unten Platz für die Leiste frei. Nötig innerhalb eines `NavigationStack`: Bis dorthin kommt der
    /// Abstand der Leiste nicht, die Seite kennt sonst nur den Home-Balken und endet hinter der Leiste.
    func clearsTabDock() -> some View { modifier(ClearsTabDock()) }
}

/// Ein Icon im Stil des Logos: eine durchgehende, runde Linie ohne Geraden. Der Strich wächst mit der Größe mit;
/// unter 20 pt wird er dünner als das Logo und verliert dessen Wirkung.
struct LineIcon: View {
    let name: String
    var size: CGFloat

    init(_ name: String, size: CGFloat = 24) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("icon-\(name)").resizable().renderingMode(.template).frame(width: size, height: size)
    }
}

/// Die Markierung des gewählten Eintrags – gleich in der Leiste unten, bei Food-Check/Ratgeber und den Reitern.
/// Die feine Kante hält sie im Dunkeln klar, wo das Licht des Glases sonst eine Seite verschluckt.
struct SelectionPill: View {
    var body: some View {
        Capsule().fill(Palette.soft)
            .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1))
    }
}

/// Ein Reiter: gleich auf Gassi und beim Hund.
struct ReiterButton: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(on ? Palette.accent : Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background { if on { SelectionPill() } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Beschriftung mit einem Icon im Stil des Logos.
extension Label where Title == Text, Icon == LineIcon {
    init(_ title: LocalizedStringKey, icon: String) {
        self.init { Text(title) } icon: { LineIcon(icon, size: 20) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon: String) {
        self.init { Text(title) } icon: { LineIcon(icon, size: 20) }
    }
}

/// In Menüs zeichnet das System selbst und nimmt nur ein reines Bild an.
extension Label where Title == Text, Icon == Image {
    init(_ title: LocalizedStringKey, menuIcon: String) {
        self.init { Text(title) } icon: { Image("icon-\(menuIcon)") }
    }
}

extension Button where Label == SwiftUI.Label<Text, LineIcon> {
    init(_ title: LocalizedStringKey, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringKey, menuIcon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, menuIcon: menuIcon) }
    }
}
