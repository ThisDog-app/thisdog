import CoreLocation
import MapKit
import SwiftUI

/// Hund entlaufen: Der Notfallpass wird zum Steckbrief, das Rudel sieht es sofort, und ein Text zum Teilen
/// steht bereit – für Nachbarn, Gassi-Gruppen, Tierheim und Tierärzte.
enum LostDog {
    /// „2026-11-09T14:30“ in Ortszeit – so liest es auch die Seite auf thisdog.app.
    static func stamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    static func date(_ stamp: String) -> Date? {
        let parts = stamp.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        var c = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        if parts.count >= 5 { c.hour = parts[3]; c.minute = parts[4] }
        return Calendar.current.date(from: c)
    }

    /// „Seit heute, 14:30 Uhr · zuletzt gesehen: Augarten“
    static func since(_ p: DogProfile) -> String {
        var out: [String] = []
        if let d = date(p.lostSince) {
            let day = Calendar.current.isDateInToday(d) ? String(localized: "heute")
                : Calendar.current.isDateInYesterday(d) ? String(localized: "gestern")
                : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            out.append(String(localized: "Seit \(day), \(d.formatted(date: .omitted, time: .shortened)) Uhr"))
        }
        if !p.lostWhere.isEmpty { out.append(String(localized: "zuletzt gesehen: \(p.lostWhere)")) }
        return out.joined(separator: " · ")
    }

    /// Der Text zum Teilen. Kurz, das Wichtigste zuerst, die Nummer zum Antippen, der Link mit Foto am Ende.
    static func flyer(_ s: EmergencySnapshot, url: URL) -> String {
        var p = DogProfile()
        p.lostSince = s.lostSince; p.lostWhere = s.lostWhere
        let facts = [s.breed, s.sex, s.age].filter { !$0.isEmpty }.joined(separator: ", ")
        var lines = [String(localized: "\(s.name) wird vermisst!")]
        let when = since(p)
        if !when.isEmpty { lines.append(when.prefix(1).uppercased() + when.dropFirst() + ".") }
        if !facts.isEmpty { lines.append(facts + ".") }
        if !s.lostNote.isEmpty { lines.append(s.lostNote) }
        if !s.ownerPhone.isEmpty {
            lines.append(String(localized: "Bitte sofort anrufen: \([s.ownerName, s.ownerPhone].filter { !$0.isEmpty }.joined(separator: ", "))"))
        }
        lines.append(String(localized: "Nicht hinterherrennen – ängstliche Hunde laufen sonst weiter weg."))
        lines.append(String(localized: "Foto und Chipnummer: \(url.absoluteString)"))
        return lines.joined(separator: "\n")
    }
}

/// Der erste Schritt im Ernstfall: wo zuletzt gesehen, was ein Finder wissen muss, unter welcher Nummer.
struct LostDogSheet: View {
    let profile: DogProfile
    /// Ort, Hinweis, Telefon (falls es im Profil noch fehlte)
    let report: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(WalkRecorder.self) private var recorder

    @State private var whereSeen = ""
    @State private var note = ""
    @State private var phone = ""
    @State private var locating = false

    private var name: String { profile.name.isEmpty ? String(localized: "dein Hund") : profile.name }
    private var canReport: Bool { !(profile.ownerPhone.isEmpty && phone.trimmingCharacters(in: .whitespaces).isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Der Notfallpass wird zum Steckbrief: Wer den QR-Code am Halsband scannt oder den Link bekommt, sieht sofort, dass \(name) vermisst wird. Dein Rudel sieht es auch.")
                        .font(.subheadline).foregroundStyle(Palette.ink2)
                }
                Section {
                    TextField("z. B. Augarten, beim Spielplatz", text: $whereSeen, axis: .vertical)
                    Button {
                        Task { await locate() }
                    } label: {
                        Label(locating ? String(localized: "Ort wird gesucht …") : String(localized: "Mein Standort"), icon: "kompass")
                    }
                    .disabled(locating)
                } header: { Text("Wo zuletzt gesehen?") }
                Section {
                    TextField("z. B. Ängstlich, nicht rufen. Rotes Halsband.", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: { Text("Was ein Finder wissen sollte") }
                if profile.ownerPhone.isEmpty {
                    Section {
                        TextField("Telefon", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    } header: { Text("Unter welcher Nummer?") } footer: {
                        Text("Ohne Nummer kann dich niemand anrufen.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(String(localized: "\(name) ist entlaufen")) {
                BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                BarTextItem(title: String(localized: "Melden"), disabled: !canReport) {
                    report(whereSeen.trimmingCharacters(in: .whitespacesAndNewlines), note.trimmingCharacters(in: .whitespacesAndNewlines),
                           phone.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
            }
            .onAppear { note = profile.lostNote }
        }
        .tint(Palette.accent)
    }

    /// Der aktuelle oder zuletzt bekannte Ort als Adresse („Obere Augartenstraße, Wien“).
    private func locate() async {
        locating = true
        defer { locating = false }
        if recorder.isAuthorized { recorder.locateOnce() }
        try? await Task.sleep(for: .seconds(1))
        guard let c = recorder.here ?? LastPlace.load(),
              let request = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)),
              let item = try? await request.mapItems.first else { return }
        whereSeen = item.address?.shortAddress ?? item.name ?? whereSeen
    }
}

/// Auf „Heute“ ganz oben, für alle im Rudel, solange der Hund vermisst wird.
struct LostDogBanner: View {
    @Environment(DogStore.self) private var store
    let open: () -> Void

    var body: some View {
        let p = store.profile
        if p.isLost {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(p.name) wird vermisst").font(.display(24, weight: .semibold))
                    Text(LostDog.since(p)).font(.subheadline.weight(.medium)).opacity(0.9)
                    Text("Steckbrief teilen").font(.subheadline.weight(.semibold)).underline()
                }
                .foregroundStyle(.white)
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.kind(.health), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
