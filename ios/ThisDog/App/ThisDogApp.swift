import CoreLocation
import SwiftUI
import UserNotifications

/// Dienste des Systems, die auf jede Änderung an den Terminen folgen.
@MainActor
@Observable
final class Services {
    @ObservationIgnored let reminders = Reminders()
    @ObservationIgnored let calendar = SystemCalendar()

    func apply(_ store: DogStore) {
        reminders.schedule(store.events, extra: CalendarBuilder.dogEntries(profile: store.profile, dues: store.dues), doneable: store.markableDueIDs)
        calendar.sync(store.events)
    }
}

@main
struct ThisDogApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store: DogStore
    @State private var services: Services
    @State private var account: Account
    @State private var recorder: WalkRecorder
    @State private var watch: WatchBridge
    @State private var heat: HeatService
    @Environment(\.scenePhase) private var phase

    init() {
        let store = DogStore()
        _store = State(initialValue: store)
        let account = Account(store: store), services = Services()
        _account = State(initialValue: account)
        _services = State(initialValue: services)
        // Die Verbindung zur Watch gleich beim Start: Weckt die Watch die App im Hintergrund, entsteht keine
        // Oberfläche, und ohne sie kämen Stand und fertige Runden sonst nicht an.
        let recorder = WalkRecorder(), heat = HeatService(), watch = WatchBridge()
        _recorder = State(initialValue: recorder)
        _heat = State(initialValue: heat)
        _watch = State(initialValue: watch)
        watch.connect(store: store, recorder: recorder, heat: heat)
        // Auch hier, nicht erst mit der Oberfläche: Startet iOS die App nur im Hintergrund („Erledigt“ in einer
        // Mitteilung, stille Mitteilung des Rudels), gäbe es sonst keinen Speicher, und der Tipp ginge verloren.
        store.onEventsChanged = { [services, store] _ in services.apply(store) }
        store.onLocalChange = { [account, watch] in account.scheduleSync(); watch.refresh() }
        delegate.account = account
        delegate.store = store
    }

    var body: some Scene {
        WindowGroup {
            StartView()
                .environment(store)
                .environment(services)
                .environment(account)
                .environment(recorder)
                .environment(heat)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-beispiel") { store.seedExamples() }
                    if ProcessInfo.processInfo.arguments.contains("-revier") { store.seedCheckIns() }
                    if ProcessInfo.processInfo.arguments.contains("-rudel") { account.presentsPack = true }
                    if ProcessInfo.processInfo.arguments.contains("-runde"), recorder.phase == .idle { recorder.start() }
                    if ProcessInfo.processInfo.arguments.contains("-watchrunde") { recorder.watchWalk(running: true) }
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-rudeldemo") {
                        let photo = i + 1 < args.count ? try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])) : nil
                        account.demoPack(annaPhoto: photo)
                    }
                    if args.contains("-mitteilungen") { await PushRegistration.askPermission() }
                    // `-rudelbild <Pfad>`: Für die Prüfung der Mitteilungen – „Anna“ (Konto 2) mit Bild im Verzeichnis der Erweiterung.
                    if let i = args.firstIndex(of: "-rudelbild"), i + 1 < args.count {
                        PackDirectory.save(people: [.init(id: 2, name: "Anna")], images: [2: (try? Data(contentsOf: URL(fileURLWithPath: args[i + 1]))) ?? Data()])
                    }
                    if args.contains("-freunde") { account.friends.seedDemo(near: CLLocationCoordinate2D(latitude: 48.2236, longitude: 16.3760)) }
                    // `-hundefoto <Pfad>`: ein Foto vom Mac als Bild des Hundes (der Simulator liest das Dateisystem des Macs).
                    if let i = args.firstIndex(of: "-hundefoto"), i + 1 < args.count, let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])) {
                        store.setAvatar(Avatar.dog, photo: data)
                    }
                    #endif
                    recorder.onPoint = { [account] here, started in account.friends.walked(to: here, startedAt: started) }
                    recorder.onHere = { [heat, watch] here in
                        LastPlace.save(here)
                        Task { if await heat.refresh(at: here) { watch.refresh() } }
                    }
                    if let spot = LastPlace.load() { Task { if await heat.refresh(at: spot) { watch.refresh() } } }
                    recorder.onEnd = { [account] in account.friends.walkEnded() }
                    watch.refresh()
                    services.apply(store)
                    if !ProcessInfo.processInfo.arguments.contains("-rudeldemo") { await account.refresh() }
                    await store.refreshContent()
                }
                .onOpenURL { url in account.open(url) }
                .onChange(of: phase) { _, p in
                    if p == .active {
                        // Der Standort von vorhin stimmt nach dem Zurückkommen oft nicht mehr; während einer Runde kommt er ohnehin laufend.
                        if recorder.isAuthorized, recorder.phase == .idle { recorder.locateOnce() }
                        watch.becameActive()
                        Task { await account.sync(); await store.refreshContent() }
                    }
                }
        }
    }
}

