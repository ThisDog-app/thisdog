import CoreImage.CIFilterBuiltins
import SwiftUI
import Vision
import VisionKit

/// Die Einladung als QR-Code: Der Hundesitter scannt ihn mit der Kamera (oder in ThisDog) und ist im Rudel.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(14)
                // Immer hell: Scanner lesen dunkle Punkte auf hellem Grund am zuverlässigsten.
                .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityLabel("QR-Code der Einladung")
        }
    }

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Kamera für den QR-Code einer Einladung. Erkennt nur Links von thisdog.app und gibt sie weiter.
struct InviteScannerSheet: View {
    let onLink: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera = ScannerHandle()
    @State private var hint: String?

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if canScan {
                    DataScannerView(handle: camera, symbologies: [.qr]) { code in
                        guard let url = Self.inviteURL(code) else {
                            hint = String(localized: "Das ist kein Code von ThisDog.")
                            return
                        }
                        dismiss()
                        onLink(url)
                    }
                    .ignoresSafeArea()
                } else {
                    Text("Die Kamera ist hier nicht verfügbar. Öffne stattdessen den Einladungslink, den du bekommen hast.")
                        .font(.body).foregroundStyle(Palette.ink2)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.paper)
                }
                Text(hint ?? String(localized: "Halte die Kamera auf den QR-Code im Rudel des anderen Telefons."))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(24)
            }
            .navigationTitle("Einladung scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }

    /// Nur Einladungen ins Rudel oder unter Freunden – ein fremder QR-Code öffnet nichts.
    static func inviteURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host() == "thisdog.app" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, ["rudel", "freund"].contains(parts[0]) else { return nil }
        return url
    }
}
