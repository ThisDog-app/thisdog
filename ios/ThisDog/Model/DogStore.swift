import CoreLocation
import CryptoKit
import Foundation
import Observation
import UIKit

/// Ein Datensatz, der abgeglichen wird: Termine, Runden, später Gesundheitsdaten.
/// `kind` ist die Art im Abgleich (`api/sync.php`, KINDS), `u` der Zeitpunkt der letzten Änderung in ms.
protocol SyncedItem: Codable, Identifiable, Sendable where ID == String {
    static var kind: String { get }
    var u: Double { get set }
}

extension DogEvent: SyncedItem { static let kind = "event" }
extension Walk: SyncedItem { static let kind = "walk" }

/// Die Daten des Hundes auf diesem Gerät. Gespeichert als eine JSON-Datei im Format der Web-App,
/// damit der Abgleich (`api/sync.php`) dieselben Datensätze bekommt.
@MainActor
@Observable
final class DogStore {
    private(set) var events: [DogEvent] = []
    private(set) var walks: [Walk] = []
    /// Höchstens ein Eintrag – das Profil läuft durch dieselbe Maschine wie die Listen.
    private(set) var profiles: [DogProfile] = []
    private(set) var weights: [WeightEntry] = []
    private(set) var vaccinations: [Vaccination] = []
    private(set) var dewormings: [Deworming] = []
    private(set) var meds: [Medication] = []
    private(set) var notes: [HealthNote] = []
    private(set) var toolSettings: [ToolSettings] = []
    private(set) var favorites: [FavoriteFood] = []
    private(set) var tipChecks: [TipChecks] = []
    private(set) var avatars: [Avatar] = []
    private(set) var friendKeys: [FriendKey] = []
    private(set) var checkIns: [CheckIn] = []
    /// Entschlüsselte Bilder, nach Datensatz und Stand.
    @ObservationIgnored private var avatarCache: [String: (u: Double, image: UIImage)] = [:]
    private(set) var tips: [Tip] = []
    /// Lebensmittel aus dem Inhaltsspeicher – mitgeliefert, vom Server aktualisierbar.
    private(set) var foods: [Food] = []
    @ObservationIgnored private(set) var foodSearch = FoodSearch([])
    /// Löschungen für den Abgleich: „<Art>:<id>“ → Zeitpunkt in ms.
    private(set) var graves: [String: Double] = [:]
    private(set) var seasonal: [SeasonalHint] = []

    /// Abgleich: in welchem Rudel die Daten liegen, bis zu welcher Revision gelesen wurde,
    /// was seit dem letzten Abgleich geändert ist, und wer im Rudel zuletzt etwas geändert hat.
    private(set) var packID: Int?
    private(set) var rev = 0
    private(set) var dirty: Set<String> = []
    private(set) var changedBy: [String: Int] = [:]

    /// Wird nach jeder Änderung an Terminen gerufen (Systemkalender, Erinnerungen).
    @ObservationIgnored var onEventsChanged: (([DogEvent]) -> Void)?
    /// Nur bei Änderungen auf diesem Gerät – sie lösen einen Abgleich aus, eingehende nicht.
    @ObservationIgnored var onLocalChange: (() -> Void)?

    @ObservationIgnored let content = ContentStore()
    @ObservationIgnored private let file: URL

    private struct Saved: Codable {
        var events: [DogEvent] = []
        var walks: [Walk]?
        var profiles: [DogProfile]?
        var weights: [WeightEntry]?
        var vaccinations: [Vaccination]?
        var dewormings: [Deworming]?
        var meds: [Medication]?
        var notes: [HealthNote]?
        var toolSettings: [ToolSettings]?
        var favorites: [FavoriteFood]?
        var tipChecks: [TipChecks]?
        var avatars: [Avatar]?
        var friendKeys: [FriendKey]?
        var checkIns: [CheckIn]?
        var graves: [String: Double] = [:]
        var packID: Int?
        var rev: Int?
        var dirty: Set<String>?
        var changedBy: [String: Int]?
    }

