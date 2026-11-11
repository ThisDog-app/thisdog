import MapKit
import SwiftUI

/// Die Karte: Apple Karten, ruhig gestellt, damit die Runde die einzige laute Linie ist.
/// Die Strecke endet am aktuellen Standort in einem Punkt – die Linie aus dem Logo.
struct WalkMap: View {
    var track: [CLLocationCoordinate2D] = []
    var here: CLLocationCoordinate2D?
    var places: [Place] = []
    /// Unterwegs folgt die Karte dem Standort; danach zeigt sie die ganze Runde.
    var follows = false
    /// Wo die Karte steht, solange es keinen Standort gibt (die letzte Runde) – sonst zeigte sie einen Kontinent.
    var fallback: CLLocationCoordinate2D?
    /// Befreundete Hunde, die gerade unterwegs sind.
    var friends: [Friends.Spot] = []
    var friendInfo: [Friends.Friend] = []
    /// Ein Ort auf der Karte wurde angetippt.
    var onSelect: ((Place) -> Void)? = nil
    /// Der gerade gezeigte Ort ist hervorgehoben.
    var selected: String? = nil
    /// Hierhin stellt sich die Karte (ein angetippter Ort), mit diesem Abstand in Metern.
    var focus: CLLocationCoordinate2D? = nil
    var focusDistance: CLLocationDistance = 700
    /// Ändert sich dieser Wert, stellt sich die Karte auf die ganze Strecke (eine angetippte Runde).
    var fitsTrack: String? = nil
    /// Das Revier: die Orte, an denen der Hund war, je größer, desto öfter.
    var revier: [Revier.Spot] = []
    /// Adressen (Reiter „Adressen“): kleine Punkte, der Sponsor in Akzentfarbe mit „Anzeige“ darunter.
    var services: [Service] = []
    var sponsor: Service? = nil
    var onSelectService: ((Service) -> Void)? = nil

    /// Nie `.userLocation`: Das fragt selbst nach dem Standort, sobald die Karte entsteht – auch wenn
    /// niemand Gassi geöffnet hat. Die Karte folgt stattdessen dem Standort, den die App schon hat.
    @State private var camera: MapCameraPosition = .automatic
    /// Die Karte steht nur behelfsweise (letzte Runde), bis der Standort kommt.
    @State private var onFallback = false