/// Mitteilungen: die Kennung des Geräts an den Server, und Wecken, wenn sich im Rudel etwas ändert.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var account: Account?
    @MainActor var store: DogStore?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Reminders.registerCategories()
        return true
    }

    /// „Erledigt“ an einer Erinnerung, auf dem iPhone oder der Watch: abhaken, ohne die App zu öffnen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Reminders.doneAction,
              let id = response.notification.request.content.userInfo[Reminders.dueKey] as? String else { return }
        await MainActor.run { _ = self.store?.markDone(id) }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { await PushRegistration.send(token: token) }
    }

    /// Stilles Wecken vom Server: den neuen Stand des Rudels holen.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // Ein Freund ist losgegangen: Dieses Gerät entscheidet selbst, ob er nah genug ist.
        if userInfo["friend"] != nil {
            await account?.friends.handleWake(userInfo)
            return .newData
        }
        await account?.sync()
        return .newData
    }

    /// Ist die App offen, zeigt nicht iOS die Mitteilung, sondern die App selbst (oben eine kurze Meldung).
    /// Kommt sie aus dem Rudel, wird gleich abgeglichen – die Änderung steht dann schon da.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let fromPack = content.userInfo["pack"] != nil
        let by = (content.userInfo["by"] as? NSNumber)?.intValue
        let title = content.title, body = content.body
        done([])
        Task { @MainActor in
            guard let account = self.account else { return }
            if !title.isEmpty || !body.isEmpty {
                withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                    account.notice = Notice(title: title, body: body, fromPack: fromPack, by: by)
                }
            }
            if fromPack { await account.sync() }
        }
    }
}

/// Zuerst das Kennenlernen, danach die App. Wer schon einen Hund eingetragen hat, sieht es nicht mehr.
struct StartView: View {
    @Environment(DogStore.self) private var store
    @AppStorage("onboardingDone") private var done = false
    /// Einmal beim Start entschieden: Die Antwort darf sich nicht ändern, während jemand seinen Hund einträgt.
    @State private var shows: Bool?

    var body: some View {
        Group {
            if shows == true {
                OnboardingScreen {
                    done = true
                    withAnimation(.snappy) { shows = false }
                }
                .transition(.opacity)
            } else if shows == false {
                RootView().transition(.opacity)
            }
        }
        .onAppear {
            guard shows == nil else { return }
            shows = Self.shouldShow(done: done, hasProfile: store.hasProfile)
            if shows == false { done = true }
        }
    }

    private static func shouldShow(done: Bool, hasProfile: Bool) -> Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-onboarding") { return true }
        // Vorführungen und Aufnahmen bringen ihre eigenen Daten mit.
        if args.contains("-beispiel") || args.contains("-tab") { return false }
        #endif
        return !done && !hasProfile
    }
}