    init(file: URL = URL.applicationSupportDirectory.appending(path: "thisdog.json")) {
        self.file = file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            events = saved.events
            walks = saved.walks ?? []
            profiles = saved.profiles ?? []
            weights = saved.weights ?? []
            vaccinations = saved.vaccinations ?? []
            dewormings = saved.dewormings ?? []
            meds = saved.meds ?? []
            notes = saved.notes ?? []
            toolSettings = saved.toolSettings ?? []
            favorites = saved.favorites ?? []
            tipChecks = saved.tipChecks ?? []
            avatars = saved.avatars ?? []
            friendKeys = saved.friendKeys ?? []
            checkIns = saved.checkIns ?? []
            graves = saved.graves
            packID = saved.packID
            rev = saved.rev ?? 0
            dirty = saved.dirty ?? []
            changedBy = saved.changedBy ?? [:]
        }
        seasonal = content.seasonalHints()
        loadFoods()
        loadTips()
    }

    private func loadTips() {
        tips = content.data(.tips).flatMap { try? JSONDecoder().decode([Tip].self, from: $0) } ?? []
    }

    var checks: TipChecks { tipChecks.first ?? TipChecks() }

    func toggleCheck(_ tip: Tip, _ index: Int) {
        var c = checks
        var list = c.bySlug[tip.slug] ?? []
        let count = tip.checklist?.count ?? 0
        if list.count < count { list += [Bool](repeating: false, count: count - list.count) }
        guard index < list.count else { return }
        list[index].toggle()
        c.bySlug[tip.slug] = list
        upsert(c, \.tipChecks)
    }

    private func loadFoods() {
        foods = content.data(.foods).flatMap { try? JSONDecoder().decode([Food].self, from: $0) } ?? []
        foodSearch = FoodSearch(foods)
    }

    func isFavorite(_ f: Food) -> Bool { favorites.contains { $0.name == f.name } }

    func toggleFavorite(_ f: Food) {
        if isFavorite(f) { remove(FavoriteFood.self, id: f.name, \.favorites) } else { upsert(FavoriteFood(name: f.name), \.favorites) }
    }

    var entries: [CalendarEntry] {
        CalendarBuilder.all(events: events, seasonal: seasonal) + CalendarBuilder.dogEntries(profile: profile, dues: dues)
    }

    // MARK: Bilder

    func avatarImage(_ id: String) -> UIImage? {
        guard let a = avatars.first(where: { $0.id == id }) else { return nil }
        if let hit = avatarCache[id], hit.u == a.u { return hit.image }
        guard let data = Data(base64Encoded: a.jpeg), let image = UIImage(data: data) else { return nil }
        avatarCache[id] = (a.u, image)
        return image
    }

    /// Setzt ein Bild aus der Fotomediathek; `nil` entfernt es.
    func setAvatar(_ id: String, photo: Data?) {
        if let photo, let jpeg = Avatar.prepare(photo) {
            upsert(Avatar(id: id, jpeg: jpeg), \.avatars)
        } else if photo == nil {
            remove(Avatar.self, id: id, \.avatars)
        }
    }

    // MARK: Hundefreunde

    func friendKey(invite: String) -> FriendKey? { friendKeys.first { $0.id == invite } }

    func saveFriendKey(invite: String, key: SymmetricKey) {
        upsert(FriendKey(id: invite, key: Sealing.encode(key)), \.friendKeys)
    }

    func removeFriendKey(invite: String) { remove(FriendKey.self, id: invite, \.friendKeys) }

    func save(_ c: CheckIn) { upsert(c, \.checkIns) }
    func removeCheckIn(_ c: CheckIn) { remove(CheckIn.self, id: c.id, \.checkIns) }

    // MARK: Termine

    func save(_ event: DogEvent) { upsert(event, \.events) }
    func delete(id: String) { remove(DogEvent.self, id: id, \.events) }
    func event(id: String) -> DogEvent? { events.first { $0.id == id } }

    // MARK: Runden

    func save(_ walk: Walk) { upsert(walk, \.walks) }
    func deleteWalk(id: String) { remove(Walk.self, id: id, \.walks) }

    // MARK: Hund

    /// Der Name ohne Leerzeichen am Rand: Ältere Android-Fassungen speicherten ihn ungekürzt („Stella s letzte Runde“).
    var profile: DogProfile {
        var p = profiles.first ?? DogProfile()
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return p
    }
    var hasProfile: Bool { !profile.name.isEmpty }

    func save(_ p: DogProfile) { upsert(p, \.profiles) }

    /// Ein Gewicht je Tag; ein zweites am selben Tag ersetzt das erste. Das Profil folgt dem jüngsten.
    func saveWeight(_ kg: Double, on day: Day = .today) {
        upsert(WeightEntry(d: day.iso, kg: kg), \.weights)
        if let latest = weights.max(by: { $0.d < $1.d }), latest.kg != profile.weightKg {
            var p = profile
            p.weightKg = latest.kg
            save(p)
        }
    }
    func deleteWeight(day: String) { remove(WeightEntry.self, id: day, \.weights) }

    func save(_ v: Vaccination) { upsert(v, \.vaccinations) }
    func deleteVaccination(id: String) { remove(Vaccination.self, id: id, \.vaccinations) }
    func save(_ d: Deworming) { upsert(d, \.dewormings) }
    func deleteDeworming(id: String) { remove(Deworming.self, id: id, \.dewormings) }
    func save(_ m: Medication) { upsert(m, \.meds) }
    func deleteMedication(id: String) { remove(Medication.self, id: id, \.meds) }
    func save(_ n: HealthNote) { upsert(n, \.notes) }
    func deleteNote(id: String) { remove(HealthNote.self, id: id, \.notes) }

    var settings: ToolSettings { toolSettings.first ?? ToolSettings() }
    func save(_ t: ToolSettings) { upsert(t, \.toolSettings) }

    /// Was in den Gesundheitsdaten fällig wird, aufsteigend.
    var dues: [HealthDue] {
        var out: [HealthDue] = []
        for v in vaccinations { if let due = Day(iso: v.next) { out.append(HealthDue(id: "due_\(v.id)", title: v.name.isEmpty ? String(localized: "Impfung") : v.name, kind: "Impfung", last: Day(iso: v.date), due: due)) } }
        for d in dewormings { if let due = Day(iso: d.next) { out.append(HealthDue(id: "due_\(d.id)", title: d.product.isEmpty ? String(localized: "Entwurmung") : d.product, kind: "Entwurmung", last: Day(iso: d.date), due: due)) } }
        for m in meds { if let due = Day(iso: m.to) { out.append(HealthDue(id: "due_\(m.id)", title: m.name.isEmpty ? String(localized: "Medikament") : m.name, kind: "Medikament endet", last: Day(iso: m.from), due: due)) } }
        return out.sorted { $0.due < $1.due }
    }

    /// Fälligkeiten, die sich abhaken lassen (Impfung, Entwurmung).
    var markableDueIDs: Set<String> {
        Set(vaccinations.filter { !$0.next.isEmpty }.map { "due_\($0.id)" } + dewormings.filter { !$0.next.isEmpty }.map { "due_\($0.id)" })
    }

    /// Abhaken lässt sich, was sich wiederholt (Impfung, Entwurmung) und in den nächsten zwei Wochen fällig ist
    /// oder schon überfällig. Medikamente haben nur Beginn und Ende, keine einzelnen Gaben.
    func canMarkDone(_ due: HealthDue, today: Day = .today) -> Bool {
        let repeats = vaccinations.contains { "due_\($0.id)" == due.id } || dewormings.contains { "due_\($0.id)" == due.id }
        return repeats && today.days(until: due.due) <= 14
    }

    /// Impfung oder Entwurmung erledigt: ein neuer Eintrag von heute, der wieder im bisherigen Abstand fällig wird
    /// (ohne bekannten Abstand: Impfung nach einem Jahr, Entwurmung nach drei Monaten). Der alte Eintrag bleibt
    /// als Verlauf, ist aber nicht mehr fällig.
    @discardableResult
    func markDone(_ dueID: String, today: Day = .today) -> Bool {
        func next(from date: String, to due: String, fallback: Day) -> String {
            guard let a = Day(iso: date), let b = Day(iso: due), a < b else { return fallback.iso }
            return today.adding(days: a.days(until: b)).iso
        }
        // Nur, was noch fällig ist: Ein zweiter Tipp (Watch und iPhone, zwei im Rudel) legt sonst eine zweite Auffrischung an.
        if var v = vaccinations.first(where: { "due_\($0.id)" == dueID }), !v.next.isEmpty {
            let renewed = Vaccination(id: newHealthID("vaccinations"), name: v.name, date: today.iso,
                                      next: next(from: v.date, to: v.next, fallback: today.adding(years: 1)), notes: "")
            v.next = ""
            save(v)
            save(renewed)
            return true
        }
        if var d = dewormings.first(where: { "due_\($0.id)" == dueID }), !d.next.isEmpty {
            let renewed = Deworming(id: newHealthID("deworming"), product: d.product, date: today.iso,
                                    next: next(from: d.date, to: d.next, fallback: today.adding(months: 3)))
            d.next = ""
            save(d)
            save(renewed)
            return true
        }
        return false
    }

    /// Wer die Runde gelaufen ist, wenn es jemand anderes im Rudel war.
    func changer(of item: some SyncedItem) -> Int? { changedBy["\(type(of: item).kind):\(item.id)"] }

    /// Neue Inhalte vom Server übernehmen.
    func refreshContent(force: Bool = false) async {
        let changed = await content.refresh(force: force)
        if changed.contains(.publicEvents) { seasonal = content.seasonalHints() }
        if changed.contains(.foods) { loadFoods() }
        if changed.contains(.tips) { loadTips() }
    }

    // MARK: Allgemein

    private func upsert<T: SyncedItem>(_ item: T, _ list: ReferenceWritableKeyPath<DogStore, [T]>) {
        var e = item
        e.u = Date().timeIntervalSince1970 * 1000
        if let i = self[keyPath: list].firstIndex(where: { $0.id == e.id }) { self[keyPath: list][i] = e } else { self[keyPath: list].append(e) }
        let key = "\(T.kind):\(e.id)"
        graves[key] = nil
        dirty.insert(key)
        changedBy[key] = nil
        persist()
        onLocalChange?()
    }

    private func remove<T: SyncedItem>(_ type: T.Type, id: String, _ list: ReferenceWritableKeyPath<DogStore, [T]>) {
        self[keyPath: list].removeAll { $0.id == id }
        let key = "\(T.kind):\(id)"
        graves[key] = Date().timeIntervalSince1970 * 1000
        dirty.insert(key)
        persist()
        onLocalChange?()
    }

    private func stamp(of key: String) -> Double? {
        let (kind, id) = Self.split(key)
        switch kind {
        case DogEvent.kind: return events.first { $0.id == id }?.u ?? graves[key]
        case Walk.kind: return walks.first { $0.id == id }?.u ?? graves[key]
        case DogProfile.kind: return profiles.first?.u ?? graves[key]
        case WeightEntry.kind: return weights.first { $0.id == id }?.u ?? graves[key]
        case Vaccination.kind: return vaccinations.first { $0.id == id }?.u ?? graves[key]
        case Deworming.kind: return dewormings.first { $0.id == id }?.u ?? graves[key]
        case Medication.kind: return meds.first { $0.id == id }?.u ?? graves[key]
        case HealthNote.kind: return notes.first { $0.id == id }?.u ?? graves[key]
        case ToolSettings.kind: return toolSettings.first?.u ?? graves[key]
        case FavoriteFood.kind: return favorites.first { $0.id == id }?.u ?? graves[key]
        case TipChecks.kind: return tipChecks.first?.u ?? graves[key]
        case Avatar.kind: return avatars.first { $0.id == id }?.u ?? graves[key]
        case FriendKey.kind: return friendKeys.first { $0.id == id }?.u ?? graves[key]
        case CheckIn.kind: return checkIns.first { $0.id == id }?.u ?? graves[key]
        default: return graves[key]
        }
    }

    private static func split(_ key: String) -> (String, String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : ("", key)
    }

    private var allKeys: [String] {
        events.map { "\(DogEvent.kind):\($0.id)" } + walks.map { "\(Walk.kind):\($0.id)" }
            + profiles.map { "\(DogProfile.kind):\($0.id)" } + weights.map { "\(WeightEntry.kind):\($0.id)" }
            + vaccinations.map { "\(Vaccination.kind):\($0.id)" } + dewormings.map { "\(Deworming.kind):\($0.id)" }
            + meds.map { "\(Medication.kind):\($0.id)" } + notes.map { "\(HealthNote.kind):\($0.id)" } + toolSettings.map { "\(ToolSettings.kind):\($0.id)" }
            + favorites.map { "\(FavoriteFood.kind):\($0.id)" } + tipChecks.map { "\(TipChecks.kind):\($0.id)" }
            + avatars.map { "\(Avatar.kind):\($0.id)" } + friendKeys.map { "\(FriendKey.kind):\($0.id)" }
            + checkIns.map { "\(CheckIn.kind):\($0.id)" }
    }

    // MARK: Abgleich

    /// Was seit dem letzten Abgleich geändert wurde, im Format des Servers.
    func outgoingRecords() -> [SyncRecord] {
        var out: [SyncRecord] = []
        for key in dirty.sorted() {
            let (kind, id) = Self.split(key)
            let payload: JSONValue?? = switch kind {
            case DogEvent.kind: event(id: id).map { try? JSONValue.from($0) }
            case Walk.kind: walks.first { $0.id == id }.map { try? JSONValue.from($0) }
            case DogProfile.kind: profiles.first.map { try? JSONValue.from($0) }
            case WeightEntry.kind: weights.first { $0.id == id }.map { try? JSONValue.from($0) }
            case Vaccination.kind: vaccinations.first { $0.id == id }.map { try? JSONValue.from($0) }
            case Deworming.kind: dewormings.first { $0.id == id }.map { try? JSONValue.from($0) }
            case Medication.kind: meds.first { $0.id == id }.map { try? JSONValue.from($0) }
            case HealthNote.kind: notes.first { $0.id == id }.map { try? JSONValue.from($0) }
            case ToolSettings.kind: toolSettings.first.map { try? JSONValue.from($0) }
            case FavoriteFood.kind: favorites.first { $0.id == id }.map { try? JSONValue.from($0) }
            case TipChecks.kind: tipChecks.first.map { try? JSONValue.from($0) }
            case Avatar.kind: avatars.first { $0.id == id }.map { try? JSONValue.from($0) }
            case FriendKey.kind: friendKeys.first { $0.id == id }.map { try? JSONValue.from($0) }
            case CheckIn.kind: checkIns.first { $0.id == id }.map { try? JSONValue.from($0) }
            default: nil
            }
            // `payload` ist doppelt optional: außen „gibt es den Datensatz“, innen „ließ er sich kodieren“. Was sich nicht
            // kodieren lässt, darf nicht als Löschung hinausgehen – es bleibt offen.
            if case .some(.none) = payload { continue }
            if let payload = payload ?? nil, let stamp = stamp(of: key) {
                out.append(SyncRecord(kind: kind, id: id, updatedAt: stamp, payload: payload))
            } else if let when = graves[key] {
                out.append(SyncRecord(kind: kind, id: id, updatedAt: when, payload: nil))
            }
        }
        return out
    }

    /// Übernimmt, was der Server liefert. Die jüngere Fassung gewinnt – wie auf dem Server.
    /// Was gerade abgeschickt wurde, ist danach nicht mehr offen.
    func applyIncoming(_ records: [SyncRecord], rev newRev: Int, sent: [SyncRecord]) {
        // Erledigt ist nur, was seit dem Abschicken nicht noch einmal geändert wurde.
        for r in sent {
            let key = "\(r.kind):\(r.id)"
            if stamp(of: key) == r.updatedAt { dirty.remove(key) }
        }
        for r in records {
            switch r.kind {
            case DogEvent.kind: merge(r, \.events)
            case Walk.kind: merge(r, \.walks)
            case DogProfile.kind: merge(r, \.profiles)
            case WeightEntry.kind: merge(r, \.weights)
            case Vaccination.kind: merge(r, \.vaccinations)
            case Deworming.kind: merge(r, \.dewormings)
            case Medication.kind: merge(r, \.meds)
            case HealthNote.kind: merge(r, \.notes)
            case ToolSettings.kind: merge(r, \.toolSettings)
            case FavoriteFood.kind: merge(r, \.favorites)
            case TipChecks.kind: merge(r, \.tipChecks)
            case Avatar.kind: merge(r, \.avatars)
            case FriendKey.kind: merge(r, \.friendKeys)
            case CheckIn.kind: merge(r, \.checkIns)
            default: continue  // Arten, die diese Fassung noch nicht kennt, bleiben auf dem Server.
            }
        }
        rev = newRev
        persist()
    }

    private func merge<T: SyncedItem>(_ r: SyncRecord, _ list: ReferenceWritableKeyPath<DogStore, [T]>) {
        let key = "\(T.kind):\(r.id)"
        let localU = stamp(of: key) ?? -1
        guard r.updatedAt >= localU else { return }
        // Fehlt `u` (Datensätze aus der Web-App), gilt der Zeitpunkt des Servers – sonst schlüge das Dekodieren fehl.
        var payload = r.payload
        if case .object(var o)? = payload, o["u"] == nil { o["u"] = .number(r.updatedAt); payload = .object(o) }
        if let payload, var item = try? payload.decode(T.self) {
            item.u = r.updatedAt
            if let i = self[keyPath: list].firstIndex(where: { $0.id == item.id }) { self[keyPath: list][i] = item } else { self[keyPath: list].append(item) }
            graves[key] = nil
        } else {
            self[keyPath: list].removeAll { $0.id == r.id }
            graves[key] = r.updatedAt
        }
        dirty.remove(key)
        changedBy[key] = r.by
    }

    /// Nach dem Anmelden: Alles, was bisher nur auf dem Gerät lag, gehört ins Rudel.
    func markAllChanged() {
        dirty.formUnion(allKeys)
        persist(notify: false)
    }

    /// Wechselt das Rudel. Mit `keepLocal` wandern die Daten dieses Geräts mit hinüber (beim Beitreten),
    /// sonst bleibt das Gerät leer, bis der Abgleich das neue Rudel holt (beim Verlassen).
    func switchPack(to id: Int?, keepLocal: Bool = true) {
        packID = id
        rev = 0
        changedBy = [:]
        if keepLocal {
            dirty.formUnion(allKeys)
        } else {
            events = []
            walks = []
            profiles = []
            weights = []
            vaccinations = []
            dewormings = []
            meds = []
            notes = []
            toolSettings = []
            favorites = []
            tipChecks = []
            avatars = []
            friendKeys = []
            checkIns = []
            graves = [:]
            dirty = []
        }
        persist()
    }

    /// Beitreten: Der Hund des Rudels ist der Hund. Profil, Hundebild, Einstellungen und Abgehaktes von hier
    /// gelten nur, wenn das Rudel sie noch nicht hat – sonst überschriebe, wer beim Einrichten schnell den Namen
    /// getippt hat, das ganze Profil der anderen. Alles andere (Termine, Runden, Einträge) wandert mit.
    /// Nach dem ersten Abgleich `claimUnanswered()` aufrufen.
    func joinPack(_ id: Int) {
        switchPack(to: id, keepLocal: true)
        for i in profiles.indices { profiles[i].u = 0 }
        for i in avatars.indices where avatars[i].id == Avatar.dog { avatars[i].u = 0 }
        for i in toolSettings.indices { toolSettings[i].u = 0 }
        for i in tipChecks.indices { tipChecks[i].u = 0 }
        dirty.subtract(Self.yieldingKeys)
        // Hundefreundschaften gehören zum alten Rudel – ihre Schlüssel bekommt das neue nicht.
        dirty.subtract(friendKeys.map { "\(FriendKey.kind):\($0.id)" })
        avatarCache = [:]
        persist()
    }

    /// Was das Rudel beim Beitreten nicht hatte, gehört jetzt ihm.
    func claimUnanswered() {
        let now = Date().timeIntervalSince1970 * 1000
        for i in profiles.indices where profiles[i].u == 0 { profiles[i].u = now; dirty.insert("\(DogProfile.kind):\(profiles[i].id)") }
        for i in avatars.indices where avatars[i].id == Avatar.dog && avatars[i].u == 0 { avatars[i].u = now; dirty.insert("\(Avatar.kind):\(Avatar.dog)") }
        for i in toolSettings.indices where toolSettings[i].u == 0 { toolSettings[i].u = now; dirty.insert("\(ToolSettings.kind):\(toolSettings[i].id)") }
        for i in tipChecks.indices where tipChecks[i].u == 0 { tipChecks[i].u = now; dirty.insert("\(TipChecks.kind):\(tipChecks[i].id)") }
        persist()
    }

    static let yieldingKeys: Set<String> = ["\(DogProfile.kind):profile", "\(Avatar.kind):\(Avatar.dog)",
                                            "\(ToolSettings.kind):settings", "\(TipChecks.kind):checks"]

    /// Beim Abmelden: Die Daten bleiben auf dem Gerät, die Verbindung zum Rudel nicht.
    func resetSync() {
        packID = nil
        rev = 0
        dirty = []
        changedBy = [:]
        persist(notify: false)
    }

    private func persist(notify: Bool = true) {
        let data = try? JSONEncoder().encode(Saved(events: events, walks: walks, profiles: profiles, weights: weights, vaccinations: vaccinations,
                                                   dewormings: dewormings, meds: meds, notes: notes, toolSettings: toolSettings, favorites: favorites, tipChecks: tipChecks, avatars: avatars, friendKeys: friendKeys, checkIns: checkIns, graves: graves, packID: packID, rev: rev,
                                                   dirty: dirty, changedBy: changedBy))
        try? data?.write(to: file, options: .atomic)
        if notify { onEventsChanged?(events) }
    }
}

