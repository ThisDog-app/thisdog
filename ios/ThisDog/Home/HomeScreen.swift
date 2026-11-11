import CoreLocation
import SwiftUI

/// Wohin die App gerade soll: der Bereich und, wenn nötig, ein Ort, der in Gassi aufgehen soll.
@MainActor
@Observable
final class Router {
    var tab: AppTab
    var place: Place?
    init(tab: AppTab) { self.tab = tab }
}

/// Die Startseite: Zuerst die Frage, ob ihr heute schon draußen wart, dann was ansteht und in seinen Bereich führt,
/// darunter die Woche und Orte, an denen ihr noch nicht wart.
struct HomeScreen: View {
    @Environment(DogStore.self) private var store
    @Environment(Account.self) private var account
    @Environment(WalkRecorder.self) private var recorder
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var hClass
    /// Kompakt nur beim iPhone im Querformat: wenig Höhe, viel Breite.
    @Environment(\.verticalSizeClass) private var vClass
    @Environment(\.tabDockClearance) private var dockClearance

    @State private var places: [Place] = []
    @State private var loading = false
    /// Wo die Ziele zuletzt gesucht wurden (siehe Gassi).
    @State private var placesCenter: CLLocationCoordinate2D?
    @State private var showsAccount = false
    @State private var showsEmergency = false
    /// Wie oft ThisDog, das Maskottchen, auf die Nase gestupst wurde: Jedes Mal kommt ein neuer Spruch.
    @State private var boops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if vClass == .compact {
                    landscape
                } else if hClass == .regular {
                    FoldSplit {
                        ScrollView { VStack(alignment: .leading, spacing: 40) { lostBanner; greeting; walkCard; OutsideBlock(); weekBlock }.padding(.horizontal, 32).padding(.vertical, 24) }
                    } trailing: {
                        ScrollView { VStack(alignment: .leading, spacing: 40) { upcoming; discover }.padding(.horizontal, 32).padding(.vertical, 24) }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 36) { lostBanner; greeting; walkCard; OutsideBlock(); upcoming; weekBlock; discover }
                            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
                    }
                }
            }
            .background(Palette.paper)
            .clearsTabDock()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showsAccount) { SettingsScreen() }
            .sheet(isPresented: $showsEmergency) { EmergencyPassScreen() }
            .task(id: spot == nil) {
                if spot == nil, recorder.isAuthorized { recorder.locateOnce() }
                await loadPlaces()
            }
            .onChange(of: recorder.here.map { [$0.latitude, $0.longitude] }) {
                guard let here = recorder.here, !loading,
                      placesCenter.map({ Track.distance($0, here) >= PlaceFinder.refreshDistance }) ?? true else { return }
                Task { await loadPlaces() }
            }
        }
    }

    /// iPhones ohne Platz für die Leiste an der Seite: Sie liegt auch quer unten, die linke Spalte ist niedriger.
    private var tight: Bool { vClass == .compact && dockClearance > 0 }

    /// iPhone quer: Die Frage nach der Runde steht fest links, der Knopf bleibt immer in Reichweite. Rechts läuft der Rest.
    private var landscape: some View {
        HStack(alignment: .top, spacing: 20) {
            GeometryReader { g in
                ScrollView {
                    walkCard
                        .frame(minHeight: g.size.height - 20)
                        .padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                // Die Pfötchen dürfen über den Rand der Spalte fliegen.
                .scrollClipDisabled()
            }
            .frame(width: 350)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) { lostBanner; greeting; OutsideBlock(); upcoming; weekBlock; discover }
                    .padding(.top, 10).padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 4)
    }

    private var dogName: String { store.profile.name }

    /// Entlaufen: steht über allem, bei allen im Rudel.
    @ViewBuilder
    private var lostBanner: some View {
        if store.profile.isLost { LostDogBanner { showsEmergency = true } }
    }
    private var spot: CLLocationCoordinate2D? { recorder.here ?? LastPlace.load() }

    // MARK: Gruß

    private var greeting: some View {
        HStack(spacing: 14) {
            AvatarView(image: store.avatarImage(Avatar.dog), name: dogName, size: 52, isDog: true)
            Text(store.profile.ownerName.isEmpty ? Self.salute() : "\(Self.salute()), \(store.profile.ownerName)")
                .font(.display(19, weight: .regular, relativeTo: .headline))
                .foregroundStyle(Palette.ink2)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            greetingButton(String(localized: "Rudel"), symbol: "rudel") { account.presentsPack = true }
            greetingButton(String(localized: "Einstellungen"), symbol: "einstellungen") { showsAccount = true }
        }
    }

    private func greetingButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LineIcon(symbol, size: 26)
                .foregroundStyle(Palette.ink2)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    static func salute(at date: Date = Date()) -> String {
        switch Calendar.gregorianLocal.component(.hour, from: date) {
        case 5..<11: String(localized: "Guten Morgen")
        case 11..<18: String(localized: "Hallo")
        default: String(localized: "Guten Abend")
        }
    }

    // MARK: Runde

    private var todayWalks: [Walk] { store.walks.filter { $0.day == .today } }

    private var isWalking: Bool { recorder.phase != .idle || recorder.runsOnWatch }

    private var walkCard: some View {
        let quer = vClass == .compact
        return VStack(alignment: .leading, spacing: tight ? 8 : 12) {
            Text(Self.headline(walking: isWalking, walkedToday: !todayWalks.isEmpty))
                .font(.display(tight ? 23 : 27, weight: .medium))
                .foregroundStyle(Palette.ink)
            HStack(alignment: .center, spacing: 2) {
                speechBubble.frame(maxWidth: .infinity, alignment: .leading)
                boopableMark
            }
            Text(walkLine).font(quer ? .subheadline : .body).foregroundStyle(Palette.ink2)
            // Quer füllt die Karte die Spalte: Der Knopf steht dann unten, beim Daumen.
            if quer { Spacer(minLength: 0) }
            Button {
                if recorder.phase == .idle { recorder.start() }
                router.tab = .gassi
            } label: {
                Text(isWalking ? String(localized: "Zur Runde") : todayWalks.isEmpty ? String(localized: "Runde starten") : String(localized: "Noch eine Runde"))
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
            .padding(.top, tight ? 0 : 4)
        }
        .padding(tight ? 16 : 20)
        .frame(maxHeight: quer ? .infinity : nil, alignment: .top)
        .background(Palette.soft, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-stupsen") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                boops += 1
            }
        }
        #endif
    }

    /// Was ThisDog gerade zu sagen hat.
    private var speechBubble: some View {
        let last = store.walks.max { $0.start < $1.start }?.day
        return Text(Self.dogLine(walking: isWalking, walkedToday: !todayWalks.isEmpty, lastWalk: last, today: .today,
                                 hour: Calendar.gregorianLocal.component(.hour, from: Date()), seed: Self.daySeed() + boops))
            .font(.display(19, weight: .medium, relativeTo: .headline))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .animation(.snappy, value: boops)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .trailing) {
                BubbleTail().fill(Palette.surface).frame(width: 12, height: 18).offset(x: 10)
            }
            .padding(.trailing, 10)
    }

    /// Stupsen erlaubt: Das Maskottchen wackelt, Pfötchen fliegen, und es kommt ein neuer Spruch.
    private var boopableMark: some View {
        Button { boops += 1 } label: {
            StellaMark(wiggle: boops)
                .frame(width: tight ? 76 : 108, height: tight ? 76 : 108)
                .overlay { if !reduceMotion { PawBurst(trigger: boops) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "ThisDog auf die Nase stupsen"))
        .sensoryFeedback(.impact(weight: .light), trigger: boops)
    }

    private static func daySeed(_ date: Date = Date()) -> Int {
        Calendar.gregorianLocal.ordinality(of: .day, in: .year, for: date) ?? 0
    }

    /// Der Spruch zur Lage. Bleibt über den Tag gleich und wechselt erst beim Stupsen (`seed`).
    static func dogLine(walking: Bool, walkedToday: Bool, lastWalk: Day?, today: Day, hour: Int, seed: Int) -> String {
        let lines: [String]
        if walking {
            lines = [String(localized: "Hier riecht's super!"), String(localized: "Nicht so schnell, ich les noch!"), String(localized: "Da! Ein Stock!")]
        } else if walkedToday {
            lines = [String(localized: "Schön war's. Jetzt Sofa?"), String(localized: "Ich bin wunschlos. Fast. Leckerli?"), String(localized: "Morgen wieder? Morgen wieder!")]
        } else if lastWalk == nil {
            lines = [String(localized: "Unsere erste Runde! Ich bin so bereit."), String(localized: "Raus? Raus! Raus?!"), String(localized: "Ich hol schon mal die Leine.")]
        } else if let lastWalk, lastWalk.days(until: today) >= 3 {
            lines = [String(localized: "Hallo? Die Leine vermisst mich."), String(localized: "Die Wiese hat nach uns gefragt."), String(localized: "Ich hab schon alles hier beschnüffelt.")]
        } else if hour < 11 {
            lines = [String(localized: "Aufstehen! Die Wiese wartet."), String(localized: "Raus? Raus! Raus?!"), String(localized: "Ich hol schon mal die Leine.")]
        } else if hour < 18 {
            lines = [String(localized: "Ich hab da was gerochen. Komm mit!"), String(localized: "Raus? Raus! Raus?!"), String(localized: "Ich warte nur ganz zufällig an der Tür.")]
        } else {
            lines = [String(localized: "Noch eine Schnüffelrunde?"), String(localized: "Einmal noch um den Block?"), String(localized: "Im Dunkeln riecht alles besser.")]
        }
        return lines[((seed % lines.count) + lines.count) % lines.count]
    }

    // MARK: Woche

    private var weekBlock: some View {
        // Keine Serien und keine Strecken zum Angeben: Raus geht man ohnehin mehrmals am Tag, und eine Zahl,
        // die man nicht beeinflussen will, motiviert nicht, sie nervt. Stattdessen ein Spruch zum Schmunzeln.
        VStack(alignment: .leading, spacing: 10) {
            WeekLeash(walks: store.walks)
            Text(Saying.of(.today)).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func headline(walking: Bool, walkedToday: Bool) -> String {
        if walking { return String(localized: "Ihr seid unterwegs.") }
        return walkedToday ? String(localized: "Schön, ihr wart heute schon draußen.") : String(localized: "Zeit für eine Runde?")
    }

    private var walkLine: String {
        if recorder.runsOnWatch { return String(localized: "Die Runde läuft auf deiner Watch.") }
        if recorder.phase != .idle { return String(localized: "\(WalkText.distance(recorder.meters)) bis jetzt. Viel Spaß!") }
        if !todayWalks.isEmpty {
            let m = todayWalks.reduce(0) { $0 + $1.meters }, s = todayWalks.reduce(0) { $0 + $1.seconds }
            return String(localized: "Heute \(WalkText.distance(m)) in \(WalkText.duration(s))")
        }
        guard let last = store.walks.max(by: { $0.start < $1.start }) else {
            return String(localized: "Tipp auf Start, wenn ihr losgeht. Das Telefon kann in die Tasche.")
        }
        return dogName.isEmpty
            ? String(localized: "Eure letzte Runde: \(CheckIns.whenText(last.startDate)), \(WalkText.distance(last.meters)).")
            : String(localized: "\(dogName)s letzte Runde: \(CheckIns.whenText(last.startDate)), \(WalkText.distance(last.meters)).")
    }

    // MARK: Neues entdecken

    /// Die nächsten Orte, an denen ihr noch nicht eingecheckt habt.
    static func unvisited(_ places: [Place], checkIns: [CheckIn], limit: Int = 3) -> [Place] {
        let seen = Set(checkIns.map(\.place))
        return Array(places.filter { !seen.contains(CheckIn(place: $0).place) }.prefix(limit))
    }

    @ViewBuilder
    private var discover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hier wart ihr noch nicht").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink).padding(.bottom, 6)
            let list = Self.unvisited(places, checkIns: store.checkIns)
            if !list.isEmpty {
                ForEach(list) { p in
                    row(symbol: p.isDogZone ? "hund" : "park", title: p.name, line: placeLine(p)) { router.place = p; router.tab = .gassi }
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            } else if spot == nil {
                Text("Erlaube den Standort, dann zeigt dir ThisDog Parks und Hundezonen in der Nähe.")
                    .font(.subheadline).foregroundStyle(Palette.ink2)
                Button("Standort freigeben", icon: "ort") { recorder.locateOnce() }.padding(.top, 6)
            } else {
                Text("Ihr kennt schon alle Orte in der Nähe. Kennst du noch einen? Trag ihn in Gassi ein.")
                    .font(.subheadline).foregroundStyle(Palette.ink2)
            }
        }
    }

    private func placeLine(_ p: Place) -> String {
        guard let spot else { return p.label }
        let far = Track.distance(spot, p.coordinate)
        return p.name == p.label ? String(localized: "\(WalkText.distance(far)) entfernt") : String(localized: "\(p.label), \(WalkText.distance(far)) entfernt")
    }

    private func loadPlaces() async {
        guard let spot else { return }
        loading = true
        placesCenter = spot
        places = await PlaceFinder.near(spot)
        loading = false
    }

    // MARK: Was sonst ansteht

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Was sonst ansteht").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink).padding(.bottom, 6)
            // Die nächsten zwei Termine aus dem Rudelkalender.
            ForEach(NextUp.upcoming(from: store.entries, limit: 2), id: \.id) { e in
                row(symbol: "kalender", title: e.title, line: NextUp.remaining(to: e, now: Date())) { router.tab = .kalender }
            }
            if let d = store.dues.first {
                let n = Day.today.days(until: d.due)
                HStack(spacing: 10) {
                    row(symbol: "notfall", title: d.title, line: n < 0 ? String(localized: "\(d.kind), seit \(-n) Tagen fällig") : n == 0 ? String(localized: "\(d.kind), heute fällig") : (n == 1 ? String(localized: "\(d.kind), in 1 Tag fällig") : String(localized: "\(d.kind), in \(n) Tagen fällig"))) { router.tab = .hund }
                    if store.canMarkDone(d) {
                        Button("Erledigt") { withAnimation(.snappy) { store.markDone(d.id) } }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).tint(Palette.accent)
                    }
                }
            }
            row(symbol: "lupe", title: String(localized: "Darf mein Hund das fressen?"), line: String(localized: "Im Food-Check nachsehen")) { router.tab = .wissen }
        }
    }

    private func row(symbol: String, title: String, line: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LineIcon(symbol, size: 26).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(2)
                    Text(line).font(.subheadline).foregroundStyle(Palette.ink2)
                }
                Spacer(minLength: 8)
                LineIcon("chevron-rechts", size: 16).foregroundStyle(Palette.ink3)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14, style: .continuous))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
    }
}

/// Das Schwänzchen der Sprechblase, zeigt zum Maskottchen.
private struct BubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Pfötchen, die beim Stupsen auffliegen und verblassen.
private struct PawBurst: View {
    var trigger: Int

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) / 5 * Double.pi
                LineIcon("hund", size: 16 + CGFloat(i % 3) * 4)
                    .foregroundStyle(Palette.accent)
                    .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, t in
                        view
                            .rotationEffect(.degrees(cos(angle) * 30))
                            .scaleEffect(0.6 + t * 0.6)
                            .offset(x: cos(angle) * 78 * t, y: -sin(angle) * 92 * t - 16 * t)
                            .opacity(t <= 0 || t >= 1 ? 0 : 1 - t * t)
                    } keyframes: { _ in
                        KeyframeTrack {
                            MoveKeyframe(0)
                            LinearKeyframe(1, duration: 0.9, timingCurve: .easeOut)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}
