import Foundation
import UIKit

/// Das Profil des Hundes – ein einzelner Datensatz (Art „profile“, Kennung „profile“), Felder wie in der Web-App.
struct DogProfile: Codable, Hashable, Sendable {
    var name = ""
    var breed = ""
    /// „JJJJ-MM-TT“
    var birthdate = ""
    var chip = ""
    /// „f“ Hündin, „m“ Rüde, leer: keine Angabe.
    var sex = ""
    var weightKg: Double?
    var targetWeightKg: Double?
    /// „low“, „normal“, „high“
    var activity = "normal"
    var neutered = false
    var vetName = ""
    var vetPhone = ""
    var allergies = ""
    var ownerName = ""
    var ownerPhone = ""
    /// Trägt einen AirTag oder einen Tracker für „Wo ist?“ – dann bietet Gassi den Weg dorthin an.
    var tracker = false
    /// Entlaufen: seit wann („JJJJ-MM-TTTHH:MM“, leer = alles gut), wo zuletzt gesehen, was ein Finder wissen sollte.
    /// Steht im Profil, damit das ganze Rudel es sofort sieht.
    var lostSince = ""
    var lostWhere = ""
    var lostNote = ""
    var u: Double = 0

    enum CodingKeys: String, CodingKey {
        case name, breed, birthdate, chip, sex, weightKg, targetWeightKg, activity, neutered
        case vetName, vetPhone, allergies, ownerName, ownerPhone, tracker, lostSince, lostWhere, lostNote, u
    }

    var isLost: Bool { !lostSince.isEmpty }

    init() {}

