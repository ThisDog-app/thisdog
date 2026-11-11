import PhotosUI
import SwiftUI

/// Das Gesundheitstagebuch im Reiter Gesundheit: was auffiel, neueste zuerst, mit Foto und wer es eingetragen hat.
/// „Für den Tierarzt“ fasst die letzten Monate als Text zusammen.
struct HealthDiarySection: View {
    @Environment(DogStore.self) private var store
    @Environment(Account.self) private var account
    @State private var editing: HealthNote?
    @State private var shownAll = false

    private var sorted: [HealthNote] {
        store.notes.sorted { ($0.d, $0.time, $0.u) > ($1.d, $1.time, $1.u) }
    }

    var body: some View {
        let list = sorted
        let visible = shownAll ? list : Array(list.prefix(6))
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tagebuch").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Button { editing = HealthNote() } label: {
                    LineIcon("plus", size: 22).foregroundStyle(Palette.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(.hoverEffect, Circle())
                        .hoverEffect(.highlight)
                }
                .accessibilityLabel("Ins Tagebuch schreiben")
            }
            if list.isEmpty {
                Text("Erbrochen, humpelt, Zecke entfernt: kurz notiert, mit Datum und Foto. Beim Tierarzt hast du dann den Verlauf.")
                    .font(.subheadline).foregroundStyle(Palette.ink3)
                Button { editing = HealthNote() } label: {
                    Text("Erster Eintrag").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible) { note in
                        Button { editing = note } label: { row(note) }
                            .buttonStyle(.plain)
                        if note.id != visible.last?.id { Divider().overlay(Palette.line).padding(.leading, 16) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                HStack(spacing: 16) {
                    if list.count > visible.count || shownAll {
                        Button(shownAll ? String(localized: "Weniger zeigen") : String(localized: "Alle \(list.count) Einträge")) {
                            withAnimation(.snappy) { shownAll.toggle() }
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    Spacer(minLength: 0)
                    ShareLink(item: Self.vetSummary(list, dog: store.profile.name)) {
                        Label("Für den Tierarzt", icon: "teilen").font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .sheet(item: $editing) { HealthNoteEditor(note: $0) }
    }

    private func row(_ n: HealthNote) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.when(n)).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
                Text(n.headline).font(.body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(2)
                if !n.tags.isEmpty, !n.text.isEmpty {
                    Text(n.text).font(.subheadline).foregroundStyle(Palette.ink2).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let who = account.author(of: n) {
                AvatarView(image: who.image, name: who.name, size: 22)
                    .accessibilityLabel("eingetragen von \(who.name)")
            }
            if let photo = n.photo, let data = Data(base64Encoded: photo), let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    static func when(_ n: HealthNote) -> String {
        let day = n.day.map { $0 == .today ? String(localized: "Heute") : $0 == Day.today.adding(days: -1) ? String(localized: "Gestern") : $0.shortText } ?? ""
        return n.time.isEmpty ? day : "\(day), \(n.time) Uhr"
    }

    /// Als Text zum Weiterleiten oder Vorlesen: die letzten zwölf Monate, älteste zuerst – so liest man einen Verlauf.
    static func vetSummary(_ notes: [HealthNote], dog: String, today: Day = .today) -> String {
        let since = today.adding(months: -12)
        let lines = notes.filter { ($0.day ?? today) >= since }
            .sorted { ($0.d, $0.time) < ($1.d, $1.time) }
            .map { n -> String in
                let date = n.day?.date.formatted(date: .numeric, time: .omitted) ?? n.d
                let head = [date, n.time.isEmpty ? nil : n.time].compactMap { $0 }.joined(separator: " ")
                let what = [n.tags.joined(separator: ", "), n.text].filter { !$0.isEmpty }.joined(separator: ": ")
                return "\(head) – \(what)\(n.photo == nil ? "" : String(localized: " (Foto in der App)"))"
            }
        let name = dog.isEmpty ? String(localized: "meinem Hund") : dog
        return ([String(localized: "Gesundheitstagebuch von \(name)"), ""] + lines).joined(separator: "\n")
    }
}

/// Ein Eintrag: Stichworte zum Antippen, eigener Text, Tag und Uhrzeit, ein Foto.
struct HealthNoteEditor: View {
    @Environment(DogStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let note: HealthNote

    @State private var draft = HealthNote()
    @State private var date = Date()
    @State private var withTime = true
    @State private var photoItem: PhotosPickerItem?
    @State private var takesPhoto = false
    @State private var photoFailed = false
    @State private var confirmsDelete = false

    private var isNew: Bool { !store.notes.contains { $0.id == note.id } }
    private var canSave: Bool { !draft.tags.isEmpty || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.photo != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(HealthNote.presets + draft.tags.filter { !HealthNote.presets.contains($0) }, id: \.self) { tag in
                            let on = draft.tags.contains(tag)
                            Button { toggle(tag) } label: {
                                Text(tag).font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .foregroundStyle(on ? Color.white : Palette.ink)
                                    .background(on ? Palette.accent : Palette.paper, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                    TextField("Was ist dir aufgefallen?", text: $draft.text, axis: .vertical)
                        .lineLimit(3...8)
                } header: { Text("Was war los?") }
                Section {
                    DatePicker("Wann", selection: $date, in: ...Date(), displayedComponents: withTime ? [.date, .hourAndMinute] : [.date])
                    Toggle("Mit Uhrzeit", isOn: $withTime)
                }
                Section {
                    if let photo = draft.photo, let data = Data(base64Encoded: photo), let img = UIImage(data: data) {
                        Image(uiImage: img).resizable().scaledToFit()
                            .frame(maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button("Foto entfernen", role: .destructive) { draft.photo = nil }
                    } else {
                        Button { takesPhoto = true } label: { Label("Foto aufnehmen", icon: "kamera") }
                        PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .compatible) { Label("Aus der Mediathek", icon: "foto") }
                    }
                    if photoFailed { Text("Dieses Foto ließ sich nicht verwenden.").foregroundStyle(Palette.kind(.health)) }
                } header: { Text("Foto") } footer: {
                    Text("Ausschlag, Wunde, Häufchen: Ein Foto sagt dem Tierarzt oft mehr. Es wird verschlüsselt mit dem Rudel geteilt.")
                }
                if !isNew {
                    Section { Button("Eintrag löschen", role: .destructive) { confirmsDelete = true } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(isNew ? String(localized: "Neuer Eintrag") : String(localized: "Eintrag")) {
                BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                BarTextItem(title: String(localized: "Sichern"), disabled: !canSave) { save() }
            }
            .confirmationDialog("Eintrag löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { store.deleteNote(id: note.id); dismiss() }
            }
            .fullScreenCover(isPresented: $takesPhoto) {
                CameraPicker { use($0) }.ignoresSafeArea()
            }
            .onChange(of: photoItem) {
                Task {
                    guard let photoItem, let img = await PickedPhoto.image(photoItem) else { return }
                    use(img)
                }
            }
            .onAppear(perform: load)
        }
        .tint(Palette.accent)
    }

    private func toggle(_ tag: String) {
        if let i = draft.tags.firstIndex(of: tag) { draft.tags.remove(at: i) } else { draft.tags.append(tag) }
    }

    private func use(_ image: UIImage) {
        if let s = HealthNote.preparePhoto(image) { draft.photo = s; photoFailed = false } else { photoFailed = true }
    }

    private func load() {
        draft = note
        if let day = note.day {
            var c = Calendar.current.dateComponents([.year, .month, .day], from: day.date)
            let parts = note.time.split(separator: ":").compactMap { Int($0) }
            withTime = isNew || parts.count == 2
            if parts.count == 2 { c.hour = parts[0]; c.minute = parts[1] }
            if isNew { date = Date() } else { date = Calendar.current.date(from: c) ?? day.date }
        }
    }

    private func save() {
        var n = draft
        n.text = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
        n.d = Day(date: date).iso
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        n.time = withTime ? String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) : ""
        store.save(n)
        dismiss()
    }
}
