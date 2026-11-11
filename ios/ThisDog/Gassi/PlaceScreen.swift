import PhotosUI
import MapKit
import SwiftUI

/// Bewertungen eines Ortes beim Server (api/place.php). Nach außen gehen nur Zählungen.
enum PlaceService {
    struct Summary: Decodable {
        let votes: [String: [Int]]
        let voters: Int
        let sizes: [Int]
        var photos: [Place.Photo]? = nil
        var checkedAt: Double? = nil
        var facts: [String: Place.Fact]? = nil
        var scout: Bool? = nil
        let mine: Mine
        struct Mine: Decodable {
            let votes: [String: Int]
            let sizes: Sizes?

            /// Ob man hier schon etwas gesagt hat: Mehr als eine Bewertung je Mensch und Ort gibt es nicht.
            var isRated: Bool { !votes.isEmpty || sizes?.any == true }
        }
    }

    struct Sizes: Codable, Equatable {
        var small = false, medium = false, large = false
        var any: Bool { small || medium || large }
    }

    static func summary(_ id: String) async throws -> Summary {
        try await Api().get("place.php", ["id": id])
    }

    /// Stimmen: Merkmal → 1 (gibt es), 0 (gibt es nicht) oder nil (weiß nicht – eine frühere Stimme fällt weg).
    static func vote(_ id: String, votes: [String: Int?], sizes: Sizes) async throws -> Summary {
        struct Body: Encodable { let id: String; let votes: [String: Int?]; let sizes: Sizes }
        return try await Api().post("place.php", ["action": "vote"], body: Body(id: id, votes: votes, sizes: sizes))
    }

    static func add(name: String, kind: String, at c: CLLocationCoordinate2D, votes: [String: Int]) async throws -> Place {
        struct Body: Encodable { let name: String; let kind: String; let lat: Double; let lon: Double; let votes: [String: Int] }
        struct Answer: Decodable { let place: Place }
        let a: Answer = try await Api().post("place.php", ["action": "add"], body: Body(name: name, kind: kind, lat: c.latitude, lon: c.longitude, votes: votes))
        return a.place
    }

    static func report(_ id: String, reason: String) async throws {
        struct Body: Encodable { let id: String; let reason: String }
        let _: Ok = try await Api().post("place.php", ["action": "report"], body: Body(id: id, reason: reason))
    }
}

/// Ein Ort: was es dort gibt, welche Hunde man trifft, bewerten, melden.
/// Auf dem iPhone als Blatt über der Liste, auf dem Duo und dem iPad in der rechten Hälfte neben der Karte.
struct PlaceScreen: View {
    @Environment(Account.self) private var account
    @Environment(DogStore.self) private var store
    @Environment(WalkRecorder.self) private var recorder
    @State var place: Place
    /// Zeigt oben eine kleine Karte (iPhone); daneben steht die große Karte schon (Duo, iPad).
    var showsMap = true
    var onClose: (() -> Void)? = nil
    var onChange: ((Place) -> Void)? = nil
    /// Neben der Liste (Duo, iPad): „‹ Wohin heute? › Ort“ statt eines Schließen-Kreuzes.
    var parent: String? = nil

    @State private var rating = false
    /// Was man selbst gesagt hat; kommt vom Server und nach dem Sichern neu.
    @State private var mine: PlaceService.Summary.Mine?
    @State private var reporting = false
    @State private var reported = false
    @State private var scout = false
    @State private var checking = false
    @State private var pickingCamera = false
    /// Eigener Zustand statt `PhotosPicker` im Menü: Das Menü schließt sich und nähme die Auswahl mit.
    @State private var pickingLibrary = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photoNote: String?
    @State private var faceImage: UIImage?