#if DEBUG
extension DogStore {
    /// Beispieltermine für Bildschirmfotos: Start mit `-beispiel`.
    func seedExamples() {
        guard events.isEmpty else { return }
        let t = Day.today
        let list = [
            DogEvent(title: String(localized: "Entwurmung"), start: t.adding(days: 12).adding(months: -3), repetition: .quarterly),
            DogEvent(title: String(localized: "Tierarzt: Impfung Tollwut"), start: t.adding(days: 2), time: "10:30", notes: String(localized: "Impfpass mitnehmen")),
            DogEvent(title: String(localized: "Krallen schneiden"), start: t.adding(days: -9), repetition: .monthly),
            DogEvent(title: String(localized: "Hundeschule"), start: t.adding(days: -t.weekdayFromMonday + 5), time: "09:00", repetition: .weekly),
            DogEvent(title: String(localized: "Urlaub an der Ostsee"), start: t.adding(days: 20), end: t.adding(days: 26)),
            DogEvent(title: String(localized: "Zeckenschutz"), start: t, repetition: .monthly),
        ]
        for e in list { save(e) }

        var p = DogProfile()
        p.name = String(localized: "Stella"); p.breed = String(localized: "Zwergpudel"); p.sex = "f"; p.birthdate = t.adding(months: -16).iso
        p.targetWeightKg = 6; p.vetName = String(localized: "Tierarztpraxis am Augarten"); p.vetPhone = "+43 1 234 56 78"
        p.ownerName = String(localized: "Alex"); p.ownerPhone = "+43 660 123 45 67"; p.chip = "040098100123456"
        p.allergies = String(localized: "Verträgt kein Huhn"); p.tracker = true
        // `-vermisst`: Stella ist seit zwei Stunden weg (für den Steckbrief).
        if ProcessInfo.processInfo.arguments.contains("-vermisst") {
            p.lostSince = LostDog.stamp(Date().addingTimeInterval(-2 * 3600))
            p.lostWhere = String(localized: "Augarten, beim Spielplatz")
            p.lostNote = String(localized: "Ängstlich, nicht rufen. Rotes Halsband.")
        }
        save(p)
        // Drei Runden durch den Augarten in Wien, für „Letzte Runden“ und die Woche.
        let park = (lat: 48.2236, lng: 16.3760)
        // `-ohneheute`: Heute noch keine Runde (für die Aufnahme der Startseite).
        let first = ProcessInfo.processInfo.arguments.contains("-ohneheute") ? 1 : 0
        for (back, scale, minutes) in [(first, 1.0, 38.0), (first + 1, 0.8, 31.0), (3, 1.2, 47.0)] {
            let coords = (0...40).map { i -> CLLocationCoordinate2D in
                let a = Double(i) / 40 * 2 * .pi
                return CLLocationCoordinate2D(latitude: park.lat + 0.0042 * scale * sin(a), longitude: park.lng + 0.0056 * scale * cos(a) * (1 + 0.15 * sin(3 * a)))
            }
            let meters = zip(coords, coords.dropFirst()).reduce(0) { $0 + Track.distance($1.0, $1.1) }
            let start = Date().addingTimeInterval(-Double(back) * 86400 - 3 * 3600)
            save(Walk(id: Walk.newID(), start: start.timeIntervalSince1970 * 1000, end: start.addingTimeInterval(minutes * 60).timeIntervalSince1970 * 1000,
                      seconds: minutes * 60, meters: meters, path: Polyline.encode(coords)))
        }
        // Zwergpudel: mit sechs Monaten gut 4 kg, ausgewachsen 6 kg.
        for (m, kg) in [(-10, 4.2), (-8, 4.9), (-6, 5.4), (-4, 5.7), (-2, 5.9), (0, 6.0)] {
            saveWeight(kg, on: t.adding(months: m))
        }
        save(Vaccination(id: newHealthID("vaccinations"), name: "Tollwut", date: t.adding(months: -9).iso, next: t.adding(months: 3).iso))
        save(Vaccination(id: newHealthID("vaccinations"), name: "SHPPi", date: t.adding(months: -11).iso, next: t.adding(days: 25).iso))
        save(Deworming(id: newHealthID("deworming"), product: String(localized: "Milbemax"), date: t.adding(months: -2).iso, next: t.adding(days: 12).iso))
        var n1 = HealthNote(d: t.adding(days: -1).iso); n1.time = "07:40"; n1.tags = [String(localized: "Erbrochen")]
        n1.text = String(localized: "Morgens Gras gefressen, danach einmal erbrochen. Mittags wieder munter.")
        save(n1)
        var n2 = HealthNote(d: t.adding(days: -16).iso); n2.tags = [String(localized: "Zecke")]
        n2.text = String(localized: "Am Hals entfernt, Stelle leicht gerötet.")
        save(n2)
    }
}

extension DogStore {
    /// Für Bildschirmfotos: Termine und Runden gelten als von jemand anderem im Rudel geändert.
    func demoSetAvatar(_ a: Avatar) { avatars.removeAll { $0.id == a.id }; avatars.append(a) }

    func demoChangedBy(_ account: Int, keys: [String]) {
        for k in keys { changedBy[k] = account }
    }
}
#endif
