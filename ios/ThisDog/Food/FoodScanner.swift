import PhotosUI
import SwiftUI
import Vision
import VisionKit

/// Kamera im Food-Check: Ein Strichcode wird von selbst erkannt und über seine Zutaten geprüft;
/// ein Druck auf den Auslöser fotografiert das Essen und schlägt es in der Liste nach.
/// Ohne Kamera (Simulator, ältere Geräte) bleibt die Auswahl aus den Fotos.
struct FoodScanner: View {
    @Environment(DogStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Erkannte Suchbegriffe aus einem Foto, der wahrscheinlichste zuerst.
    let onPhoto: ([String]) -> Void

    private enum Stage: Equatable {
        case scanning
        case working(String)
        case product(ScannedProduct)
        case failed(String)
    }

    @State private var stage: Stage = .scanning
    @State private var camera = ScannerHandle()
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var nothingFound = false

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                switch stage {
                case .scanning, .working:
                    scanner
                case .product(let p):
                    ScrollView { ProductAnswer(product: p).padding(20) }
                case .failed(let message):
                    VStack(spacing: 14) {
                        Text(message).font(.body).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                    }
                    .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .glassBar(String(localized: "Foto oder Strichcode")) {
                BarTextItem(title: String(localized: "Schließen"), cancel: true) { dismiss() }
            }
        }
        .tint(Palette.accent)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                guard let img = await PickedPhoto.image(item) else { return }
                await recognize(img)
            }
        }
        .alert("Kein Essen erkannt", isPresented: $nothingFound) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Versuch es näher und mit mehr Licht, oder tipp den Namen ins Suchfeld.")
        }
    }

    // MARK: Kamera

    @ViewBuilder
    private var scanner: some View {
        if canScan {
            DataScannerView(handle: camera) { code in
                guard stage == .scanning else { return }
                Task { await lookup(code) }
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Text("Strichcode ins Bild halten – oder Essen fotografieren.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.top, 8)
            }
            .overlay { if case .working(let text) = stage { working(text) } }
        } else {
            VStack(spacing: 12) {
                LineIcon("kamera", size: 40).foregroundStyle(Palette.ink3)
                Text("Hier gibt es keine Kamera zum Scannen. Wähl ein Foto aus deiner Mediathek.")
                    .font(.body).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
            }
            .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if case .working(let text) = stage { working(text) } }
        }
    }

    private func working(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        }
        .padding(20)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch stage {
        case .scanning, .working:
            HStack(spacing: 12) {
                PhotosPicker(selection: $pickedPhoto, matching: .images, preferredItemEncoding: .compatible) {
                    Label("Aus Fotos", icon: "foto").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(Palette.ink)
                if canScan {
                    Button {
                        Task {
                            guard let img = await camera.capture() else { return }
                            await recognize(img)
                        }
                    } label: {
                        Label("Foto prüfen", icon: "kamera").font(.headline).foregroundStyle(Palette.paper)
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.ink)
                }
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(stage != .scanning)
            .padding(.horizontal, 20).padding(.vertical, 12)
        case .product, .failed:
            Button {
                stage = .scanning
                camera.resume()
            } label: {
                Text("Nochmal scannen").font(.headline).foregroundStyle(Palette.paper).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.ink)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    // MARK: Auswerten

    private func recognize(_ image: UIImage) async {
        guard let cg = image.cgImage else { return }
        stage = .working(String(localized: "Erkenne …"))
        let terms = await FoodPhoto.recognize(cg)
        stage = .scanning
        if terms.isEmpty { nothingFound = true; return }
        onPhoto(terms)
        dismiss()
    }

    private func lookup(_ code: String) async {
        camera.pause()
        stage = .working(String(localized: "Suche Produkt …"))
        do {
            stage = .product(try await ScannedProduct.lookup(code))
        } catch .notFound {
            stage = .failed(String(localized: "Dieses Produkt ist bei Open Food Facts nicht verzeichnet. Schau auf die Zutatenliste: Xylit, Schokolade, Rosinen, Zwiebeln und Knoblauch sind für Hunde gefährlich."))
        } catch {
            stage = .failed(String(localized: "Gerade keine Verbindung. Ohne Internet lassen sich Strichcodes nicht nachschlagen."))
        }
    }
}

/// Die Antwort zu einem gescannten Produkt: Gesamturteil, die auffälligen Zutaten und woher die Daten stammen.
private struct ProductAnswer: View {
    @Environment(DogStore.self) private var store
    let product: ScannedProduct

    private var hits: [IngredientCheck.Hit] {
        IngredientCheck(foods: store.foods).hits(tags: product.ingredientTags, text: product.ingredientsText)
    }

    var body: some View {
        let hits = hits
        let verdict: Food.Verdict = hits.first?.verdict ?? .warn
        let color = Palette.verdict(verdict)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.name ?? String(localized: "Unbekanntes Produkt")).font(.display(26)).foregroundStyle(Palette.ink)
                if let brand = product.brand { Text(brand).font(.subheadline).foregroundStyle(Palette.ink2) }
            }

            HStack(alignment: .center, spacing: 14) {
                LineIcon(Palette.verdictSymbol(verdict), size: 30).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(color, in: Circle())
                Text(headline(hits)).font(.display(22, weight: .bold, width: 85)).foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(hits) { h in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(Palette.verdict(h.verdict)).frame(width: 9, height: 9)
                        Text(h.name).font(.headline).foregroundStyle(Palette.ink)
                    }
                    Text(h.reason).font(.subheadline).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if hits.isEmpty {
                Text(product.hasIngredients
                     ? "In den Zutaten steht nichts, was für Hunde giftig ist. Fertigprodukte sind trotzdem oft zu salzig, zu fett oder gewürzt – höchstens ausnahmsweise und wenig."
                     : "Zu diesem Produkt sind keine Zutaten hinterlegt. Schau selbst auf die Packung: Xylit, Schokolade, Rosinen, Zwiebeln und Knoblauch sind für Hunde gefährlich.")
                    .font(.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            }

            if !product.ingredientsText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Zutaten").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink3)
                    Text(product.ingredientsText).font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Produktdaten: Open Food Facts (ODbL). Die Angaben pflegen Freiwillige und können unvollständig sein.")
                .font(.caption).foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(_ hits: [IngredientCheck.Hit]) -> String {
        switch hits.first?.verdict {
        case .bad: String(localized: "Nicht geeignet")
        case .warn: String(localized: "Nur mit Vorsicht")
        case .ok, nil: product.hasIngredients ? String(localized: "Nichts Giftiges gefunden") : String(localized: "Zutaten unbekannt")
        }
    }
}

/// Verbindung zwischen SwiftUI und dem Scanner: Foto auslösen, anhalten, weiterscannen.
@MainActor
final class ScannerHandle {
    weak var scanner: DataScannerViewController?

    func capture() async -> UIImage? { try? await scanner?.capturePhoto() }
    func pause() { scanner?.stopScanning() }
    func resume() { try? scanner?.startScanning() }
}

/// Die Kamera mit Strichcode-Erkennung. Food-Check: EAN; Rudel: QR-Code der Einladung.
struct DataScannerView: UIViewControllerRepresentable {
    let handle: ScannerHandle
    var symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .upce]
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: symbologies)],
                                           qualityLevel: .balanced, recognizesMultipleItems: false,
                                           isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        handle.scanner = vc
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in added {
                if case .barcode(let b) = item, let code = b.payloadStringValue { onCode(code); return }
            }
        }
    }
}
