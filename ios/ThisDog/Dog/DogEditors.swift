import SwiftUI

/// Profil anlegen oder bearbeiten.
struct ProfileEditor: View {
    @Environment(DogStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var profile: DogProfile
    /// Der Stand beim Öffnen: Gesichert wird nur, was hier geändert wurde – sonst löschte ein offener Editor, was
    /// inzwischen im Rudel eingetragen wurde (etwa „entlaufen“).
    private let base: DogProfile

    init(profile: DogProfile) {
        _profile = State(initialValue: profile)
        base = profile
    }
    @State private var hasBirth = false
    @State private var birth = Date()
    @State private var weight = ""
    @State private var target = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, z. B. Stella", text: $profile.name).font(.body.weight(.semibold))
                    TextField("Rasse oder Typ, z. B. Pudel", text: $profile.breed)
                    Picker("Geschlecht", selection: $profile.sex) {
                        Text("Keine Angabe").tag("")
                        Text("Hündin").tag("f")
                        Text("Rüde").tag("m")
                    }
                    Toggle("Kastriert", isOn: $profile.neutered)
                }
                Section {
                    Toggle("Geburtstag bekannt", isOn: $hasBirth.animation())
                    if hasBirth { DatePicker("Geboren am", selection: $birth, in: ...Date(), displayedComponents: .date) }
                } footer: { Text("Daraus entstehen Alter, Lebensphase und der Geburtstag im Kalender.") }
                Section {
                    LabeledContent("Gewicht") { TextField("kg", text: $weight).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    LabeledContent("Wunschgewicht") { TextField("kg", text: $target).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    Picker("Aktivität", selection: $profile.activity) {
                        ForEach(DogProfile.activities, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } footer: { Text("Grundlage für Futtermenge und Wasserbedarf.") }
                Section("Tierarzt") {
                    TextField("Praxis", text: $profile.vetName)
                    TextField("Telefon", text: $profile.vetPhone).keyboardType(.phonePad)
                }
                Section {
                    TextField("Dein Name", text: $profile.ownerName).textContentType(.name)
                    TextField("Deine Nummer", text: $profile.ownerPhone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    TextField("Chip-Nummer", text: $profile.chip).keyboardType(.numberPad)
                } header: { Text("Für den Notfallpass") } footer: { Text("Steht im Notfallpass, falls jemand anderes den Hund findet.") }
                Section {
                    Toggle("Trägt einen AirTag oder Tracker", isOn: $profile.tracker)
                } footer: { Text("Dann öffnet ein Button bei Gassi die App „Wo ist?“.") }
                Section("Besonderheiten") {
                    TextField("Unverträglichkeiten, Vorerkrankungen", text: $profile.allergies, axis: .vertical).lineLimit(2...6)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(store.hasProfile ? String(localized: "Profil bearbeiten") : String(localized: "Hund anlegen")) {
                BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                BarTextItem(title: String(localized: "Speichern"), disabled: profile.name.trimmingCharacters(in: .whitespaces).isEmpty) { save() }
            }
            .onAppear {
                if let b = profile.birthDay { hasBirth = true; birth = b.date }
                weight = profile.weightKg.map(DogScreen.kg) ?? ""
                target = profile.targetWeightKg.map(DogScreen.kg) ?? ""
            }
        }
        .tint(Palette.accent)
    }

    static func number(_ s: String) -> Double? {
        let v = Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        return v.flatMap { $0 > 0 && $0 < 150 ? $0 : nil }
    }

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.birthdate = hasBirth ? Day(date: birth).iso : ""
        profile.targetWeightKg = Self.number(target)
        let kg = Self.number(weight)
        let changed = kg != nil && kg != profile.weightKg
        profile.weightKg = kg
        let merged = store.profile.applying(edits: profile, since: base)
        if merged != store.profile { store.save(merged) }
        // Ein neues Gewicht wandert zugleich in den Verlauf, wie in der Web-App.
        if changed, let kg { store.saveWeight(kg) }
        dismiss()
    }
}

/// Ein Gewicht eintragen.
struct WeightEditor: View {
    @Environment(DogStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var day = Date()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Gewicht") {
                    TextField("kg", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($focused)
                }
                DatePicker("Am", selection: $day, in: ...Date(), displayedComponents: .date)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(String(localized: "Gewicht eintragen")) {
                BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                BarTextItem(title: String(localized: "Speichern"), disabled: ProfileEditor.number(text) == nil) {
                    if let kg = ProfileEditor.number(text) { store.saveWeight(kg, on: Day(date: day)) }
                    dismiss()
                }
            }
            .onAppear { focused = true }
        }
        .tint(Palette.accent)
        .presentationDetents([.medium])
    }
}

/// Impfung, Entwurmung oder Medikament anlegen und bearbeiten.
struct HealthEditor: View {
    enum Item: Identifiable {
        case vaccination(Vaccination), deworming(Deworming), medication(Medication)
        var id: String {
            switch self { case .vaccination(let v): v.id; case .deworming(let d): d.id; case .medication(let m): m.id }
        }
    }

    @Environment(DogStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: Item

    @State private var title = ""
    @State private var detail = ""
    @State private var date = Date()
    @State private var hasNext = false
    @State private var next = Date()
    @State private var confirmsDelete = false

    private var isNew: Bool {
        switch item {
        case .vaccination(let v): !store.vaccinations.contains { $0.id == v.id }
        case .deworming(let d): !store.dewormings.contains { $0.id == d.id }
        case .medication(let m): !store.meds.contains { $0.id == m.id }
        }
    }

    private var labels: (title: String, placeholder: String, detail: String?, date: String, next: String) {
        switch item {
        case .vaccination: (String(localized: "Impfung"), String(localized: "z. B. Tollwut, SHPPi"), String(localized: "Notiz"), String(localized: "Geimpft am"), String(localized: "Nächste fällig"))
        case .deworming: (String(localized: "Entwurmung"), String(localized: "Präparat, z. B. Milbemax"), nil, String(localized: "Am"), String(localized: "Nächste fällig"))
        case .medication: (String(localized: "Medikament"), String(localized: "z. B. Schmerzmittel"), String(localized: "Dosierung, z. B. 1 Tablette morgens"), String(localized: "Von"), String(localized: "Bis"))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(labels.placeholder, text: $title).font(.body.weight(.semibold))
                    if let d = labels.detail { TextField(d, text: $detail) }
                }
                Section {
                    DatePicker(labels.date, selection: $date, displayedComponents: .date)
                    Toggle(labels.next, isOn: $hasNext.animation())
                    if hasNext { DatePicker(labels.next, selection: $next, in: date..., displayedComponents: .date) }
                } footer: {
                    if case .medication = item {} else { Text("Die Fälligkeit erscheint im Kalender und unter „Was ansteht“.") }
                }
                if !isNew {
                    Section { Button("Löschen", role: .destructive) { confirmsDelete = true } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(isNew ? String(localized: "\(labels.title) hinzufügen") : labels.title) {
                BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                BarTextItem(title: String(localized: "Speichern")) { save() }
            }
            .confirmationDialog("Eintrag löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { delete() }
            }
            .onAppear(perform: load)
        }
        .tint(Palette.accent)
    }

    private func load() {
        func set(_ t: String, _ d: String, _ day: String, _ nx: String) {
            title = t; detail = d
            if let x = Day(iso: day) { date = x.date }
            if let x = Day(iso: nx) { hasNext = true; next = x.date } else { next = date.addingTimeInterval(365 * 86400) }
        }
        switch item {
        case .vaccination(let v): set(v.name, v.notes, v.date, v.next)
        case .deworming(let d):
            set(d.product, "", d.date, d.next)
            if Day(iso: d.next) == nil { next = date.addingTimeInterval(91 * 86400) }
        case .medication(let m): set(m.name, m.dose, m.from, m.to)
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        let d = Day(date: date).iso, nx = hasNext ? Day(date: next).iso : ""
        switch item {
        case .vaccination(var v): v.name = t; v.notes = detail; v.date = d; v.next = nx; store.save(v)
        case .deworming(var x): x.product = t; x.date = d; x.next = nx; store.save(x)
        case .medication(var m): m.name = t; m.dose = detail; m.from = d; m.to = nx; store.save(m)
        }
        dismiss()
    }

    private func delete() {
        switch item {
        case .vaccination(let v): store.deleteVaccination(id: v.id)
        case .deworming(let d): store.deleteDeworming(id: d.id)
        case .medication(let m): store.deleteMedication(id: m.id)
        }
        dismiss()
    }
}

