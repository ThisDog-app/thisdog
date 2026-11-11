import CoreLocation
import PhotosUI
import SwiftUI
import UIKit
import Vision

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up; case .down: self = .down; case .left: self = .left; case .right: self = .right
        case .upMirrored: self = .upMirrored; case .downMirrored: self = .downMirrored; case .leftMirrored: self = .leftMirrored; case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

extension PlaceService {
    /// Ein Foto zu einem Ort; gleich für alle sichtbar.
    static func uploadPhoto(_ id: String, jpeg: Data, label: String = "", check: Int? = nil) async throws {
        struct Answer: Decodable { struct P: Decodable { let id: Int }; let photo: P }
        var fields = ["id": id, "label": label]
        if let check { fields["check"] = String(check) }
        let _: Answer = try await Api().upload("place.php", ["action": "photo"], fields: fields, file: "foto", jpeg: jpeg)
    }

    /// Eine Prüfung vor Ort (nur Erkunder): alle Merkmale, der Standort und wann geprüft wurde.
    static func check(_ id: String, answers: [String: Int], lat: Double, lon: Double, at: Date) async throws -> Int {
        struct Body: Encodable { let id: String; let answers: [String: Int]; let lat: Double; let lon: Double; let at: Int }
        struct Answer: Decodable { struct C: Decodable { let id: Int }; let check: C }
        let a: Answer = try await Api().post("place.php", ["action": "check"], body: Body(id: id, answers: answers, lat: lat, lon: lon, at: Int(at.timeIntervalSince1970)))
        return a.check.id
    }

    struct MyCheck: Decodable, Identifiable {
        let id: Int
        let place: String
        let name: String
        let at: Double
        let status: String
        let photos: Int
    }

    static func mine() async throws -> (scout: Bool, checks: [MyCheck]) {
        struct Answer: Decodable { let scout: Bool; let checks: [MyCheck] }
        let a: Answer = try await Api().get("place.php", ["action": "mine"])
        return (a.scout, a.checks)
    }

    static func reportPhoto(_ id: Int, reason: String) async throws {
        struct Body: Encodable { let photo: Int; let reason: String }
        let _: Ok = try await Api().post("place.php", ["action": "report_photo"], body: Body(photo: id, reason: reason))
    }

    /// Ob auf dem Foto ein Gesicht zu sehen ist – erkannt auf dem Gerät, nichts geht dafür weg.
    static func hasFace(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation)).perform([req])
        return !(req.results ?? []).isEmpty
    }

    /// Ein Foto für das Hochladen: höchstens 2000 px, JPEG. Der Server kodiert es ohnehin neu.
    static func jpeg(_ image: UIImage) -> Data? {
        let k = min(1, 2000 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * k, height: image.size.height * k)
        return UIGraphicsImageRenderer(size: size, format: .photo).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
    }
}

/// Die Kamera (oder, im Simulator, die Mediathek).
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onPick(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Fotos eines Ortes nebeneinander; Antippen zeigt sie groß.
struct PlacePhotos: View {
    let photos: [Place.Photo]
    @State private var shown: Place.Photo?
    /// Gemeldet: bis zur Entscheidung verborgen, auch hier gleich.
    @State private var reported: Set<Int> = []

    var body: some View {
        if !photos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(photos.filter { !reported.contains($0.id) }) { ph in
                        Button { shown = ph } label: {
                            AsyncImage(url: ph.thumb) { img in img.resizable().scaledToFill() } placeholder: { Palette.surface }
                                .frame(width: 120, height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Foto")
                    }
                }
            }
            .fullScreenCover(item: $shown) { ph in
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    AsyncImage(url: ph.url) { img in img.resizable().scaledToFit() } placeholder: { ProgressView().tint(.white) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 12) {
                        Menu {
                            ForEach([("person", String(localized: "Person erkennbar")), ("unpassend", String(localized: "Unpassend")), ("falscher_ort", String(localized: "Gehört nicht zu diesem Ort")), ("anderes", String(localized: "Etwas anderes"))], id: \.0) { key, title in
                                Button(title) { Task { try? await PlaceService.reportPhoto(ph.id, reason: key); reported.insert(ph.id); shown = nil } }
                            }
                        } label: {
                            Text("Melden").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).frame(height: 40).background(.white.opacity(0.18), in: Capsule())
                        }
                        Button { shown = nil } label: {
                            LineIcon("kreuz", size: 22).foregroundStyle(.white)
                                .frame(width: 40, height: 40).background(.white.opacity(0.18), in: Circle())
                        }
                        .accessibilityLabel("Schließen")
                    }
                    .padding(20)
                }
            }
        }
    }
}