struct RootView: View {
    @Environment(Account.self) private var account
    @Environment(DogStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hClass
    /// Kompakt nur beim iPhone im Querformat: Die Leiste an der Seite füllt dort fast die ganze Höhe.
    @Environment(\.verticalSizeClass) private var vClass
    @State private var router = Router(tab: RootView.startTab)
    /// Bereiche werden erst beim ersten Besuch gebaut und bleiben dann, wie sie waren.
    @State private var visited: Set<AppTab> = [RootView.startTab]

    /// In der Entwicklerfassung lässt sich der Tab beim Start wählen: `-tab gassi`.
    private static var startTab: AppTab {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let t = AppTab(rawValue: args[i + 1]) { return t }
        #endif
        return .heute
    }

    /// Die Seite, auf der das System eine breite Spalte freihält (Duo: Kameraseite), sonst `nil`.
    private static func sideColumn(_ insets: EdgeInsets, verticallyCompact: Bool) -> HorizontalEdge? {
        let edge: HorizontalEdge? = insets.trailing >= 56 ? .trailing : insets.leading >= 56 ? .leading : nil
        if DeviceCode.looksLikeDuo(hasSideColumn: edge != nil, isPhone: UIDevice.current.userInterfaceIdiom == .phone, verticallyCompact: verticallyCompact),
           !DeviceCode.seenDuo { DeviceCode.seenDuo = true }
        return edge
    }

    @ViewBuilder
    private func screen(_ t: AppTab) -> some View {
        switch t {
        case .heute: HomeScreen()
        case .kalender: CalendarScreen()
        case .gassi: GassiScreen()
        case .hund: DogScreen()
        case .wissen: KnowledgeScreen()
        }
    }

    var body: some View {
        @Bindable var account = account
        @Bindable var router = router
        let tab = router.tab
        GeometryReader { g in
            let side = Self.sideColumn(g.safeAreaInsets, verticallyCompact: vClass == .compact)
            ZStack {
                ForEach(AppTab.allCases) { t in
                    if visited.contains(t) {
                        screen(t)
                            .opacity(t == tab ? 1 : 0)
                            .allowsHitTesting(t == tab)
                            .accessibilityHidden(t != tab)
                            .environment(\.tabDockClearance, side == nil ? TabDock.clearance : 0)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if side == nil {
                    // iPad: unter der rechten Hälfte, beim rechten Daumen. iPhone: in der Mitte.
                    HStack(spacing: 0) {
                        if hClass == .regular { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        TabDock(tab: $router.tab).frame(maxWidth: .infinity)
                    }
                    .padding(.bottom, 2)
                }
            }
            .overlay(alignment: Alignment(horizontal: side == .leading ? .leading : .trailing, vertical: vClass == .compact ? .center : .bottom)) {
                if let side {
                    let width = side == .leading ? g.safeAreaInsets.leading : g.safeAreaInsets.trailing
                    // iPhone quer: mittig auf dem ganzen Bildschirm, nicht nur im Bereich über dem Home-Balken.
                    // Aufgeklappt bleibt sie unten beim Daumen.
                    let compact = vClass == .compact
                    TabDock(tab: $router.tab, vertical: true)
                        .frame(width: width)
                        .padding(.bottom, compact ? 0 : 12)
                        .offset(x: side == .leading ? -width : width,
                                y: compact ? (g.safeAreaInsets.bottom - g.safeAreaInsets.top) / 2 : 0)
                }
            }
        }
        .onChange(of: router.tab) { _, t in
            visited.insert(t)
            // Bereiche bleiben im Hintergrund erhalten; ein Suchfeld behielte sonst den Fokus und die Tastatur bliebe stehen.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .environment(router)
        .tint(Palette.accent)
        .ownView(isPresented: $account.presentsPack, regular: hClass == .regular) { PackScreen() }
        .overlay(alignment: .top) {
            if let notice = account.notice {
                NoticeBanner(notice: notice, image: notice.by.flatMap { store.avatarImage(Avatar.member($0)) }) {
                    withAnimation(.snappy) { if account.notice?.id == notice.id { account.notice = nil } }
                }
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .sensoryFeedback(.impact(weight: .light), trigger: notice.id)
            }
        }
        #if DEBUG
        .task {
            // Für Bildschirmfotos: `-quer` dreht das Fenster ins Querformat (iPad).
            if ProcessInfo.processInfo.arguments.contains("-quer") {
                try? await Task.sleep(for: .seconds(1))
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { print("Querformat abgelehnt:", $0) }
                }
            }
            // Zurück ins Hochformat: `-hoch`.
            if ProcessInfo.processInfo.arguments.contains("-hoch"), let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
            // Zum Ansehen: `-meldung` zeigt nach dem Start eine Meldung aus dem Rudel.
            if ProcessInfo.processInfo.arguments.contains("-meldung") {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                    account.notice = Notice(title: String(localized: "Anna"), body: String(localized: "hat einen Termin eingetragen."), fromPack: true, by: 2)
                }
            }
        }
        #endif
    }
}