    private var signedIn: Bool { if case .signedIn = account.state { true } else { false } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showsMap {
                    WalkMap(here: recorder.here, places: [place], selected: place.id, focus: place.coordinate, focusDistance: 600)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .allowsHitTesting(false)
                        .padding(.bottom, 18)
                }
                if let parent, let onClose {
                    Breadcrumb(parent: parent, current: place.label, back: onClose).padding(.bottom, 6)
                }
                header
                if let at = place.checkedAt { checkedBadge(Date(timeIntervalSince1970: at)).padding(.top, 14) }
                if hasActions { actions.padding(.top, 16) }
                // Noch nicht da: zu Fuß hinführen lassen (Apple Karten).
                if !canCheckIn, recentCheckIn == nil {
                    Button(action: guide) {
                        Label("Hinführen", icon: "kompass").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).tint(Palette.ink)
                    .padding(.top, hasActions ? 10 : 16)
                }
                if scout, place.serverID != nil {
                    Button { checking = true } label: {
                        Label("Vor Ort prüfen", icon: "pruefung").font(.subheadline.weight(.semibold))
                    }
                    .padding(.top, 10)
                }
                visitsCard

                if place.hasNoDogsArea {
                    Label("In Teilen des Parks gilt Hundeverbot (laut Stadt Wien).", icon: "warnung")
                        .font(.subheadline).foregroundStyle(Palette.kind(.health))
                        .padding(.top, 14)
                }

                Text("Wie es hier ist")
                    .font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink)
                    .padding(.top, 24).padding(.bottom, 4)
                if place.enoughVotes { votedFeatures } else { knownFeatures }
                if let mine, mine.isRated { myRating(mine).padding(.top, 18) } else if !place.enoughVotes { invite }
                if place.enoughVotes, place.sizes.reduce(0, +) > 0 { sizes.padding(.top, 18) }

