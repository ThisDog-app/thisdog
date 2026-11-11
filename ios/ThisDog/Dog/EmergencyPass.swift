import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Was auf der Seite hinter dem QR-Code steht – genau diese Felder gehen an den Server, sonst nichts.
struct EmergencySnapshot: Codable, Hashable {
    var name = "", breed = "", sex = "", age = "", chip = ""
    var ownerName = "", ownerPhone = "", vetName = "", vetPhone = ""
    var important = "", meds = "", note = ""
    var lostSince = "", lostWhere = "", lostNote = ""

    @MainActor
    init(store: DogStore) {
        let p = store.profile
        name = p.name
        breed = p.breed
        sex = p.sexLabel ?? ""
        age = p.age() ?? ""
        chip = p.chip
        ownerName = p.ownerName
        ownerPhone = p.ownerPhone
        vetName = p.vetName
        vetPhone = p.vetPhone
        important = p.allergies
        lostSince = p.lostSince
        lostWhere = p.lostWhere
        lostNote = p.lostNote
        // Nur, was gerade gegeben wird: ohne Enddatum oder bis heute oder später.
        let today = Day.today
        meds = store.meds
            .filter { m in Day(iso: m.to).map { $0 >= today } ?? true }
            .map { [$0.name, $0.dose].filter { !$0.isEmpty }.joined(separator: ", ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct EmergencyStatus: Decodable, Equatable {
    let active: Bool
    var url: URL?
    var updatedAt: Int?
    var views: Int?
    var lastViewAt: Int?
}

extension Account {
    private var stampKey: String { "notfallpass.stand.\(store.packID ?? 0)" }

    func emergencyStatus() async throws -> EmergencyStatus {
        try await api.get("emergency.php", ["action": "status", "pack": String(store.packID ?? 0)])
    }

    @discardableResult
    func publishEmergency() async throws -> EmergencyStatus {
        struct Body: Encodable { let pack: Int?; let card: EmergencySnapshot; let photo: String? }
        let card = EmergencySnapshot(store: store)
        let photo = store.avatars.first { $0.id == Avatar.dog }?.jpeg
        let status: EmergencyStatus = try await api.post("emergency.php", ["action": "publish"], body: Body(pack: store.packID, card: card, photo: photo))
        UserDefaults.standard.set(Self.stamp(card, photo), forKey: stampKey)
        return status
    }

    func revokeEmergency() async throws {
        struct Body: Encodable { let pack: Int? }
        let _: EmergencyStatus = try await api.post("emergency.php", ["action": "revoke"], body: Body(pack: store.packID))
        UserDefaults.standard.removeObject(forKey: stampKey)
    }

    /// Nach jedem Abgleich: Ist der Pass freigegeben und hat sich etwas geändert (Telefon, Foto, Medikament),
    /// bekommt die Seite den neuen Stand. Der QR-Code bleibt derselbe.
    func refreshEmergencyIfNeeded() async {
        guard let saved = UserDefaults.standard.string(forKey: stampKey) else { return }
        let now = Self.stamp(EmergencySnapshot(store: store), store.avatars.first { $0.id == Avatar.dog }?.jpeg)
        guard now != saved else { return }
        _ = try? await publishEmergency()
    }

    private static func stamp(_ card: EmergencySnapshot, _ photo: String?) -> String {
        let data = (try? JSONEncoder().encode(card)) ?? Data()
        return "\(data.hashValue)-\(photo?.count ?? 0)-\(photo?.suffix(32) ?? "")"
    }
}

enum QRCode {
    /// Scharf in jeder Größe: ein Pixel je Modul, vergrößert ohne Glätten.
    static func image(_ text: String, scale: CGFloat = 12) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Der Notfallpass: die Karte, wie sie ein Finder sieht, und der QR-Code, der dorthin führt.
struct EmergencyPassScreen: View {
    @Environment(DogStore.self) private var store
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var status: EmergencyStatus?
    @State private var working = false
    @State private var message: String?
    @State private var confirmsRevoke = false
    @State private var draft = DogProfile()
    /// Der Stand, von dem `draft` ausging: Gesichert wird nur, was hier geändert wurde – sonst schriebe ein offener
    /// Pass einen veralteten Namen zurück, wenn inzwischen das Profil des Rudels angekommen ist.
    @State private var base = DogProfile()
    @State private var reportsLost = false

    /// Nur die hier geänderten Felder, auf den aktuellen Stand.
    private func saveDraft() {
        let merged = store.profile.applying(edits: draft, since: base)
        if merged != store.profile { store.save(merged) }
        base = merged
        draft = merged
    }

    private var signedIn: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-notfall") { return true }
        #endif
        if case .signedIn = account.state { return true } else { return false }
    }

    var body: some View {
        TwoPane(parent: store.profile.name, title: String(localized: "Notfallpass"), rightFirst: true, close: { dismiss() }) {
            // Vorschau: Das Wichtigste auf dieser Seite ist der QR-Code in der anderen Spalte.
            VStack(alignment: .leading, spacing: 6) {
                Text("Ich heiße \(draft.name).").font(.display(40)).foregroundStyle(Palette.ink)
                    .lineLimit(2).minimumScaleFactor(0.7)
            }
            preview
        } right: {
            lost
            qr
            if let message { Text(message).font(.subheadline).foregroundStyle(Palette.kind(.health)) }
            fields
            Text("Ändert sich etwas, aktualisiert ThisDog die Seite. Der QR-Code bleibt gleich.")
                .font(.footnote).foregroundStyle(Palette.ink3)
        }
        .task { draft = store.profile; base = draft; await load() }
        // Kommt ein neuer Stand an und hier wurde nichts geändert, zeigt der Pass ihn.
        .onChange(of: store.profile) { _, now in if draft == base { draft = now; base = now } }
        // Kurz nach dem Tippen sichern, nicht bei jedem Buchstaben.
        .task(id: draft) {
            guard draft != base else { return }
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled else { return }
            saveDraft()
        }
        .onDisappear { if draft != base { saveDraft() } }
        .sheet(isPresented: $reportsLost) {
            LostDogSheet(profile: draft) { whereSeen, note, phone in
                if draft.ownerPhone.isEmpty { draft.ownerPhone = phone }
                draft.lostSince = LostDog.stamp(Date())
                draft.lostWhere = whereSeen
                draft.lostNote = note
                saveDraft()
                run {
                    try await account.ensureAccount()
                    status = try await account.publishEmergency()
                }
            }
        }
        .confirmationDialog("Notfallpass sperren?", isPresented: $confirmsRevoke, titleVisibility: .visible) {
            Button("Sperren", role: .destructive) { run { try await account.revokeEmergency(); status = EmergencyStatus(active: false) } }
        } message: {
            Text("Gedruckte QR-Codes führen dann ins Leere. Gibst du den Pass wieder frei, bekommt er einen neuen Code.")
        }
    }

    // MARK: Entlaufen

    /// Ganz oben: Ist der Hund weg, zählt nur noch der Steckbrief. Sonst ein ruhiger Knopf für den Ernstfall.
    @ViewBuilder
    private var lost: some View {
        if draft.isLost {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(draft.name) wird vermisst").font(.display(26, weight: .semibold)).foregroundStyle(.white)
                Text(LostDog.since(draft)).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                if let url = status?.url, status?.active == true {
                    ShareLink(item: LostDog.flyer(EmergencySnapshot(store: store), url: url)) {
                        Label("Steckbrief teilen", icon: "teilen").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .tint(.white).foregroundStyle(Palette.kind(.health))
                    Text("Für Nachbarn, Gassi-Gruppen, Tierheim und Tierärzte in der Nähe. Der Link zeigt Foto, Chipnummer und deine Nummer – und dass \(draft.name) vermisst wird.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.85))
                } else if working {
                    ProgressView().tint(.white)
                }
                Button("\(draft.name) ist wieder da") {
                    draft.lostSince = ""; draft.lostWhere = ""; draft.lostNote = ""
                    saveDraft()
                    run { status = try await account.publishEmergency() }
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.kind(.health), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            Button { reportsLost = true } label: {
                Label("\(draft.name.isEmpty ? String(localized: "Hund") : draft.name) ist entlaufen", icon: "notfall").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            .tint(Palette.kind(.health))
            .disabled(working)
        }
    }

    // MARK: Bearbeiten

    private var fields: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Was der Finder sieht").font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink)
            group(String(localized: "Wen anrufen?")) {
                field(String(localized: "Dein Name"), $draft.ownerName, content: .givenName)
                field(String(localized: "Telefon"), $draft.ownerPhone, keyboard: .phonePad, content: .telephoneNumber)
            }
            group(String(localized: "Wichtig")) {
                field(String(localized: "Allergien, Unverträglichkeiten"), $draft.allergies)
            }
            group(String(localized: "Chip")) {
                field(String(localized: "Chipnummer"), $draft.chip, keyboard: .numberPad)
            }
            group(String(localized: "Tierarzt")) {
                field(String(localized: "Praxis"), $draft.vetName)
                field(String(localized: "Telefon"), $draft.vetPhone, keyboard: .phonePad)
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
            c()
        }
    }

    private func field(_ title: String, _ text: Binding<String>, keyboard: UIKeyboardType = .default, content: UITextContentType? = nil) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .textContentType(content)
            .padding(14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: QR-Code

    @ViewBuilder
    private var qr: some View {
        if !signedIn {
            card {
                Text("Damit ein Finder die Seite öffnen kann, liegt sie auf thisdog.app. Dafür legt ThisDog ein Konto für dieses Telefon an, ohne E-Mail und ohne Passwort.")
                    .font(.subheadline).foregroundStyle(Palette.ink2)
                Button("Weiter") { run { try await account.ensureAccount(); await load() } }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(working)
            }
        } else if let status, status.active, let url = status.url {
            card {
                // In einer schmalen Spalte untereinander, statt Wörter zu trennen.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) { qrImage(url); qrState(status) }
                    VStack(alignment: .leading, spacing: 12) { qrImage(url); qrState(status) }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { qrButtons(url) }
                    VStack(alignment: .leading, spacing: 10) { qrButtons(url) }
                }
                .buttonBorderShape(.capsule)
                Button("Sperren", role: .destructive) { confirmsRevoke = true }.font(.subheadline)
            }
        } else if status != nil {
            card {
                Text("Mit einem QR-Code am Halsband sieht jeder, der \(store.profile.name) findet, wen er anrufen soll – ohne App, ohne Anmeldung. Wenn jemand den Pass öffnet, bekommt das Rudel eine Mitteilung.")
                    .font(.subheadline).foregroundStyle(Palette.ink2)
                Button { run { status = try await account.publishEmergency() } } label: {
                    Text("Notfallpass freigeben").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .disabled(working || store.profile.ownerPhone.isEmpty)
                if store.profile.ownerPhone.isEmpty {
                    Text("Trag zuerst eine Telefonnummer ein, sonst kann dich niemand anrufen.")
                        .font(.footnote).foregroundStyle(Palette.ink3)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func qrImage(_ url: URL) -> some View {
        if let img = QRCode.image(url.absoluteString) {
            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                .frame(width: 148, height: 148)
                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel("QR-Code zum Notfallpass")
        }
    }

    private func qrState(_ s: EmergencyStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Freigegeben").font(.headline).foregroundStyle(Palette.ink).fixedSize()
            Text(viewsLine(s)).font(.subheadline).foregroundStyle(Palette.ink2).frame(minWidth: 96, alignment: .leading)
        }
    }

    @ViewBuilder
    private func qrButtons(_ url: URL) -> some View {
        if let img = QRCode.image(url.absoluteString, scale: 24) {
            ShareLink(item: Image(uiImage: img), preview: SharePreview(String(localized: "Notfallpass von \(store.profile.name)"), image: Image(uiImage: img))) {
                Label("QR-Code teilen", icon: "teilen").lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderedProminent)
        }
        Link(destination: url) { Label("Seite ansehen", icon: "kompass").lineLimit(1).fixedSize() }.buttonStyle(.bordered)
    }

    private func viewsLine(_ s: EmergencyStatus) -> String {
        guard let n = s.views, n > 0 else { return String(localized: "Noch nicht geöffnet.") }
        let when = s.lastViewAt.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(.relative(presentation: .named)) } ?? ""
        return n == 1 ? String(localized: "Einmal geöffnet, \(when).") : String(localized: "\(n)-mal geöffnet, zuletzt \(when).")
    }

    // MARK: Vorschau

    private var preview: some View {
        let s = EmergencySnapshot(store: store)
        return VStack(alignment: .leading, spacing: 12) {
            Text("So sieht es der Finder").font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink)
            if !s.ownerPhone.isEmpty {
                Text("\(s.ownerName.isEmpty ? "Anrufen" : "\(s.ownerName) anrufen")  \(s.ownerPhone)")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.accent, in: Capsule())
            }
            if !s.important.isEmpty || !s.meds.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if !s.important.isEmpty { row(String(localized: "Wichtig"), s.important, alarm: true) }
                    if !s.meds.isEmpty { row(String(localized: "Medikamente"), s.meds, alarm: true) }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.kind(.health).opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 10) {
                row(String(localized: "Chipnummer"), s.chip.isEmpty ? String(localized: "nicht eingetragen") : s.chip)
                row(String(localized: "Tierarzt"), [s.vetName, s.vetPhone].filter { !$0.isEmpty }.joined(separator: "\n").isEmpty ? String(localized: "nicht eingetragen") : [s.vetName, s.vetPhone].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func row(_ label: String, _ value: String, alarm: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(alarm ? Palette.kind(.health) : Palette.ink2)
            Text(value).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 16, content: c)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-notfall") {
            status = EmergencyStatus(active: true, url: URL(string: "https://thisdog.app/notfall/Beispiel4Dv25Q20hzybK"), updatedAt: nil, views: 0, lastViewAt: nil)
            return
        }
        #endif
        guard signedIn else { return }
        do {
            var s = try await account.emergencyStatus()
            if s.active { await account.refreshEmergencyIfNeeded(); s = (try? await account.emergencyStatus()) ?? s }
            status = s
        } catch {
            message = String(localized: "Der Stand des Passes ließ sich nicht laden. Prüf die Verbindung.")
            status = EmergencyStatus(active: false)
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        message = nil
        Task {
            do { try await work() } catch { message = String(localized: "Das hat nicht geklappt. Versuch es gleich noch einmal.") }
            working = false
        }
    }
}
