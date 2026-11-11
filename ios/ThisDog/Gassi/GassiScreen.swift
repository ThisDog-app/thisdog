import MapKit
import SwiftUI

/// Gassi: Die Karte ist die Hauptsache und füllt den Bildschirm; alles andere liegt darüber (`MapStage`).
/// Vor der Runde Reiter für Wohin, Runden, Freunde und Revier; jeder nutzt dieselbe Karte.
/// Eine angetippte Runde oder ein Ort erscheint in derselben Karte, nicht in einem eigenen Fenster.
struct GassiScreen: View {
    @Environment(DogStore.self) private var store
    @Environment(Account.self) private var account
    @Environment(WalkRecorder.self) private var recorder
    @Environment(Router.self) private var router

    @State private var places: [Place] = []
    @State private var loadingPlaces = false
    /// Wo die Ziele zuletzt gesucht wurden. Wer sich weiter entfernt, bekommt eine neue Liste.
    @State private var placesCenter: CLLocationCoordinate2D?
    /// Die eben beendete Runde, bis sie behalten oder verworfen ist. Sie liegt auf der Karte.
    @State private var finished: Walk?
    /// Die Runde, die gerade auf der Karte liegt.
    @State private var shownWalk: Walk?
    @State private var reiter: GassiReiter = .wohin
    @State private var detent: StageDetent = .middle
    @State private var confirmsDiscard = false
    @State private var friendInvite: URL?
    @State private var invitingFriend = false
    @State private var showsNearby = false
    /// Der Ort, dessen Seite offen ist (iPhone: als Blatt; Duo und iPad: rechts neben der Karte).
    @State private var selected: Place?
    @State private var addingPlace = false
    @State private var isScout = false
    @State private var showsChecks = false
    /// Unterwegs nicht noch einmal fragen, wenn „Später“ getippt wurde.
    @State private var dismissedNear: Set<String> = []