/// Prüfungen, die ohne Netz gemacht wurden: auf dem Gerät gesichert, mit Ort und Zeit von damals; gehen raus,
/// sobald es wieder Netz gibt.
@MainActor
enum CheckQueue {
    struct Item: Codable, Identifiable {
        var id = UUID()
        let place: String
        let name: String
        let answers: [String: Int]
        let lat: Double
        let lon: Double
        let at: Date
        var photos: [String]   // Dateinamen im Ordner der Warteschlange
    }

    private static let folder = URL.applicationSupportDirectory.appending(path: "pruefungen")
    private static var file: URL { folder.appending(path: "warteschlange.json") }

    static var items: [Item] {
        (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: file))) ?? []
    }

    private static func save(_ list: [Item]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: file, options: .atomic)
    }

    static func add(place: Place, answers: [String: Int], at here: CLLocationCoordinate2D, photos: [Data]) {
        var names: [String] = []
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for p in photos {
            let n = UUID().uuidString + ".jpg"
            try? p.write(to: folder.appending(path: n))
            names.append(n)
        }
        save(items + [Item(place: place.serverID ?? "", name: place.name, answers: answers, lat: here.latitude, lon: here.longitude, at: Date(), photos: names)])
    }

    /// Schickt, was wartet. Was der Server ablehnt (zu weit weg, zu alt), fällt weg; ohne Netz bleibt es.
    static func flush() async {
        var rest: [Item] = []
        for item in items {
            do {
                let cid = try await PlaceService.check(item.place, answers: item.answers, lat: item.lat, lon: item.lon, at: item.at)
                for n in item.photos {
                    if let d = try? Data(contentsOf: folder.appending(path: n)) { try? await PlaceService.uploadPhoto(item.place, jpeg: d, check: cid) }
                    try? FileManager.default.removeItem(at: folder.appending(path: n))
                }
            } catch Api.Failure.offline {
                rest.append(item)
            } catch {
                for n in item.photos { try? FileManager.default.removeItem(at: folder.appending(path: n)) }
            }
        }
        save(rest)
    }
}