    var body: some View {
        Map(position: $camera) {
            if track.count > 1 {
                MapPolyline(coordinates: track)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let first = track.first {
                Annotation(String(localized: "Start"), coordinate: first, anchor: .center) {
                    Circle().strokeBorder(Palette.accent, lineWidth: 3).background(Circle().fill(.white)).frame(width: 14, height: 14)
                }
                .annotationTitles(.hidden)
            }
            let most = max(1, revier.map(\.visits).max() ?? 1)
            ForEach(revier) { s in
                Annotation(s.name, coordinate: s.coordinate, anchor: .center) {
                    let size = 12 + 26 * CGFloat(s.visits) / CGFloat(most)
                    Circle().fill(Palette.accent.opacity(0.35 + 0.6 * Double(s.visits) / Double(most)))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .frame(width: size, height: size)
                }
            }
            ForEach(places) { p in
                Annotation(p.name, coordinate: p.coordinate, anchor: .center) {
                    let on = p.id == selected
                    ZStack {
                        if on {
                            Circle().fill(Palette.accent).frame(width: 30, height: 30)
                            LineIcon(p.isDogZone ? "hund" : "park", size: 18).foregroundStyle(.white)
                        } else {
                            Circle().strokeBorder(p.isDogZone ? Palette.accent : Palette.ink, lineWidth: 1.6)
                                .background(Circle().fill(.white)).frame(width: 12, height: 12)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                    .onTapGesture { onSelect?(p) }
                    .accessibilityAddTraits(.isButton)
                }
            }
            ForEach(services) { s in
                Annotation(s.name, coordinate: s.coordinate, anchor: .center) {
                    servicePin(s, ad: false)
                }
                .annotationTitles(.hidden)
            }
            if let sponsor {
                Annotation(sponsor.name, coordinate: sponsor.coordinate, anchor: .top) {
                    servicePin(sponsor, ad: true)
                }
                .annotationTitles(.hidden)
            }
            ForEach(friends) { spot in
                let info = friendInfo.first { $0.pack == spot.pack }
                Annotation(info?.name ?? String(localized: "Freund"), coordinate: spot.coordinate, anchor: .center) {
                    AvatarView(image: info?.photo, name: info?.name ?? "", size: 36, isDog: info?.photo == nil)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .overlay(Circle().strokeBorder(Palette.accent, lineWidth: 1.5).padding(-1.5))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                }
            }
            if let here {
                Annotation(String(localized: "Hier"), coordinate: here, anchor: .center) {
                    ZStack {
                        Circle().fill(Palette.accent.opacity(0.16)).frame(width: 44, height: 44)
                        Circle().fill(Palette.accent).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.park, .nationalPark])))
        .mapControls { MapCompass() }
        .onChange(of: fitsTrack) { _, id in
            if id != nil, !fitCoordinates.isEmpty {
                withAnimation(.smooth) { camera = .rect(Self.rect(fitCoordinates)) }
            } else if let center = here ?? fallback {
                withAnimation(.smooth) { camera = .camera(MapCamera(centerCoordinate: center, distance: 2600)) }
            }
        }
        .onChange(of: focus.map { "\($0.latitude),\($0.longitude)" }) { _, _ in
            guard let focus else { return }
            withAnimation(.smooth) { camera = .camera(MapCamera(centerCoordinate: focus, distance: focusDistance)) }
        }
        .onAppear {
            if let focus {
                camera = .camera(MapCamera(centerCoordinate: focus, distance: focusDistance))
                return
            }
            if here == nil, track.isEmpty, let fallback {
                camera = .camera(MapCamera(centerCoordinate: fallback, distance: 2500))
                onFallback = true
            }
        }
        .onChange(of: here.map { "\($0.latitude),\($0.longitude)" }) { _, _ in
            guard let here else { return }
            if follows {
                withAnimation(.smooth) { camera = .camera(MapCamera(centerCoordinate: here, distance: 900)) }
            } else if focus == nil, fitCoordinates.isEmpty, onFallback || camera == .automatic {
                camera = .camera(MapCamera(centerCoordinate: here, distance: 2600))
                onFallback = false
            }
        }
        .onAppear {
            if focus != nil { return }
            if !follows, !fitCoordinates.isEmpty {
                camera = .rect(Self.rect(fitCoordinates))
            } else if let here {
                camera = .camera(MapCamera(centerCoordinate: here, distance: follows ? 900 : 2600))
            }
        }
    }

    /// Eine Adresse auf der Karte; gewählt groß mit dem Icon ihrer Art (wie bei Orten).
    private func servicePin(_ s: Service, ad: Bool) -> some View {
        let on = s.id == selected
        return VStack(spacing: 2) {
            ZStack {
                if on {
                    Circle().fill(Palette.accent).frame(width: 30, height: 30)
                    LineIcon(s.icon, size: 18).foregroundStyle(.white)
                } else if ad {
                    Circle().fill(Palette.accent).overlay(Circle().strokeBorder(.white, lineWidth: 2)).frame(width: 14, height: 14)
                } else {
                    Circle().strokeBorder(Palette.ink, lineWidth: 1.6)
                        .background(Circle().fill(.white)).frame(width: 10, height: 10)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            .onTapGesture { onSelectService?(s) }
            .accessibilityAddTraits(.isButton)
            if ad {
                // Der Punkt sitzt auf der Adresse (Anker oben, Mitte des Kreises), das Schild hängt darunter.
                Text("Anzeige")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Palette.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.ink3, lineWidth: 0.5))
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .offset(y: ad ? -17 : 0)
    }

    /// Worauf sich die Karte einstellt: das Revier oder die ganze Strecke.
    private var fitCoordinates: [CLLocationCoordinate2D] {
        if !revier.isEmpty { return revier.map(\.coordinate) }
        return track.count > 1 ? track : []
    }

    static func rect(_ coords: [CLLocationCoordinate2D]) -> MKMapRect {
        let r = coords.map { MKMapPoint($0) }.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        return r.insetBy(dx: -r.width * 0.25 - 200, dy: -r.height * 0.25 - 200)
    }
}

/// Die Woche als Leine: ein Punkt je Tag, je größer, desto weiter gelaufen.
struct WeekLeash: View {
    let walks: [Walk]
    private var monday: Day { Day.today.adding(days: -Day.today.weekdayFromMonday) }

    var body: some View {
        let km = (0..<7).map { i in walks.filter { $0.day == monday.adding(days: i) }.reduce(0) { $0 + $1.meters } / 1000 }
        let total = km.reduce(0, +)
        let count = walks.filter { $0.day >= monday }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(total.formatted(.number.precision(.fractionLength(1)).locale(AppLocale.current)))
                    .font(.display(40, weight: .bold, width: 75))
                    .foregroundStyle(Palette.accent)
                    .contentTransition(.numericText())
                Text(count == 1 ? String(localized: "km diese Woche, eine Runde") : String(localized: "km diese Woche, \(count) Runden"))
                    .font(.display(17, weight: .medium, relativeTo: .headline))
                    .foregroundStyle(Palette.ink)
            }
            GeometryReader { g in
                let step = (g.size.width - 28) / 6
                ZStack(alignment: .topLeading) {
                    Path { p in p.move(to: CGPoint(x: 14, y: 20)); p.addLine(to: CGPoint(x: g.size.width - 14, y: 20)) }
                        .stroke(Palette.line, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    ForEach(0..<7, id: \.self) { i in
                        let x = 14 + CGFloat(i) * step
                        let r = km[i] > 0 ? 3 + CGFloat(min(km[i], 6)) * 2.4 : 3
                        Group {
                            if km[i] > 0 {
                                Circle().fill(Palette.accent.opacity(0.35 + min(km[i], 6) / 10))
                            } else {
                                Circle().strokeBorder(Palette.ink3, lineWidth: 1.2).background(Circle().fill(Palette.paper))
                            }
                        }
                        .frame(width: r * 2, height: r * 2)
                        .position(x: x, y: 20)
                        Text(Day.weekdayShort[i]).font(.caption2).foregroundStyle(Palette.ink3).position(x: x, y: 48)
                    }
                }
            }
            .frame(height: 56)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(zip(Day.weekdayNames, km).map { $1 > 0 ? "\($0) \(WalkText.distance($1 * 1000))" : String(localized: "\($0) keine Runde") }.joined(separator: ", "))
        }
    }
}

/// Die großen Zahlen unterwegs: Zeit, Strecke, Tempo, darunter die Kilometer als Leine.
struct LiveStats: View {
    @Environment(WalkRecorder.self) private var recorder
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: compact ? 14 : 24) {
                HStack(spacing: 8) {
                    Circle().fill(Palette.accent).frame(width: 8, height: 8)
                        .background(Circle().fill(Palette.soft).frame(width: 18, height: 18))
                        .opacity(recorder.phase == .paused ? 0.3 : 1)
                    Text(recorder.phase == .paused ? String(localized: "Pause") : String(localized: "Unterwegs"))
                        .font(.footnote.weight(.semibold)).foregroundStyle(Palette.accent)
                }
                stat(String(localized: "Zeit"), WalkText.clock(recorder.seconds(at: ctx.date)), size: compact ? 88 : 112)
                HStack(alignment: .top, spacing: 40) {
                    stat(String(localized: "Strecke"), WalkText.km(recorder.meters), unit: "km", size: compact ? 40 : 52)
                    stat(String(localized: "Tempo"), WalkText.pace(recorder.pace), unit: "/km", size: compact ? 40 : 52)
                }
                if !recorder.splits.isEmpty && !compact { splitsLeash }
            }
        }
    }

    private func stat(_ label: String, _ value: String, unit: String? = nil, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.display(size, weight: .bold, width: 75))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Palette.ink)
                if let unit { Text(unit).font(.display(size * 0.42, weight: .medium)).foregroundStyle(Palette.ink2) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Je Kilometer ein Punkt mit der Zeit für diesen Kilometer.
    private var splitsLeash: some View {
        let times = zip(recorder.splits, [0] + recorder.splits).map { $0 - $1 }
        return HStack(spacing: 0) {
            ForEach(Array(times.enumerated()), id: \.offset) { i, t in
                VStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 10, height: 10)
                    Text("km \(i + 1)").font(.caption2.weight(.semibold)).foregroundStyle(Palette.ink2)
                    Text(WalkText.clock(t)).font(.caption).monospacedDigit().foregroundStyle(Palette.ink)
                }
                .frame(width: 56)
                if i < times.count - 1 { Rectangle().fill(Palette.line).frame(height: 1.4).frame(maxWidth: 30).offset(y: -22) }
            }
        }
    }
}