                photosSection.padding(.top, 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text(place.sourceNote)
                    if place.serverID != nil {
                        Button(reported ? String(localized: "Danke, wir sehen es uns an.") : String(localized: "Stimmt etwas nicht?")) { reporting = true }
                            .disabled(reported || !signedIn)
                            .foregroundStyle(reported ? Palette.ink3 : Palette.accent)
                    }
                }
                .font(.footnote).foregroundStyle(Palette.ink3)
                .padding(.top, 22)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Palette.paper)
        .sheet(isPresented: $rating) {
            RatePlaceSheet(place: place) { summary in
                place.votes = summary.votes; place.voters = summary.voters; place.sizes = summary.sizes
                mine = summary.mine
                onChange?(place)
            }
        }
        .confirmationDialog("Was stimmt nicht?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach([("gibt_es_nicht", String(localized: "Den Ort gibt es nicht")), ("falscher_ort", String(localized: "Er liegt woanders")),
                     ("hunde_verboten", String(localized: "Hunde sind hier verboten")), ("falscher_name", String(localized: "Der Name stimmt nicht")), ("anderes", String(localized: "Etwas anderes"))], id: \.0) { key, title in
                Button(title) { Task { try? await PlaceService.report(place.serverID ?? "", reason: key); reported = true } }
            }
        }
        .task(id: place.serverID) { await refresh() }
        // Fürs Einchecken zählt, wo man jetzt ist – nicht, wo die App den Standort zuletzt kannte.
        // Während einer Runde auf dem iPhone kommt er ohnehin laufend.
        .task(id: place.id) { if recorder.phase == .idle, recorder.isAuthorized { recorder.locateOnce() } }
        .sheet(isPresented: $checking) {
            CheckSheet(place: place) { account.notice = Notice(title: String(localized: "Vor Ort geprüft"), body: $0, fromPack: false, symbol: "pruefung") }
        }
        .sheet(isPresented: $pickingCamera) { CameraPicker { consider($0) }.ignoresSafeArea() }
        .photosPicker(isPresented: $pickingLibrary, selection: $pickedPhoto, matching: .images, preferredItemEncoding: .compatible)
        .confirmationDialog("Auf dem Foto ist ein Gesicht zu sehen.", isPresented: Binding(get: { faceImage != nil }, set: { if !$0 { faceImage = nil } }), titleVisibility: .visible) {
            Button("Trotzdem hochladen") { if let img = faceImage { upload(img) }; faceImage = nil }
            Button("Abbrechen", role: .cancel) { faceImage = nil }
        } message: { Text("Fotos von Orten zeigen besser keine Menschen, die man erkennen kann.") }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            photoNote = String(localized: "Foto wird geladen …")
            Task {
                if let img = await PickedPhoto.image(item) {
                    photoNote = nil
                    consider(img)
                } else {
                    photoNote = String(localized: "Das Foto ließ sich nicht laden. Versuch es mit einem anderen.")
                }
                pickedPhoto = nil
            }
        }
    }

    // MARK: Fotos und Prüfung

    private func checkedBadge(_ d: Date) -> some View {
        let green = Color(red: 0.12, green: 0.44, blue: 0.29)
        return HStack(spacing: 10) {
            LineIcon("pruefung", size: 27).foregroundStyle(green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Von ThisDog geprüft").font(.subheadline.weight(.semibold)).foregroundStyle(green)
                Text("vor Ort am \(d.formatted(.dateTime.day().month(.wide).year().locale(AppLocale.current)))").font(.footnote).foregroundStyle(green.opacity(0.8))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(red: 0.89, green: 0.95, blue: 0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Fotos").font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                if signedIn, place.serverID != nil {
                    Menu {
                        Button("Foto aufnehmen", menuIcon: "kamera") { pickingCamera = true }
                        Button("Aus der Mediathek", menuIcon: "foto") { pickingLibrary = true }
                    } label: {
                        Label("Foto hinzufügen", icon: "plus").font(.subheadline.weight(.semibold))
                    }
                }
            }
            if place.photos.isEmpty {
                Text("Noch keine Fotos. Zeig anderen, wie es hier aussieht.").font(.subheadline).foregroundStyle(Palette.ink2)
            }
            PlacePhotos(photos: place.photos)
            if let photoNote { Text(photoNote).font(.subheadline).foregroundStyle(Palette.ink2) }
        }
    }

    /// Vor dem Hochladen: Ist ein Gesicht zu sehen, fragt die App nach.
    private func consider(_ img: UIImage) {
        if PlaceService.hasFace(img) { faceImage = img } else { upload(img) }
    }

    private func upload(_ img: UIImage) {
        guard let id = place.serverID else { return }
        guard let d = PlaceService.jpeg(img) else {
            photoNote = String(localized: "Das Foto ließ sich nicht umwandeln. Versuch es mit einem anderen.")
            return
        }
        photoNote = String(localized: "Wird hochgeladen …")
        Task {
            do {
                try await PlaceService.uploadPhoto(id, jpeg: d)
                photoNote = nil
                await refresh()
            } catch {
                photoNote = String(localized: "Nicht hochgeladen. Prüfe die Verbindung und versuche es noch einmal.")
            }
        }
    }

    // MARK: Einchecken

    private var dogName: String { store.profile.name.isEmpty ? String(localized: "Dein Hund") : store.profile.name }
    private var myVisits: [CheckIn] { CheckIns.visits(to: place, in: store.checkIns) }
    private var recentCheckIn: CheckIn? { CheckIns.recent(place, in: store.checkIns) }
    private var canCheckIn: Bool { CheckIns.inReach(place, from: recorder.here) }

    /// Solange kaum jemand bewertet hat, lädt der Abschnitt „Wie es hier ist“ dazu ein – oben genügt Einchecken.
    private var hasRated: Bool { mine?.isRated == true }
    private var hasActions: Bool { (place.enoughVotes && !hasRated) || canCheckIn || recentCheckIn != nil }

    /// Öffnet den Fußweg in Apple Karten.
    private func guide() {
        let item = MKMapItem(location: CLLocation(latitude: place.lat, longitude: place.lon), address: nil)
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    /// Einchecken, wenn man vor Ort ist (höchstens 300 m), daneben Bewerten.
    private var actions: some View {
        HStack(spacing: 10) {
            if let recent = recentCheckIn {
                Label("Eingecheckt um \(recent.date.formatted(date: .omitted, time: .shortened))", icon: "haken")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Palette.accent)
                    .background(Palette.soft, in: Capsule())
            } else if canCheckIn {
                Button(action: checkIn) {
                    Label("Einchecken", icon: "pin").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .sensoryFeedback(.success, trigger: store.checkIns.count)
            }
            if place.enoughVotes, !hasRated {
                Button {
                    guard signedIn else { account.presentsPack = true; return }
                    rating = true
                } label: {
                    Label("Bewerten", icon: "schreiben")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(canCheckIn || recentCheckIn != nil ? AnyPrimitiveButtonStyle(.bordered) : AnyPrimitiveButtonStyle(.borderedProminent))
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    /// Wie oft der eigene Hund hier war, und welche Freunde gerade hier eingecheckt haben.
    @ViewBuilder
    private var visitsCard: some View {
        let mine = myVisits
        let friends = account.friends.visits(at: place)
        if !mine.isEmpty {
            HStack(spacing: 12) {
                AvatarView(image: store.avatarImage(Avatar.dog), name: dogName, size: 40, isDog: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mine.count == 1 ? String(localized: "\(dogName) war einmal hier") : String(localized: "\(dogName) war \(mine.count)-mal hier"))
                        .font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("zuletzt \(CheckIns.whenText(mine[0].date))").font(.subheadline).foregroundStyle(Palette.ink2)
                }
                Spacer()
                if mine.count >= 10 { LineIcon("abzeichen", size: 27).foregroundStyle(Palette.accent) }
            }
            .padding(12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 16)
        }
        ForEach(friends) { v in
            let f = account.friends.list.first { $0.pack == v.pack }
            HStack(spacing: 10) {
                AvatarView(image: f?.photo, name: f?.name ?? "", size: 28, isDog: f?.photo == nil)
                (Text(f?.name ?? String(localized: "Ein Freund")).fontWeight(.semibold).foregroundStyle(Palette.ink)
                 + Text(" ist seit \(Self.since(v.at)) hier").foregroundStyle(Palette.ink2))
                    .font(.subheadline)
            }
            .padding(.top, 10).padding(.leading, 4)
        }
    }

    static func since(_ d: Date, now: Date = Date()) -> String {
        let m = max(1, Int(now.timeIntervalSince(d) / 60))
        return m < 60 ? (m == 1 ? String(localized: "1 Minute") : String(localized: "\(m) Minuten")) : (m < 120 ? String(localized: "einer Stunde") : String(localized: "\(m / 60) Stunden"))
    }

    private func checkIn() { CheckIns.perform(place, store: store, account: account) }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name).font(.display(30)).foregroundStyle(Palette.ink)
                Text(meta).font(.subheadline).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 8)
            if parent == nil, let onClose {
                Button(action: onClose) {
                    LineIcon("kreuz", size: 19).frame(width: 34, height: 34)
                        .background(Palette.surface, in: Circle())
                }
                .foregroundStyle(Palette.ink2)
                .accessibilityLabel("Schließen")
            }
        }
    }

    private var meta: String {
        var parts = [place.label]
        if let here = recorder.here { parts.append(String(localized: "\(WalkText.distance(Track.distance(here, place.coordinate))) entfernt")) }
        if let a = place.area { parts.append(String(localized: "\(a.formatted(.number.locale(AppLocale.current))) m²")) }
        return parts.joined(separator: ", ")
    }

    // MARK: Merkmale

    /// Genug Bewertungen: gibt es, uneinig (mit Zählung), gibt es nicht.
    private var votedFeatures: some View {
        let all = PlaceFeature.all(for: place).compactMap { f in place.verdict(f).map { (f, $0) } }
        let yes = all.filter { if case .yes = $0.1 { true } else { false } }
        let unsure = all.compactMap { f, v -> (PlaceFeature, Int, Int)? in if case let .unsure(y, n) = v { (f, y, n) } else { nil } }
        let no = all.filter { if case .no = $0.1 { true } else { false } }
        return VStack(alignment: .leading, spacing: 0) {
            group(String(localized: "Gibt es")) {
                ForEach(yes, id: \.0) { f, _ in chip(f.short, symbol: "haken", style: .yes) }
                ForEach(place.extras, id: \.title) { chip($0.title, symbol: "haken", style: .yes) }
            }
            if !unsure.isEmpty {
                group(String(localized: "Uneinig")) { ForEach(unsure, id: \.0) { f, y, n in chip(f.short, symbol: f.symbol, style: .unsure, count: String(localized: "\(y) von \(n)")) } }
            }
            if !no.isEmpty {
                group(String(localized: "Gibt es nicht")) { ForEach(no, id: \.0) { f, _ in chip(f.short, symbol: f.symbol, style: .no) } }
            }
            Text(place.voters == 1 ? String(localized: "1 Mensch hat bewertet") : String(localized: "\(place.voters) Menschen haben bewertet"))
                .font(.footnote).foregroundStyle(Palette.ink3).padding(.top, 8)
        }
    }

    /// Zu wenig Bewertungen: was die Daten sagen, gestrichelt, mit Quelle.
    @ViewBuilder
    private var knownFeatures: some View {
        let known = PlaceFeature.all(for: place).compactMap { f in place.verdict(f).map { (f, $0) } }
        let yes = known.filter { if case .yes = $0.1 { true } else { false } }
        let partly = known.filter { if case .partly = $0.1 { true } else { false } }
        let no = known.filter { if case .no = $0.1 { true } else { false } }
        let source = Set(place.facts.values.map(\.src)).contains("wien") ? String(localized: "Laut Stadt Wien und Karte") : Place.sourceLabel(place.facts.values.first?.src)
        if !yes.isEmpty || !partly.isEmpty || !place.extras.isEmpty {
            group(source) {
                ForEach(yes, id: \.0) { f, _ in chip(f.short, symbol: f.symbol, style: .known) }
                ForEach(partly, id: \.0) { f, _ in chip(String(localized: "teilweise \(f.short.lowercased())"), symbol: f.symbol, style: .known) }
                ForEach(place.extras, id: \.title) { chip($0.title, symbol: $0.symbol, style: .known) }
            }
        }
        if !no.isEmpty {
            group(String(localized: "Gibt es nicht")) { ForEach(no, id: \.0) { f, _ in chip(f.short, symbol: f.symbol, style: .no) } }
        }
    }

    /// Die eigene Bewertung: Sie zählt nur einmal und lässt sich ändern, nicht wiederholen.
    private func myRating(_ m: PlaceService.Summary.Mine) -> some View {
        let answered = PlaceFeature.all(for: place).compactMap { f in m.votes[f.rawValue].map { (f, $0) } }
        let dogs = [m.sizes?.small == true ? String(localized: "Kleine") : nil,
                    m.sizes?.medium == true ? String(localized: "Mittlere") : nil,
                    m.sizes?.large == true ? String(localized: "Große") : nil].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Deine Bewertung").font(.display(19, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Button("Ändern") { rating = true }.font(.subheadline.weight(.semibold))
            }
            if !answered.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(answered, id: \.0) { f, v in
                        chip(f.short, symbol: v == 1 ? "haken" : f.symbol, style: v == 1 ? .yes : .no)
                    }
                }
            }
            if !dogs.isEmpty {
                Text("Hunde hier: \(dogs.joined(separator: ", "))").font(.subheadline).foregroundStyle(Palette.ink2)
            }
            if !place.enoughVotes {
                Text("Für alle sichtbar, sobald mehr Menschen bewertet haben.").font(.footnote).foregroundStyle(Palette.ink3)
            }
        }
    }

    private var invite: some View {
        VStack(alignment: .leading, spacing: 8) {
            LineIcon("hund", size: 30).foregroundStyle(Palette.accent)
            Text("Noch kaum bewertet").font(.display(19, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("Warst du schon mit deinem Hund hier? In einer halben Minute sagst du, ob man frei laufen kann und ob es Wasser und Schatten gibt. Alle, die mit Hund herkommen, sehen es dann.")
                .font(.subheadline).foregroundStyle(Palette.ink2)
            Button {
                guard signedIn else { account.presentsPack = true; return }
                rating = true
            } label: {
                Text("Ort bewerten").font(.headline).frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).padding(.top, 4)
            Text(place.voters == 0 ? String(localized: "Noch niemand hat bewertet") : place.voters == 1 ? String(localized: "1 Mensch hat bisher bewertet") : String(localized: "\(place.voters) Menschen haben bisher bewertet"))
                .font(.caption).foregroundStyle(Palette.ink2).frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(Palette.soft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 14)
    }

    private var sizes: some View {
        let s = place.sizes, total = max(1, s.reduce(0, +))
        let labels = [String(localized: "Kleine"), String(localized: "Mittlere"), String(localized: "Große")]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Hunde hier meist").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(Palette.accent.opacity([1, 0.55, 0.25][i]))
                            .frame(width: max(0, (g.size.width - 4) * CGFloat(s[i]) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 10)
            HStack {
                ForEach(0..<3, id: \.self) { i in
                    (Text(labels[i]).fontWeight(.semibold).foregroundStyle(Palette.ink) + Text(" \(s[i])").foregroundStyle(Palette.ink2))
                    if i < 2 { Spacer() }
                }
            }
            .font(.footnote)
        }
        .accessibilityElement(children: .combine)
    }

    private enum ChipStyle { case yes, unsure, no, known }

    private func group<C: View>(_ title: String, @ViewBuilder _ chips: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2).frame(width: 92, alignment: .leading)
            FlowLayout(spacing: 6) { chips() }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func chip(_ title: String, symbol: String, style: ChipStyle, count: String? = nil) -> some View {
        HStack(spacing: 5) {
            LineIcon(symbol, size: 16)
            Text(title).strikethrough(style == .no)
            if let count { Text(count).font(.caption).foregroundStyle(Palette.ink3) }
        }
        .font(.subheadline.weight(style == .yes ? .semibold : .regular))
        .foregroundStyle(style == .yes ? Color(red: 0.12, green: 0.44, blue: 0.29) : style == .no ? Palette.ink3 : Palette.ink)
        .padding(.horizontal, style == .no ? 4 : 11).padding(.vertical, 6)
        .background {
            switch style {
            case .yes: Capsule().fill(Color(red: 0.89, green: 0.95, blue: 0.92))
            case .unsure: Capsule().fill(Palette.surface).overlay(Capsule().strokeBorder(Palette.line))
            case .known: Capsule().fill(Palette.surface).overlay(Capsule().strokeBorder(Palette.ink3, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            case .no: Color.clear
            }
        }
    }

    /// Frische Zählungen vom Server (die Liste kann einige Minuten alt sein).
    private func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-erkunder") { scout = true }
        // Zum Ansehen: `-mediathek` öffnet die Auswahl der Fotos.
        if ProcessInfo.processInfo.arguments.contains("-mediathek") { pickingLibrary = true }
        // Zum Ansehen: `-bewertet` zeigt eine eigene Bewertung.
        if ProcessInfo.processInfo.arguments.contains("-bewertet") {
            let f = PlaceFeature.allCases
            mine = .init(votes: [f[0].rawValue: 1, f[2].rawValue: 1, f[4].rawValue: 0], sizes: .init(small: true, medium: true))
        }
        if ProcessInfo.processInfo.arguments.contains("-orte") { return }
        #endif
        guard let id = place.serverID, let s = try? await PlaceService.summary(id) else { return }
        place.votes = s.votes; place.voters = s.voters; place.sizes = s.sizes
        mine = s.mine
        if let ph = s.photos { place.photos = ph }
        if let at = s.checkedAt { place.checkedAt = at }
        if let f = s.facts { for (k, v) in f { place.facts[k] = v } }
        scout = s.scout ?? false
    }
}

/// Damit zwei Button-Stile in einem Ausdruck stehen können.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Bewerten: je Merkmal Ja, Nein oder Weiß nicht, dazu welche Hunde man dort meist trifft.
struct RatePlaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let place: Place
    var onSaved: (PlaceService.Summary) -> Void

    @State private var answers: [PlaceFeature: Int] = [:]   // 1 ja, 0 nein; fehlt = weiß nicht
    @State private var sizes = PlaceService.Sizes()
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(PlaceFeature.all(for: place)) { f in
                        HStack {
                            Label(f.title, icon: f.symbol)
                            Spacer()
                            Picker(f.title, selection: Binding(get: { answers[f] ?? -1 }, set: { answers[f] = $0 < 0 ? nil : $0 })) {
                                Text("Ja").tag(1); Text("Nein").tag(0); Text("Weiß nicht").tag(-1)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                        }
                    }
                } header: {
                    Text("Was stimmt hier? Du kannst es später ändern.")
                }
                Section("Welche Hunde triffst du hier meist?") {
                    Toggle("Kleine", isOn: $sizes.small)
                    Toggle("Mittlere", isOn: $sizes.medium)
                    Toggle("Große", isOn: $sizes.large)
                }
                if failed {
                    Section { Text("Nicht gesichert. Prüfe die Verbindung und versuche es noch einmal.").foregroundStyle(Palette.kind(.health)) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(place.name) {
                BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                BarTextItem(title: String(localized: "Sichern"), disabled: saving) { save() }
            }
        }
        .tint(Palette.accent)
        .task {
            guard let id = place.serverID, let s = try? await PlaceService.summary(id) else { return }
            for (k, v) in s.mine.votes { if let f = PlaceFeature(rawValue: k) { answers[f] = v } }
            if let mine = s.mine.sizes { sizes = mine }
        }
    }

    private func save() {
        guard let id = place.serverID else { dismiss(); return }
        saving = true; failed = false
        let votes = Dictionary(uniqueKeysWithValues: PlaceFeature.all(for: place).map { ($0.rawValue, answers[$0]) })
        Task {
            do {
                onSaved(try await PlaceService.vote(id, votes: votes, sizes: sizes))
                dismiss()
            } catch {
                failed = true
            }
            saving = false
        }
    }
}

/// Einen Ort eintragen: Karte verschieben, bis der Punkt stimmt, dann Name, Art und was es dort gibt.
struct AddPlaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let start: CLLocationCoordinate2D
    var onAdded: (Place) -> Void

    @State private var camera: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var name = ""
    @State private var kind = "dog_park"
    @State private var features: Set<PlaceFeature> = []
    @State private var saving = false
    @State private var message: String?

    init(start: CLLocationCoordinate2D, onAdded: @escaping (Place) -> Void) {
        self.start = start
        self.onAdded = onAdded
        _camera = State(initialValue: .camera(MapCamera(centerCoordinate: start, distance: 600)))
        _center = State(initialValue: start)
    }

    private static let kinds = [("dog_park", String(localized: "Hundezone")), ("park", String(localized: "Park")), ("meadow", String(localized: "Wiese")), ("forest", String(localized: "Wald"))]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Map(position: $camera)
                            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.park])))
                            .onMapCameraChange(frequency: .continuous) { center = $0.region.center }
                        LineIcon("pin", size: 46).foregroundStyle(Palette.accent)
                            .offset(y: -17).allowsHitTesting(false)
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    Text("Karte verschieben, bis der Punkt stimmt.").font(.footnote).foregroundStyle(Palette.ink2).padding(.top, 8)

                    Text("Name").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2).padding(.top, 18).padding(.bottom, 6)
                    TextField("z. B. Wiese am Schützenhaus", text: $name)
                        .padding(13).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("Was ist das?").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2).padding(.top, 18).padding(.bottom, 8)
                    FlowLayout(spacing: 8) {
                        ForEach(Self.kinds, id: \.0) { key, title in
                            pill(title, on: kind == key) {
                                kind = key
                                if key != "dog_park" { features.remove(.split) }
                            }
                        }
                    }

                    Text("Was es dort gibt").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2).padding(.top, 18).padding(.bottom, 8)
                    FlowLayout(spacing: 8) {
                        ForEach(PlaceFeature.all(dogZone: kind == "dog_park")) { f in
                            pill(f.short, symbol: f.symbol, on: features.contains(f)) {
                                if features.contains(f) { features.remove(f) } else { features.insert(f) }
                            }
                        }
                    }
                    if let message { Text(message).font(.subheadline).foregroundStyle(Palette.kind(.health)).padding(.top, 12) }
                    Text("Andere sehen den Ort sofort. Dein Name steht nicht dabei.")
                        .font(.footnote).foregroundStyle(Palette.ink3).padding(.top, 16)
                }
                .padding(20)
            }
            .background(Palette.paper)
            .glassBar(String(localized: "Ort eintragen")) {
                BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                BarTextItem(title: String(localized: "Eintragen"), disabled: saving || name.trimmingCharacters(in: .whitespaces).isEmpty) { save() }
            }
        }
        .tint(Palette.accent)
    }

    private func pill(_ title: String, symbol: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { LineIcon(symbol, size: 18) }
                Text(title)
            }
            .font(.subheadline.weight(on ? .semibold : .regular))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(on ? Palette.accent : Palette.ink2)
            .background(on ? Palette.soft : Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? .clear : Palette.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func save() {
        saving = true; message = nil
        let votes = Dictionary(uniqueKeysWithValues: features.map { ($0.rawValue, 1) })
        Task {
            do {
                onAdded(try await PlaceService.add(name: name.trimmingCharacters(in: .whitespaces), kind: kind, at: center, votes: votes))
                dismiss()
            } catch Api.Failure.server("rate_limited") {
                message = String(localized: "Für heute hast du schon fünf Orte eingetragen. Morgen geht es weiter.")
            } catch Api.Failure.notSignedIn {
                message = String(localized: "Melde dich im Rudel an, dann kannst du Orte eintragen.")
            } catch {
                message = String(localized: "Nicht eingetragen. Prüfe die Verbindung und versuche es noch einmal.")
            }
            saving = false
        }
    }
}