    /// Fehlende Felder sind leer statt eines Fehlers – ältere Fassungen kannten nicht alle.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? "" }
        name = s(.name); breed = s(.breed); birthdate = s(.birthdate); chip = s(.chip); sex = s(.sex)
        weightKg = (try? c.decodeIfPresent(Double.self, forKey: .weightKg)) ?? nil
        targetWeightKg = (try? c.decodeIfPresent(Double.self, forKey: .targetWeightKg)) ?? nil
        activity = s(.activity).isEmpty ? "normal" : s(.activity)
        neutered = ((try? c.decodeIfPresent(Bool.self, forKey: .neutered)) ?? nil) ?? false
        vetName = s(.vetName); vetPhone = s(.vetPhone); allergies = s(.allergies)
        ownerName = s(.ownerName); ownerPhone = s(.ownerPhone)
        tracker = ((try? c.decodeIfPresent(Bool.self, forKey: .tracker)) ?? nil) ?? false
        lostSince = s(.lostSince); lostWhere = s(.lostWhere); lostNote = s(.lostNote)
        u = ((try? c.decodeIfPresent(Double.self, forKey: .u)) ?? nil) ?? 0
    }

    /// Übernimmt die Felder, die `draft` gegenüber `base` geändert hat – alles andere bleibt, wie es jetzt ist.
    func applying(edits draft: DogProfile, since base: DogProfile) -> DogProfile {
        let enc = JSONEncoder()
        func dict(_ p: DogProfile) -> [String: Any] {
            (try? enc.encode(p)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        var out = dict(self)
        let b = dict(base), d = dict(draft)
        for key in Set(b.keys).union(d.keys) where key != "u" {
            let before = b[key].map { "\($0)" }, after = d[key].map { "\($0)" }
            if before != after { out[key] = d[key] ?? NSNull() }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out),
              var merged = try? JSONDecoder().decode(DogProfile.self, from: data) else { return draft }
        merged.u = u
        return merged
    }

    var birthDay: Day? { Day(iso: birthdate) }
    var sexLabel: String? { sex == "f" ? String(localized: "Hündin") : sex == "m" ? String(localized: "Rüde") : nil }

    static let activities: [(String, String)] = [
        ("low", String(localized: "Ruhig, kurze Runden")),
        ("normal", String(localized: "Normal, täglich unterwegs")),
        ("high", String(localized: "Sehr aktiv, Sport und lange Touren")),
    ]

    /// „3 Jahre, 4 Monate“
    func age(on today: Day = .today) -> String? {
        guard let b = birthDay else { return nil }
        var months = (today.year - b.year) * 12 + (today.month - b.month)
        if today.day < b.day { months -= 1 }
        if months < 0 { return nil }
        let y = months / 12, m = months % 12
        let mt = m == 1 ? String(localized: "1 Monat") : String(localized: "\(m) Monate")
        if y == 0 { return mt }
        let yt = y == 1 ? String(localized: "1 Jahr") : String(localized: "\(y) Jahre")
        return m == 0 ? yt : "\(yt), \(mt)"
    }

    /// Lebensphase wie in der Web-App: große Hunde altern früher.
    func stage(on today: Day = .today) -> String? {
        guard let b = birthDay else { return nil }
        let months = Double(b.days(until: today)) / 30.44
        if months < 12 { return String(localized: "Welpe") }
        let seniorAt: Double = switch weightKg ?? 0 {
        case 40...: 72
        case 25...: 84
        case 0.1...: 108
        default: 96
        }
        return months >= seniorAt ? String(localized: "Senior") : String(localized: "Erwachsen")
    }
}

/// Ein Eintrag im Gewichtsverlauf. Je Tag einer; die Kennung ist der Tag (wie in der Web-App).
struct WeightEntry: Codable, Hashable, Sendable {
    var d: String
    var kg: Double
    var u: Double = 0
}

struct Vaccination: Codable, Hashable, Sendable {
    var id: String
    var name = ""
    var date = ""
    var next = ""
    var notes = ""
    var u: Double = 0
}

struct Deworming: Codable, Hashable, Sendable {
    var id: String
    var product = ""
    var date = ""
    var next = ""
    var u: Double = 0
}

struct Medication: Codable, Hashable, Sendable {
    var id: String
    var name = ""
    var dose = ""
    var from = ""
    var to = ""
    var u: Double = 0
}

/// Ein Eintrag im Gesundheitstagebuch: was auffiel und wann, auf Wunsch mit Foto. Beim Tierarzt zeigt man dann den
/// Verlauf, statt zu raten, ob es letzte oder vorletzte Woche war.
struct HealthNote: Codable, Hashable, Sendable, Identifiable {
    var id: String
    /// „JJJJ-MM-TT“
    var d = ""
    /// „HH:mm“ oder leer
    var time = ""
    var tags: [String] = []
    var text = ""
    /// Kleines JPEG als Base64 – geht verschlüsselt durch den Abgleich wie die Bilder der Rudelmitglieder.
    var photo: String?
    var u: Double = 0

    enum CodingKeys: String, CodingKey { case id, d, time, tags, text, photo, u }

    init(id: String = newHealthID("notes"), d: String = Day.today.iso) { self.id = id; self.d = d }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        d = ((try? c.decodeIfPresent(String.self, forKey: .d)) ?? nil) ?? ""
        time = ((try? c.decodeIfPresent(String.self, forKey: .time)) ?? nil) ?? ""
        tags = ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil) ?? []
        text = ((try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil) ?? ""
        photo = (try? c.decodeIfPresent(String.self, forKey: .photo)) ?? nil
        u = ((try? c.decodeIfPresent(Double.self, forKey: .u)) ?? nil) ?? 0
    }

    /// Was am häufigsten vorkommt – ein Tipp statt Tippen.
    static let presets: [String] = [
        String(localized: "Erbrochen"), String(localized: "Durchfall"), String(localized: "Frisst nicht"),
        String(localized: "Humpelt"), String(localized: "Juckreiz"), String(localized: "Husten"),
        String(localized: "Zecke"), String(localized: "Verletzung"), String(localized: "Schlapp"),
    ]

    var day: Day? { Day(iso: d) }
    var headline: String { tags.isEmpty ? (text.isEmpty ? String(localized: "Notiz") : text) : tags.joined(separator: ", ") }

    /// Ein Foto, klein genug für den Abgleich: lange Seite höchstens 900 px, so stark komprimiert wie nötig.
    static func preparePhoto(_ image: UIImage) -> String? {
        for side in [900.0, 700.0, 520.0] {
            let k = min(1, side / max(image.size.width, image.size.height))
            let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
            let small = UIGraphicsImageRenderer(size: size, format: .photo).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            for q in [0.7, 0.55, 0.4, 0.3] {
                if let s = small.jpegData(compressionQuality: q)?.base64EncodedString(), s.count <= 60_000 { return s }
            }
        }
        return nil
    }
}

extension DogProfile: SyncedItem {
    static let kind = "profile"
    var id: String { "profile" }
}
extension WeightEntry: SyncedItem {
    static let kind = "weight"
    var id: String { d }
}
extension Vaccination: SyncedItem { static let kind = "vaccinations" }
extension Deworming: SyncedItem { static let kind = "deworming" }
extension Medication: SyncedItem { static let kind = "meds" }
extension HealthNote: SyncedItem { static let kind = "notes" }

/// Eine Fälligkeit aus den Gesundheitsdaten: wann zuletzt, wann wieder.
struct HealthDue: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: String
    let last: Day?
    let due: Day

    /// Wie viel vom Abstand zwischen letztem Mal und Fälligkeit vergangen ist (0…1); `nil` ohne letztes Datum.
    func progress(on today: Day = .today) -> Double? {
        guard let last, last < due else { return nil }
        return min(1, max(0, Double(last.days(until: today)) / Double(last.days(until: due))))
    }
}

func newHealthID(_ prefix: String) -> String { DogEvent.newID().replacingOccurrences(of: "evt_", with: "\(prefix)_") }