/// Eine Zeile in „Letzte Runden“.
struct WalkRow: View {
    let walk: Walk
    let by: String?
    /// Wer gelaufen ist (im Rudel mit anderen, auch man selbst) – mit Bild.
    var walker: (name: String, image: UIImage?)? = nil

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: -2) {
                Text("\(walk.day.day)").font(.display(19, weight: .bold, relativeTo: .headline)).monospacedDigit()
                Text(Day.monthShort[walk.day.month - 1]).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Palette.ink)
            .frame(width: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(WalkText.distance(walk.meters)) in \(WalkText.duration(walk.seconds))")
                    .font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(by.map { String(localized: "\($0) war unterwegs") } ?? walk.startDate.formatted(date: .omitted, time: .shortened) + String(localized: " Uhr"))
                    .font(.subheadline).foregroundStyle(Palette.ink2)
            }
            Spacer()
            if let walker { AvatarView(image: walker.image, name: walker.name, size: 30) }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Wie weit das Blatt über der Karte aufgezogen ist.
enum StageDetent: String { case peek, middle, full }

/// Die Karte füllt den ganzen Bildschirm, alles andere liegt darüber.
///
/// Breit: ein schwebendes Panel an der rechten Seite, das ganz in der rechten Hälfte bleibt – auf dem Duo
/// läuft so nichts über den Knick. Schmal oder hochkant: ein Blatt von unten, das sich in drei Stufen ziehen
/// lässt; der Kopf bleibt immer sichtbar. Die Karte erfährt, was verdeckt ist, und richtet sich danach aus.
struct MapStage<MapContent: View, Top: View, Header: View, Content: View>: View {
    @Binding var detent: StageDetent
    /// Das Panel ist nur so groß wie sein Kopf und lässt sich nicht ziehen (unterwegs).
    var fitsContent = false
    @ViewBuilder var map: (EdgeInsets) -> MapContent
    @ViewBuilder var top: Top
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    @GestureState private var drag: CGFloat = 0
    @State private var headerHeight: CGFloat = 130

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > g.size.height && g.size.width >= 600
            if wide { wideLayout(g) } else { sheetLayout(g) }
        }
    }

    // MARK: Breit

    private func wideLayout(_ g: GeometryProxy) -> some View {
        let inset = g.safeAreaInsets
        let half = (g.size.width + inset.leading + inset.trailing) / 2
        let width = min(440, half - inset.trailing - 24)
        let covered = width + 24 + inset.trailing
        // Oben und unten gleich viel Rand, gemessen am ganzen Bildschirm: sonst säße das Panel zu hoch,
        // weil unten der Home-Balken oder die Leiste freibleibt.
        let margin = max(inset.top, inset.bottom) + 8
        return ZStack(alignment: .trailing) {
            map(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: covered)).ignoresSafeArea()
            top
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.trailing, width + 24)
                .padding(.top, 8)
            VStack(spacing: 0) {
                head.padding(.top, 16).padding(.bottom, fitsContent ? 16 : 8)
                if !fitsContent { content.frame(maxHeight: .infinity) }
            }
            .frame(width: width)
            .frame(maxHeight: fitsContent ? nil : .infinity)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
            .padding(.vertical, margin)
            .frame(maxHeight: .infinity)
            .padding(.trailing, 12)
            .ignoresSafeArea(.container, edges: .vertical)
        }
    }

    // MARK: Schmal und hochkant

    private func sheetLayout(_ g: GeometryProxy) -> some View {
        let middle = g.size.height * 0.5
        let full = g.size.height - 8
        let rest = fitsContent ? headerHeight : height(of: detent, middle: middle, full: full)
        let shown = fitsContent ? rest : min(full, max(headerHeight, rest - drag))
        // Ganz aufgezogen bleibt die Karte, wo sie war, damit sie nicht unter dem Blatt springt.
        let covered = min(rest, middle)
        return ZStack(alignment: .bottom) {
            map(EdgeInsets(top: 0, leading: 0, bottom: covered + g.safeAreaInsets.bottom, trailing: 0)).ignoresSafeArea()
            top
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !fitsContent {
                        Capsule().fill(Palette.ink3.opacity(0.5)).frame(width: 38, height: 5).padding(.top, 8).padding(.bottom, 10)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .gesture(sheetDrag(middle: middle, full: full))
                            .onTapGesture { step(middle: middle, full: full) }
                            .accessibilityElement()
                            .accessibilityLabel(String(localized: "Blatt größer oder kleiner"))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { step(middle: middle, full: full) }
                    }
                    head.padding(.top, fitsContent ? 16 : 0).padding(.bottom, fitsContent ? 12 : 8)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                if !fitsContent { content.frame(maxHeight: .infinity) }
            }
            .frame(height: fitsContent ? nil : shown, alignment: .top)
            .frame(maxWidth: .infinity)
            .clipped()
            .background(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                    .fill(Palette.paper)
                    .shadow(color: .black.opacity(0.14), radius: 18, y: -4)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private var head: some View { header.padding(.horizontal, 16) }

    private func height(of d: StageDetent, middle: CGFloat, full: CGFloat) -> CGFloat {
        switch d {
        case .peek: headerHeight
        case .middle: middle
        case .full: full
        }
    }

    private func sheetDrag(middle: CGFloat, full: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                let target = height(of: detent, middle: middle, full: full) - value.predictedEndTranslation.height
                let options: [StageDetent] = [.peek, .middle, .full]
                let next = options.min { abs(height(of: $0, middle: middle, full: full) - target) < abs(height(of: $1, middle: middle, full: full) - target) } ?? .middle
                withAnimation(.snappy) { detent = next }
            }
    }

    private func step(middle: CGFloat, full: CGFloat) {
        withAnimation(.snappy) {
            detent = switch detent { case .peek: .middle; case .middle: .full; case .full: .peek }
        }
    }
}
