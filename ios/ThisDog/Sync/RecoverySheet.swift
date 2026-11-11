import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Zeigt den Wiederherstellungsschlüssel, zum Kopieren oder Ausdrucken.
struct RecoverySheet: View {
    let code: String
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Falls alle Telefone weg sind")
                        .font(.display(30, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text("Mit diesem Schlüssel kommst du wieder an die Termine, Impfungen und Runden deines Hundes. Heb ihn gut auf, am besten in deinen Passwörtern oder ausgedruckt bei den Impfpapieren.")
                        .font(.body)
                        .foregroundStyle(Palette.ink2)
                    Text(code)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Button {
                        // Nur auf diesem Gerät und nach zwei Minuten wieder weg.
                        UIPasteboard.general.setItems([[UTType.plainText.identifier: code]],
                                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        copied = true
                        onSaved()
                    } label: {
                        Label(copied ? String(localized: "Kopiert") : String(localized: "Kopieren"), icon: copied ? "haken" : "kopieren")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button {
                        printCode()
                    } label: {
                        Label("Ausdrucken", icon: "drucker").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Text("Niemand außer dir kann ihn ersetzen, auch wir nicht. Und wer ihn hat und in euer Konto kommt, kann eure Daten lesen. Zeig ihn also nur Menschen, denen du deinen Hund anvertrauen würdest.")
                        .font(.footnote)
                        .foregroundStyle(Palette.ink2)
                }
                .padding(24)
            }
            .background(Palette.paper)
            .tint(Palette.accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }

    private func printCode() {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = String(localized: "ThisDog Wiederherstellungsschlüssel")
        let page = UIPrintInteractionController.shared
        page.printInfo = info
        page.printFormatter = UISimpleTextPrintFormatter(
            text: String(localized: "ThisDog: Wiederherstellungsschlüssel\n\n\(code)\n\nGut aufheben. Falls alle Telefone weg sind, kommst du damit wieder an die Daten deines Hundes."))
        page.present(animated: true) { _, done, _ in if done { onSaved() } }
    }
}