    var body: some View {
        stage
        .background(Palette.paper)
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-rundekarte") { show(store.walks.max { $0.start < $1.start }) }
            if args.contains("-fertig") { finished = store.walks.max { $0.start < $1.start } }
            if args.contains("-quer") {
                (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
            }
            if let i = args.firstIndex(of: "-reiter"), i + 1 < args.count, let r = GassiReiter(rawValue: args[i + 1]) { reiter = r }
            if let i = args.firstIndex(of: "-stufe"), i + 1 < args.count, let d = StageDetent(rawValue: args[i + 1]) { detent = d }
        }
        #endif
        .onChange(of: selected?.id) { _, id in
            guard id != nil else { return }
            shownWalk = nil
            reiter = .wohin
            makeMapVisible()
        }
        // Beim Start der Runde (nicht bei Pause und Weiter) die Ortsseite schließen.
        .onChange(of: recorder.phase) { old, phase in
            if old == .idle, phase != .idle { shownWalk = nil; selected = nil }
        }
        // Läuft die Runde auf der Watch, kennt das iPhone den Standort sonst nur von vorhin –
        // fürs Einchecken unterwegs alle halbe Minute neu.
        .task(id: recorder.runsOnWatch) {
            while recorder.runsOnWatch, recorder.phase == .idle, !Task.isCancelled {
                if recorder.isAuthorized { recorder.locateOnce() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .sheet(isPresented: $showsNearby) { NearbySheet() }
        .sheet(isPresented: $showsChecks) { MyChecksScreen() }
        // Prüfungen, die ohne Netz gemacht wurden, gehen raus; ob man Erkunder ist, sagt der Server.
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-erkunder") { isScout = true }
            #endif
            guard signedIn else { return }
            await CheckQueue.flush()
            isScout = (try? await PlaceService.mine().scout) ?? false
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-erkunder") { isScout = true }
            #endif
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-revieransicht") { reiter = .revier }
            if ProcessInfo.processInfo.arguments.contains("-hundnah") { showsNearby = true }
        }
        #endif
        .onChange(of: walking) { _, now in if !now { dismissedNear = [] } }
        // Von der Startseite: Dieser Ort soll aufgehen.
        .task(id: router.place?.id) {
            if let p = router.place { selected = p; router.place = nil }
        }
        .sheet(isPresented: $addingPlace) {
            if let here = recorder.here {
                AddPlaceSheet(start: here) { p in places.insert(p, at: 0); selected = p }
            }
        }
        // Nach dem Standort wird erst gefragt, wenn jemand ihn freigibt – nicht beim Öffnen der App.
        // Ist er schon freigegeben, holt Gassi ihn beim Zeigen selbst.
        .task(id: recorder.here == nil) {
            if recorder.here == nil {
                if recorder.isAuthorized { recorder.locateOnce() }
            } else if places.isEmpty {
                await loadPlaces()
            }
        }
        // Unterwegs: Liegt der Standort weit genug von der letzten Suche weg, neu suchen.
        .onChange(of: recorder.here.map { [$0.latitude, $0.longitude] }) {
            guard let here = recorder.here, let c = placesCenter, !loadingPlaces,
                  Track.distance(c, here) >= PlaceFinder.refreshDistance else { return }
            Task { await loadPlaces() }
        }
        .animation(.snappy, value: recorder.phase)
        .animation(.snappy, value: nearPlace?.id)
        // Freunde laden und, solange es welche gibt, alle 20 Sekunden schauen, wer unterwegs ist.
        .task {
            await account.friends.load()
            while !Task.isCancelled {
                await account.friends.refreshLive()
                await account.friends.refreshVisits()
                try? await Task.sleep(for: .seconds(Friends.interval))
            }
        }
    }

    // MARK: Karte und Panel

    private var idle: Bool { recorder.phase == .idle }
    private var showsRevier: Bool { idle && finished == nil && reiter == .revier && selected == nil }
    /// Die Runde, die vor der nächsten auf der Karte liegt.
    private var walkOnMap: Walk? { finished ?? shownWalk }

    private var stage: some View {
        MapStage(detent: $detent, fitsContent: !idle && selected == nil) { insets in
            // Auch unterwegs liegen die Orte auf der Karte: gehen, Hundezone, weitergehen ist eine Runde.
            WalkMap(track: idle ? (walkOnMap?.coordinates ?? []) : recorder.coordinates, here: recorder.here,
                    places: (idle && walkOnMap == nil && !showsRevier) || !idle ? Array(places.prefix(12)) : [], follows: !idle && selected == nil, fallback: lastSpot,
                    friends: account.friends.live, friendInfo: account.friends.list, onSelect: { selected = $0 },
                    selected: selected?.id, focus: selected?.coordinate, focusDistance: 1100,
                    fitsTrack: showsRevier ? "revier" : walkOnMap?.id, revier: showsRevier ? Revier(store.checkIns).spots : [])
                .safeAreaPadding(insets)
        } top: {
            nearCard
        } header: {
            if finished != nil {
                keepButtons
            } else if idle {
                VStack(spacing: 12) {
                    HeatBanner()
                    startButton
                    if recorder.runsOnWatch, selected == nil { reachableSection }
                    reiterLeiste
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    LiveStats(compact: true)
                        .overlay(alignment: .topTrailing) {
                            // Klein und mit Rückfrage, auf Höhe von „Unterwegs“: Abbrechen ist die Ausnahme.
                            Button("Abbrechen") { confirmsDiscard = true }
                                .font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
                        }
                    controls
                    if selected == nil { reachableSection }
                }
            }
        } content: {
            if let walk = finished {
                ScrollView { finishedContent(walk).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24) }
            } else if idle {
                panelContent
            } else if let p = selected {
                // Unterwegs: die Ortsseite unter der laufenden Runde, zurück geht es zur Runde.
                PlaceScreen(place: p, showsMap: false, onClose: { selected = nil }, onChange: update, parent: String(localized: "Runde"))
                    .id(p.id)
            }
        }
    }

    // MARK: Nach der Runde

    /// Die Runde ist beim Beenden schon gespeichert; hier geht es nur noch um die Notiz.
    private var keepButtons: some View {
        Button {
            closeFinished()
        } label: {
            Text("Fertig").font(.headline).foregroundStyle(Palette.paper).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.ink)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    /// Schließt die Zusammenfassung und speichert die Notiz, falls eine dazugekommen ist. Geändert wird nur die Notiz
    /// an der Runde, wie sie jetzt im Speicher liegt: Inzwischen gelöscht (auch im Rudel), bleibt sie gelöscht, und
    /// was ein anderes Gerät seither geändert hat, bleibt.
    private func closeFinished() {
        if let finished, var current = store.walks.first(where: { $0.id == finished.id }),
           finished.notes != current.notes {
            current.notes = finished.notes
            store.save(current)
        }
        finished = nil
    }

    private func finishedContent(_ walk: Walk) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Schöne Runde.")
                .font(.display(28)).foregroundStyle(Palette.ink)
            HStack(alignment: .top, spacing: 20) {
                WalkNumber(label: String(localized: "Strecke"), value: WalkText.km(walk.meters), unit: "km")
                WalkNumber(label: String(localized: "Zeit"), value: WalkText.clock(walk.seconds), unit: nil)
                WalkNumber(label: String(localized: "Tempo"), value: WalkText.pace(walk.pace), unit: "/km")
            }
            TextField("Notiz, z. B. „Erstes Mal ohne Leine“", text: Binding(get: { finished?.notes ?? "" }, set: { finished?.notes = $0 }), axis: .vertical)
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bringt eine Runde auf die Karte (nil: wieder weg) und lässt die Karte dabei sichtbar.
    private func show(_ walk: Walk?) {
        shownWalk = walk
        guard walk != nil else { return }
        selected = nil
        reiter = .runden
        makeMapVisible()
    }

    private func makeMapVisible() {
        if detent != .middle { withAnimation(.snappy) { detent = .middle } }
    }

    private var reiterLeiste: some View {
        HStack(spacing: 2) {
            ForEach(GassiReiter.allCases) { r in
                ReiterButton(title: r.title, on: reiter == r) {
                    withAnimation(.snappy) {
                        reiter = r
                        selected = nil
                        shownWalk = nil
                        if detent == .peek { detent = .middle }
                    }
                }
            }
        }
        .padding(3)
        .background(Palette.surface, in: Capsule())
    }

    @ViewBuilder
    private var panelContent: some View {
        if let p = selected {
            PlaceScreen(place: p, showsMap: false, onClose: { selected = nil }, onChange: update, parent: String(localized: "Wohin heute?"))
                .id(p.id)
        } else {
            ScrollView {
                Group {
                    switch reiter {
                    case .wohin: wohinList
                    case .runden: rundenList
                    case .freunde: friendsSection
                    case .revier: RevierPanel()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
    }

    /// Wo die letzte Runde begann.
    private var lastSpot: CLLocationCoordinate2D? {
        store.walks.max { $0.start < $1.start }?.coordinates.first
    }

    private var wohinList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wohin heute?")
                .font(.display(22, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.bottom, 6)

            if let here = recorder.here {
                if places.isEmpty {
                    Text(loadingPlaces ? String(localized: "Ziele werden gesucht …") : String(localized: "In der Nähe ist nichts verzeichnet."))
                        .font(.subheadline).foregroundStyle(Palette.ink3).padding(.vertical, 12)
                }
                ForEach(places.prefix(12)) { p in
                    Button { selected = p } label: { placeRow(p, here: here) }
                        .buttonStyle(.plain)
                    if p.id != places.prefix(12).last?.id { Divider().overlay(Palette.line).padding(.leading, 46) }
                }
                Button {
                    guard signedIn else { account.presentsPack = true; return }
                    addingPlace = true
                } label: {
                    Label("Ort fehlt? Eintragen", icon: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 10)
            } else {
                Button("Standort freigeben", icon: "ort") { recorder.locateOnce() }
                    .buttonStyle(.bordered)
            }

            if store.profile.tracker { findMy.padding(.top, 18) }
            if isScout {
                Button { showsChecks = true } label: {
                    Label("Meine Prüfungen", icon: "pruefung").font(.subheadline.weight(.semibold))
                }
                .padding(.top, 12)
            }
            AsphaltSection().padding(.top, 28)
        }
    }

    @ViewBuilder
    private var rundenList: some View {
        if let walk = shownWalk {
            walkDetail(walk)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                WeekLeash(walks: store.walks)
                let all = store.walks.sorted { $0.start > $1.start }
                if all.isEmpty {
                    Text("Noch keine Runden. Eure erste erscheint hier, sobald ihr unterwegs wart.")
                        .font(.subheadline).foregroundStyle(Palette.ink2).padding(.top, 24)
                } else {
                    Text("Letzte Runden")
                        .font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink)
                        .padding(.top, 24).padding(.bottom, 4)
                    LazyVStack(spacing: 0) {
                        ForEach(all) { w in
                            Button { show(w) } label: {
                                WalkRow(walk: w, by: account.name(of: store.changer(of: w)), walker: account.author(of: w, includeMe: true))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if w.id != all.last?.id { Divider().overlay(Palette.line).padding(.leading, 54) }
                        }
                    }
                }
            }
        }
    }

    /// Die angetippte Runde: Ihre Strecke liegt schon auf der Karte, hier stehen die Zahlen.
    private func walkDetail(_ walk: Walk) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Breadcrumb(parent: String(localized: "Runden"), current: walk.startDate.formatted(date: .abbreviated, time: .omitted)) { show(nil) }
            Text(walk.startDate.formatted(date: .long, time: .shortened))
                .font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
            HStack(alignment: .top, spacing: 20) {
                WalkNumber(label: String(localized: "Strecke"), value: WalkText.km(walk.meters), unit: "km")
                WalkNumber(label: String(localized: "Zeit"), value: WalkText.clock(walk.seconds), unit: nil)
                WalkNumber(label: String(localized: "Tempo"), value: WalkText.pace(walk.pace), unit: "/km")
            }
            if !walk.notes.isEmpty {
                Text(walk.notes).font(.body).foregroundStyle(Palette.ink2)
            }
        }
    }

    // MARK: Revier

    /// Läuft gerade eine Runde – hier oder auf der Watch?
    private var walking: Bool { recorder.phase != .idle || recorder.runsOnWatch }

    /// Orte, an denen man jetzt einchecken kann (höchstens 300 m), die nächsten zuerst.
    private var reachable: [Place] {
        guard let here = recorder.here else { return [] }
        return Array(places.filter { CheckIns.inReach($0, from: here) }.prefix(3))
    }

    /// Unterwegs unter den Knöpfen: hier einchecken, ohne die Runde zu unterbrechen.
    @ViewBuilder
    private var reachableSection: some View {
        let list = reachable
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hier in der Nähe").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
                ForEach(list) { p in
                    HStack(spacing: 10) {
                        Button { selected = p } label: {
                            HStack(spacing: 10) {
                                LineIcon(p.isDogZone ? "hund" : "park", size: 20).foregroundStyle(Palette.accent)
                                    .frame(width: 34, height: 34).background(Palette.soft, in: Circle())
                                Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if let recent = CheckIns.recent(p, in: store.checkIns) {
                            Label(recent.date.formatted(date: .omitted, time: .shortened), icon: "haken")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                                .accessibilityLabel(String(localized: "Eingecheckt um \(recent.date.formatted(date: .omitted, time: .shortened))"))
                        } else {
                            Button { CheckIns.perform(p, store: store, account: account) } label: {
                                Label("Einchecken", icon: "pin").font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Palette.accent)
                            .sensoryFeedback(.success, trigger: store.checkIns.count)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Unterwegs an einem Ort (höchstens 80 m): einchecken oder später.
    private var nearPlace: Place? {
        guard walking, selected == nil, let here = recorder.here else { return nil }
        return places.first { p in
            Track.distance(here, p.coordinate) <= CheckIns.promptDistance && !dismissedNear.contains(p.id) && CheckIns.recent(p, in: store.checkIns) == nil
        }
    }

    @ViewBuilder
    private var nearCard: some View {
        if let p = nearPlace {
            let n = CheckIns.visits(to: p, in: store.checkIns).count
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    LineIcon(p.isDogZone ? "hund" : "park", size: 24).foregroundStyle(Palette.accent)
                        .frame(width: 42, height: 42).background(Palette.soft, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Du bist bei \(p.name)").font(.display(18, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text(n == 0 ? String(localized: "Zum ersten Mal hier") : String(localized: "\(store.profile.name.isEmpty ? "Dein Hund" : store.profile.name) war \(n)-mal hier"))
                            .font(.subheadline).foregroundStyle(Palette.ink2)
                    }
                }
                HStack {
                    Button { CheckIns.perform(p, store: store, account: account) } label: {
                        Label("Einchecken", icon: "pin").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Später") { dismissedNear.insert(p.id) }.buttonStyle(.bordered).tint(Palette.ink2)
                }
                .controlSize(.large).buttonBorderShape(.capsule)
            }
            .padding(16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Hundefreunde

    private var signedIn: Bool { if case .signedIn = account.state { true } else { false } }

    private var friendsSection: some View {
        let friends = account.friends
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hundefreunde").font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                if let friendInvite {
                    ShareLink(item: friendInvite, subject: Text("Werden unsere Hunde Freunde?"),
                              message: Text("Mit diesem Link sehen sich unsere Hunde in ThisDog auf der Karte, solange wir Gassi gehen.")) {
                        Label("Link teilen", icon: "teilen").font(.subheadline.weight(.semibold))
                    }
                } else {
                    Button {
                        guard signedIn else { account.presentsPack = true; return }
                        invitingFriend = true
                        Task {
                            friendInvite = try? await friends.invite()
                            invitingFriend = false
                        }
                    } label: {
                        Label("Einladen", icon: "plus").font(.subheadline.weight(.semibold))
                    }
                    .disabled(invitingFriend)
                }
            }
            Button {
                showsNearby = true
            } label: {
                Label("Hund in der Nähe", icon: "funk").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if let m = friends.message { Text(m).font(.subheadline).foregroundStyle(Palette.kind(.health)) }
            if friends.list.isEmpty {
                Text("Befreundete Hunde seht ihr auf der Karte, solange ihr beide gerade Gassi geht. Geht einer in eurer Nähe los, sagt ThisDog Bescheid.")
                    .font(.subheadline).foregroundStyle(Palette.ink2)
            }
            ForEach(friends.list) { f in
                let spot = friends.live.first { $0.pack == f.pack }
                HStack(spacing: 12) {
                    AvatarView(image: f.photo, name: f.name, size: 40, isDog: f.photo == nil)
                        .overlay(alignment: .bottomTrailing) {
                            if spot != nil {
                                Circle().fill(Palette.verdict(.ok)).frame(width: 12, height: 12)
                                    .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 2))
                            }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.name).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text(friendLine(spot)).font(.subheadline).foregroundStyle(spot == nil ? Palette.ink3 : Palette.ink2)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .contextMenu {
                    Button("Freundschaft beenden", menuIcon: "person-minus", role: .destructive) {
                        Task { await friends.remove(f) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func friendLine(_ spot: Friends.Spot?) -> String {
        guard let spot else { return String(localized: "Gerade nicht unterwegs") }
        guard let here = recorder.here else { return String(localized: "Gerade unterwegs") }
        return String(localized: "Gerade unterwegs, \(WalkText.distance(Track.distance(here, spot.coordinate))) entfernt")
    }

    /// Apple lässt keine App den Standort eines AirTags lesen; der Weg führt in „Wo ist?“.
    private var findMy: some View {
        Button {
            if let url = URL(string: "findmy://items") { UIApplication.shared.open(url) }
        } label: {
            Label("\(store.profile.name.isEmpty ? "Hund" : store.profile.name) in „Wo ist?“ suchen", icon: "orten")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Palette.accent)
    }

    private func placeRow(_ p: Place, here: CLLocationCoordinate2D) -> some View {
        let round = p.roundTrip(from: here)
        return HStack(spacing: 12) {
            LineIcon(p.isDogZone ? "hund" : "park", size: 20)
                .foregroundStyle(Palette.accent)
                .frame(width: 34, height: 34)
                .background(Palette.soft, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(placeLine(p, round: round))
                    .font(.subheadline).foregroundStyle(Palette.ink2).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(WalkText.distance(Track.distance(here, p.coordinate)))
                .font(.display(17, weight: .semibold, relativeTo: .body)).foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// „Hundezone, eingezäunt, Wasser“ – was man vor dem Losgehen wissen will; sonst die geschätzte Runde.
    private func placeLine(_ p: Place, round: Double) -> String {
        let good = [PlaceFeature.fenced, .water, .shade].filter { if case .yes = p.verdict($0) { true } else { false } }
        if !good.isEmpty {
            let words = good.map { $0 == .fenced ? String(localized: "eingezäunt") : $0 == .water ? String(localized: "Wasser") : String(localized: "Schatten") }
            return ([p.label] + words).joined(separator: ", ")
        }
        // Namenlose Hundezonen heißen schon „Hundezone“ – dann nicht zweimal.
        return (p.name == p.label ? String(localized: "Runde etwa \(WalkText.distance(round)), \(Place.minutes(for: round)) Min.") : String(localized: "\(p.label), Runde etwa \(WalkText.distance(round)), \(Place.minutes(for: round)) Min."))
    }

    /// Eine neue Bewertung in der Liste nachziehen.
    private func update(_ p: Place) {
        if let i = places.firstIndex(where: { $0.id == p.id }) { places[i] = p }
        if selected?.id == p.id { selected = p }
    }

    @ViewBuilder
    private var startButton: some View {
        if recorder.runsOnWatch {
            Text("Die Runde läuft auf deiner Watch.")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        } else {
            Button {
                recorder.start()
            } label: {
                Text("Runde starten").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .sensoryFeedback(.start, trigger: recorder.phase == .recording)
        }
    }

    private func loadPlaces() async {
        guard let here = recorder.here else { return }
        loadingPlaces = true
        placesCenter = here
        places = await PlaceFinder.near(here)
        loadingPlaces = false
        #if DEBUG
        // Für Bildschirmfotos (`-orte`): die nächste Hundezone mit Bewertungen; `-ortseite` öffnet sie.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-orte"), let i = places.firstIndex(where: \.isDogZone) {
            places[i].votes = ["off_leash": [9, 0], "fenced": [7, 1], "water": [8, 1], "clean": [5, 4], "grass": [3, 4], "shade": [6, 3], "bench": [9, 0], "bags": [8, 1], "split": [7, 0]]
            places[i].voters = 9
            places[i].sizes = [6, 5, 2]
            places[i].checkedAt = Date().addingTimeInterval(-4 * 86400).timeIntervalSince1970
            if args.contains("-ortseite") { selected = places[i] }
        }
        #endif
    }

    // MARK: Unterwegs

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                recorder.phase == .paused ? recorder.resume() : recorder.pause()
            } label: {
                Text(recorder.phase == .paused ? String(localized: "Weiter") : String(localized: "Pause")).font(.headline).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .tint(Palette.ink)
            Button {
                // Abschließen heißt Behalten: Wer die Runde nicht will, bricht sie ab.
                if let walk = recorder.finish() {
                    store.save(walk)
                    finished = walk
                    detent = .middle
                }
            } label: {
                // Die Schrift ausdrücklich in Papierfarbe: Sonst färbt der Akzent sie ein, und im Dunkeln
                // stünde Orange auf fast weißem Grund.
                Text("Abschließen").font(.headline).foregroundStyle(Palette.paper).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.ink)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .sensoryFeedback(.selection, trigger: recorder.phase)
        .confirmationDialog("Runde abbrechen?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Runde verwerfen", role: .destructive) { recorder.discard() }
            Button("Weiterlaufen", role: .cancel) {}
        } message: {
            Text("Die Runde wird nicht gespeichert.")
        }
    }
}

private struct WalkNumber: View {
    let label: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.display(36, weight: .bold, width: 75)).monospacedDigit().foregroundStyle(Palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).font(.display(16, weight: .medium)).foregroundStyle(Palette.ink2).fixedSize() }
            }
        }
    }
}

/// Die Reiter im Panel über der Karte.
enum GassiReiter: String, CaseIterable, Identifiable {
    case wohin, runden, freunde, revier
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wohin: String(localized: "Wohin")
        case .runden: String(localized: "Runden")
        case .freunde: String(localized: "Freunde")
        case .revier: String(localized: "Revier")
        }
    }
}