/// Vor Ort prüfen (nur Erkunder): jedes Merkmal Ja oder Nein, drei Fotos.
struct CheckSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WalkRecorder.self) private var recorder
    let place: Place
    var onDone: (String) -> Void

    @State private var answers: [PlaceFeature: Int] = [:]
    @State private var photos: [String: UIImage] = [:]
    @State private var camera: String?
    @State private var saving = false
    @State private var message: String?
    @State private var faceSlot: String?
    @State private var faceImage: UIImage?

    private static let slots = [String(localized: "Eingang"), String(localized: "Fläche"), String(localized: "Besonderes")]
    private var distance: Double? { recorder.here.map { Track.distance($0, place.coordinate) } }
    private var near: Bool { (distance ?? .infinity) <= CheckIns.reach }
    private var complete: Bool { PlaceFeature.all(for: place).allSatisfy { answers[$0] != nil } && photos.count == Self.slots.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let d = distance {
                        Label(near ? String(localized: "Du bist am Ort, \(WalkText.distance(d)) entfernt") : String(localized: "Noch \(WalkText.distance(d)) bis zum Ort"),
                              icon: near ? "haken-kreis" : "ort")
                            .foregroundStyle(near ? Color(red: 0.12, green: 0.44, blue: 0.29) : Palette.ink2)
                    } else {
                        Label("Standort wird gesucht …", icon: "ort").foregroundStyle(Palette.ink2)
                    }
                }
                Section("Was es hier gibt") {
                    ForEach(PlaceFeature.all(for: place)) { f in
                        HStack {
                            Label(f.title, icon: f.symbol)
                            Spacer()
                            Picker(f.title, selection: Binding(get: { answers[f] ?? -1 }, set: { answers[f] = $0 })) {
                                Text("Ja").tag(1); Text("Nein").tag(0)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                        }
                    }
                }
                Section("Fotos") {
                    HStack(spacing: 8) {
                        ForEach(Self.slots, id: \.self) { slot in
                            Button { camera = slot } label: {
                                ZStack(alignment: .bottom) {
                                    if let img = photos[slot] {
                                        Image(uiImage: img).resizable().scaledToFill()
                                    } else {
                                        RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                        LineIcon("kamera", size: 27).foregroundStyle(Palette.accent).frame(maxHeight: .infinity)
                                    }
                                    Text(slot).font(.caption.weight(.semibold)).foregroundStyle(photos[slot] == nil ? Palette.accent : .white).padding(.bottom, 6)
                                }
                                .frame(height: 84).frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let message { Section { Text(message).foregroundStyle(Palette.kind(.health)) } }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(String(localized: "Vor Ort prüfen")) {
                BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                BarTextItem(title: String(localized: "Sichern"), disabled: saving || !complete || !near) { save() }
            }
            .sheet(item: Binding(get: { camera.map { Slot(name: $0) } }, set: { camera = $0?.name })) { slot in
                CameraPicker { img in
                    if PlaceService.hasFace(img) { faceSlot = slot.name; faceImage = img } else { photos[slot.name] = img }
                }.ignoresSafeArea()
            }
        }
        .tint(Palette.accent)
        .confirmationDialog("Auf dem Foto ist ein Gesicht zu sehen.", isPresented: Binding(get: { faceSlot != nil }, set: { if !$0 { faceSlot = nil } }), titleVisibility: .visible) {
            Button("Trotzdem verwenden") { if let s = faceSlot { photos[s] = faceImage }; faceSlot = nil }
            Button("Neues Foto", role: .cancel) { let s = faceSlot; faceSlot = nil; camera = s }
        } message: { Text("Fotos von Orten zeigen besser keine Menschen, die man erkennen kann.") }
    }

    private struct Slot: Identifiable { let name: String; var id: String { name } }

    private func save() {
        guard let here = recorder.here, let id = place.serverID else { return }
        saving = true; message = nil
        let a = Dictionary(uniqueKeysWithValues: answers.map { ($0.key.rawValue, $0.value) })
        let jpegs = Self.slots.compactMap { photos[$0].flatMap(PlaceService.jpeg) }
        Task {
            do {
                let cid = try await PlaceService.check(id, answers: a, lat: here.latitude, lon: here.longitude, at: Date())
                for (slot, d) in zip(Self.slots, jpegs) { try? await PlaceService.uploadPhoto(id, jpeg: d, label: slot, check: cid) }
                onDone(String(localized: "Geprüft. Die Angaben und Fotos sind jetzt zu sehen."))
                dismiss()
            } catch Api.Failure.offline {
                CheckQueue.add(place: place, answers: a, at: here, photos: jpegs)
                onDone(String(localized: "Ohne Netz gesichert. Die Prüfung geht raus, sobald du wieder online bist."))
                dismiss()
            } catch Api.Failure.server("too_far") {
                message = String(localized: "Zu weit vom Ort entfernt.")
            } catch {
                message = String(localized: "Nicht gesichert. Versuche es noch einmal.")
            }
            saving = false
        }
    }
}

/// Die eigenen Prüfungen: was wartet, was freigegeben ist, was ohne Netz noch auf dem Gerät liegt.
struct MyChecksScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var checks: [PlaceService.MyCheck] = []
    @State private var waiting: [CheckQueue.Item] = []

    var body: some View {
        NavigationStack {
            List {
                if !waiting.isEmpty {
                    Section {
                        Label(waiting.count == 1 ? String(localized: "1 Prüfung wartet aufs Netz") : String(localized: "\(waiting.count) Prüfungen warten aufs Netz"), icon: "offline")
                            .foregroundStyle(Palette.ink2)
                        ForEach(waiting) { w in row(w.name, String(localized: "\(w.at.formatted(date: .abbreviated, time: .shortened)), \(w.photos.count) Fotos"), String(localized: "Ohne Netz"), Palette.ink3) }
                    }
                }
                Section {
                    ForEach(checks) { c in
                        let (label, color): (String, Color) = switch c.status {
                        case "ok": (String(localized: "Freigegeben"), Palette.verdict(.ok))
                        case "rejected": (String(localized: "Abgelehnt"), Palette.kind(.health))
                        default: (String(localized: "Wartet auf Freigabe"), Palette.accent)
                        }
                        row(c.name.isEmpty ? c.place : c.name,
                            "\(Date(timeIntervalSince1970: c.at).formatted(date: .abbreviated, time: .shortened)), \(c.photos) \(c.photos == 1 ? "Foto" : "Fotos")", label, color)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(String(localized: "Meine Prüfungen")) { BarTextItem(title: String(localized: "Fertig")) { dismiss() } }
            .task {
                await CheckQueue.flush()
                waiting = CheckQueue.items
                checks = (try? await PlaceService.mine().checks) ?? []
            }
        }
        .tint(Palette.accent)
    }

    private func row(_ title: String, _ sub: String, _ status: String, _ color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(sub).font(.subheadline).foregroundStyle(Palette.ink2)
            }
            Spacer()
            Text(status).font(.footnote.weight(.semibold)).foregroundStyle(color)
        }
    }
}
