import SwiftUI

/// Zwei Hälften nebeneinander, getrennt genau in der Mitte des Fensters.
///
/// Auf dem aufgeklappten iPhone Duo liegt diese Mitte auf dem Knick. Gemessen wird deshalb über die volle
/// Breite einschließlich der Ränder, die das System freihält (auf dem Duo 84 pt an der Seite der Kamera) –
/// sonst säße die Trennung um diese Ränder versetzt neben dem Knick. Jede Hälfte hält den Rand ihrer
/// Außenseite selbst frei.
struct FoldSplit<Leading: View, Trailing: View>: View {
    /// Anteil der linken Spalte im Querformat. Weicht er von der Hälfte ab, liegt die Trennung bewusst neben dem Knick.
    var landscapeShare: CGFloat = 0.5
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // Die Ränder vorher lesen: Innerhalb von `ignoresSafeArea` meldet der GeometryReader sie als null.
        GeometryReader { outer in
            let inset = outer.safeAreaInsets
            GeometryReader { g in
                let left = g.size.width * (g.size.width > g.size.height ? landscapeShare : 0.5)
                HStack(spacing: 0) {
                    leading
                        .padding(.leading, inset.leading)
                        .frame(width: left)
                    // Kein Strich: Auf dem Duo trennt der Knick, auf dem iPad genügt der Abstand.
                    trailing
                        .padding(.trailing, inset.trailing)
                        .frame(width: g.size.width - left)
                }
            }
            .ignoresSafeArea(.container, edges: .horizontal)
        }
    }
}
