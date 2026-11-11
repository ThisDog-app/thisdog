import SwiftUI

/// Was eine Mitteilung sagt, wenn die App offen ist. Dann zeigt nicht iOS sie an, sondern die App selbst.
struct Notice: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let body: String
    /// Aus dem Rudel (eine Person hat etwas geändert) – sonst eine Erinnerung an einen Termin.
    let fromPack: Bool
    /// Wer im Rudel die Änderung gemacht hat (Konto) – für das Bild.
    var by: Int? = nil
    /// Statt der Glocke (z. B. ein Abzeichen nach dem Einchecken).
    var symbol: String? = nil
}

/// Die Meldung oben in der App: gleitet herein, bleibt kurz und geht von selbst. Antippen oder nach oben wischen schließt sie.
struct NoticeBanner: View {
    let notice: Notice
    var image: UIImage? = nil
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if notice.fromPack {
                AvatarView(image: image, name: notice.title, size: 36)
            } else {
                LineIcon(notice.symbol ?? "glocke", size: 23).foregroundStyle(Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(Palette.soft, in: Circle())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(notice.body).font(.subheadline).foregroundStyle(Palette.ink2).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.leading, 10).padding(.trailing, 16)
        .frame(maxWidth: 440)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .padding(.horizontal, 16)
        .contentShape(Capsule())
        .onTapGesture(perform: dismiss)
        .gesture(DragGesture(minimumDistance: 8).onEnded { if $0.translation.height < 0 { dismiss() } })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Schließt die Meldung")
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
    }
}
