import MapKit
import SwiftUI

/// Der Reiter „Adressen“ auf Gassi: Suche, Chips nach Art, oben der gesponserte Platz, darunter alles nach Entfernung.
/// Die Karte darüber zeigt dieselben Adressen (siehe `WalkMap`).
struct ServicesPanel: View {
    @Environment(WalkRecorder.self) private var recorder
    @Bindable var list: ServiceList
    @State private var explainsAd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let here = recorder.here {
                searchField.padding(.bottom, 12)
                if !list.kinds.isEmpty { chips.padding(.bottom, 10) }
                content(here)
                footer.padding(.top, 24)
            } else {
                Button("Standort freigeben", icon: "ort") { recorder.locateOnce() }
                    .buttonStyle(.bordered)
            }
        }
        // Beim ersten Öffnen laden, danach erst nach 250 m wieder (wie die Orte).
        .task(id: recorder.here.map { "\($0.latitude),\($0.longitude)" }) {
            if let here = recorder.here { await list.refresh(here) }
        }
        .task(id: list.query) {
            if let here = recorder.here { await list.search(near: here) }
        }
    }

    // MARK: Suche und Chips

    private var searchField: some View {
        HStack(spacing: 10) {
            LineIcon("lupe", size: 20).foregroundStyle(Palette.ink3)
            TextField("Name oder Art suchen", text: $list.query)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !list.query.isEmpty {
                Button("Leeren", icon: "kreuz-kreis") { list.query = "" }
                    .labelStyle(.iconOnly).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(String(localized: "Alle"), on: list.kind == nil) { list.kind = nil }
                ForEach(list.kinds) { k in
                    chip(k.title, on: list.kind == k) { list.kind = k }
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
        .sensoryFeedback(.selection, trigger: list.kind)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Palette.accent : Palette.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background {
                    if on { SelectionPill() } else { Capsule().fill(Palette.surface) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Liste

    @ViewBuilder
    private func content(_ here: CLLocationCoordinate2D) -> some View {
        let rows = list.list(from: here)
        let sponsor = list.showsSponsor ? list.sponsor : nil
        if let sponsor {
            Button { list.selected = sponsor.entry } label: { SponsorCard(sponsor: sponsor, here: here) }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
        }
        if rows.isEmpty, sponsor == nil {
            if list.loading {
                note(String(localized: "Adressen werden gesucht …"))
            } else if list.failed {
                VStack(alignment: .leading, spacing: 8) {
                    note(String(localized: "Adressen konnten nicht geladen werden."))
                    Button("Nochmal") { Task { await list.refresh(here, force: true) } }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Palette.accent)
                }
            } else if !list.query.trimmingCharacters(in: .whitespaces).isEmpty {
                note(String(localized: "Nichts gefunden."))
            } else {
                note(String(localized: "Hier sind noch keine Adressen verzeichnet."))
            }
        }
        LazyVStack(spacing: 0) {
            let visible = Array(rows.prefix(list.shown))
            ForEach(visible) { s in
                Button { list.selected = s } label: { ServiceRow(service: s, here: here).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                if s.id != visible.last?.id { Divider().overlay(Palette.line).padding(.leading, 46) }
            }
        }
        if rows.count > list.shown {
            Button("Mehr zeigen") { list.shown += ServiceList.page }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 10)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Palette.ink3).padding(.vertical, 12)
    }

    /// Woher die Daten kommen und warum oben eine Anzeige steht – ohne Hinweis darauf, wie man sie kauft.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daten: OpenStreetMap. Fehlt etwas? Auf [openstreetmap.org](https://www.openstreetmap.org) eintragen.")
            Button {
                withAnimation(.snappy) { explainsAd.toggle() }
            } label: {
                Text("Warum steht oben eine Anzeige?").foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            if explainsAd {
                Text("Betriebe können je Gegend einen Platz oben in den Adressen kaufen. Er ist immer als Anzeige gekennzeichnet. Die übrige Liste ist nach Entfernung sortiert und nicht käuflich, Bewertungen und Daten bleiben unberührt.")
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.ink3)
        .tint(Palette.accent)
    }
}

/// Eine Zeile wie bei „Wohin“: Icon im Kreis, Name, darunter Art und Straße, rechts die Entfernung.
struct ServiceRow: View {
    let service: Service
    let here: CLLocationCoordinate2D?
    var isAd = false

    var body: some View {
        HStack(alignment: isAd ? .top : .center, spacing: 12) {
            LineIcon(service.icon, size: 20)
                .foregroundStyle(Palette.accent)
                .frame(width: 34, height: 34)
                .background(Palette.soft, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).font(.body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text(service.line).font(.subheadline).foregroundStyle(Palette.ink2).lineLimit(1)
                    if service.emergency { EmergencyTag() }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if isAd { AdTag() }
                if let here {
                    Text(WalkText.distance(Track.distance(here, service.coordinate)))
                        .font(.display(17, weight: .semibold, relativeTo: .body)).foregroundStyle(Palette.ink)
                }
            }
        }
        .padding(.vertical, isAd ? 0 : 10)
        .accessibilityElement(children: .combine)
    }
}

/// Der gesponserte Platz: eigene Karte über der Liste, deutlich als Anzeige gekennzeichnet.
struct SponsorCard: View {
    let sponsor: ServiceSponsor
    let here: CLLocationCoordinate2D?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ServiceRow(service: sponsor.entry, here: here, isAd: true)
            if let text = sponsor.text, !text.isEmpty {
                Text(text).font(.subheadline).foregroundStyle(Palette.ink).lineLimit(2)
                    .padding(.leading, 46)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// „Anzeige“ – gut lesbar, nicht als Kleinstdruck.
struct AdTag: View {
    var body: some View {
        Text("Anzeige")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Palette.ink3, lineWidth: 1))
            .fixedSize()
    }
}

/// Tierarzt mit Notdienst.
struct EmergencyTag: View {
    var body: some View {
        Text("Notdienst")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.kind(.health))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Palette.kind(.health).opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// Eine Adresse im Panel unter der Karte, mit Zurück zu „Adressen“.
struct ServiceScreen: View {
    @Environment(\.openURL) private var openURL
    @Environment(WalkRecorder.self) private var recorder
    let service: Service
    /// Gesetzt, wenn das der gesponserte Platz ist.
    var sponsor: ServiceSponsor? = nil
    let onClose: () -> Void

    /// Antippen des Sponsors zählt höchstens einmal je Öffnen.
    @State private var tapped = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Breadcrumb(parent: String(localized: "Adressen"), current: service.label, back: onClose).padding(.bottom, 6)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.name)
                            .font(.display(28)).foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        // Die Art kommt vom Server, die Entfernung ist eine Zahl: nichts zu übersetzen.
                        Text(([service.label] + [recorder.here.map { WalkText.distance(Track.distance($0, service.coordinate)) }].compactMap { $0 }).joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Palette.ink2)
                    }
                    Spacer(minLength: 0)
                    if sponsor != nil { AdTag().padding(.top, 6) }
                }

                if let sponsor {
                    VStack(alignment: .leading, spacing: 6) {
                        if let text = sponsor.text, !text.isEmpty {
                            Text(text).font(.body).foregroundStyle(Palette.ink)
                        }
                        Text(sponsor.advertiser.map { String(localized: "Bezahlte Platzierung von \($0).") } ?? String(localized: "Bezahlte Platzierung."))
                            .font(.footnote).foregroundStyle(Palette.ink2)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 14)
                }

                if service.emergency {
                    Label("Notdienst", icon: "notfall")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.kind(.health))
                        .padding(.top, 14)
                }

                buttons.padding(.top, 18)

                let address = [service.street, service.city].compactMap { $0 }.filter { !$0.isEmpty }
                if !address.isEmpty {
                    section(String(localized: "Adresse"), address.joined(separator: "\n"))
                }
                if let hours = service.hoursText {
                    section(String(localized: "Öffnungszeiten"), hours)
                }

                Text("Aus OpenStreetMap")
                    .font(.footnote).foregroundStyle(Palette.ink3)
                    .padding(.top, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Palette.paper)
        .onAppear { countTap() }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
            Text(body).font(.body).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.top, 20)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if let tel = service.phoneURL {
                Button { countTap(); openURL(tel) } label: { buttonLabel(String(localized: "Anrufen")) }
            }
            if let web = service.websiteURL {
                Button { countTap(); openURL(web) } label: { buttonLabel(String(localized: "Website")) }
            }
            Button(action: route) { buttonLabel(String(localized: "Route")) }
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).tint(Palette.ink)
    }

    private func buttonLabel(_ title: String) -> some View {
        Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 30)
    }

    /// Mit Apple Karten hinführen.
    private func route() {
        let item = MKMapItem(location: CLLocation(latitude: service.lat, longitude: service.lon), address: nil)
        item.name = service.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }

    private func countTap() {
        guard let sponsor, !tapped else { return }
        tapped = true
        ServiceFinder.tap(sponsor.id)
    }
}
