import CoreImage.CIFilterBuiltins
import SwiftUI

/// Die Ansicht zu „Hund in der Nähe“: Beide tippen darauf, sehen sich und werden mit einem Tipp Freunde.
/// Klappt das nicht, zeigt einer einen QR-Code, und der andere hält die Kamera drauf.
struct NearbySheet: View {
    @Environment(Account.self) private var account
    @Environment(DogStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var share = NearbyShare()
    @State private var qr: UIImage?
    @State private var loadingQR = false
    @State private var qrFailed = false

    private var dogName: String { store.profile.name.isEmpty ? String(localized: "Dein Hund") : store.profile.name }
    private var signedIn: Bool { if case .signedIn = account.state { true } else { false } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Wer spielt da mit \(dogName)?")
                        .font(.display(30, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    if signedIn || isDemo {
                        status
                        qrSection
                    } else {
                        Text("Damit \(dogName) Freunde finden kann, brauchst du ein Konto. Das dauert eine Minute.")
                            .font(.body).foregroundStyle(Palette.ink2)
                        Button {
                            dismiss()
                            account.presentsPack = true
                        } label: {
                            Text("Konto anlegen").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(24)
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.paper)
            .tint(Palette.accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .onAppear {
            guard signedIn || isDemo else { return }
            share.makeLink = { [friends = account.friends] in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-hundnah") { return URL(string: "https://thisdog.app/freund/probe#k=probe")! }
                #endif
                return try await friends.invite()
            }
            share.acceptLink = { [account] url in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-hundnah") { print("Hund in der Nähe: Link angekommen", url); return }
                #endif
                account.open(url)
            }
            share.start(dogName: dogName, photo: store.avatarImage(Avatar.dog))
        }
        .onDisappear { share.stop() }
        #if DEBUG
        .onChange(of: share.peers) { _, peers in
            // Für den Test mit zwei Simulatoren: `-hundnah frage` fragt den ersten, den es findet.
            if ProcessInfo.processInfo.arguments.contains("frage"), let p = peers.first, share.phase == .searching { share.ask(p) }
        }
        .onChange(of: share.request?.id) { _, id in
            if ProcessInfo.processInfo.arguments.contains("annehmen"), id != nil { share.answer(true) }
        }
        #endif
        .alert("\(share.request?.name ?? "Ein Hund") möchte \(dogName) kennenlernen",
               isPresented: Binding(get: { share.request != nil }, set: { _ in })) {
            Button("Freunde werden") { share.answer(true) }
            Button("Nein danke", role: .cancel) { share.answer(false) }
        } message: {
            Text("Ihr seht euch dann auf der Karte, solange ihr beide Gassi geht.")
        }
    }

    private var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-hundnah")
        #else
        false
        #endif
    }

    @ViewBuilder
    private var status: some View {
        switch share.phase {
        case .searching:
            Text("Tippt jetzt beide auf „Hund in der Nähe“. Andere sehen nur den Namen \(dogName), solange diese Ansicht offen ist.")
                .font(.body).foregroundStyle(Palette.ink2)
            if share.peers.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Wir schauen, wer in der Nähe ist …").font(.subheadline).foregroundStyle(Palette.ink2)
                }
                .padding(.vertical, 8)
            }
            ForEach(share.peers) { peer in
                Button {
                    share.ask(peer)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(image: nil, name: peer.name, size: 44, isDog: true)
                        Text(peer.name).font(.display(19, weight: .medium, relativeTo: .body)).foregroundStyle(Palette.ink)
                        Spacer()
                        Text("Hallo sagen").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                    }
                    .padding(12)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        case .connecting(let name):
            HStack(spacing: 12) {
                ProgressView()
                Text("Wir fragen bei \(name) nach …").font(.body).foregroundStyle(Palette.ink2)
            }
        case .friends(let name):
            Text("\(dogName) und \(name) sind jetzt Freunde.")
                .font(.display(22, weight: .medium)).foregroundStyle(Palette.ink)
            Text("Ihr seht euch auf der Karte, solange ihr beide Gassi geht.")
                .font(.body).foregroundStyle(Palette.ink2)
        case .failed(let text):
            Text(text).font(.body).foregroundStyle(Palette.kind(.health))
        }
    }

    @ViewBuilder
    private var qrSection: some View {
        if case .friends = share.phase {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let qr {
                    Text("Der andere Mensch hält einfach die Handykamera drauf. Der Code gilt für einen Hund.")
                        .font(.subheadline).foregroundStyle(Palette.ink2)
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("QR-Code zum Freundewerden")
                } else {
                    Text("Keiner taucht auf, oder dein Gegenüber hat ein Android-Telefon?")
                        .font(.subheadline).foregroundStyle(Palette.ink2)
                    Button(loadingQR ? String(localized: "Einen Moment …") : String(localized: "QR-Code zeigen")) { makeQR() }
                        .buttonStyle(.bordered)
                        .disabled(loadingQR)
                    if qrFailed {
                        Text("Dafür braucht es gerade eine Internetverbindung.")
                            .font(.subheadline).foregroundStyle(Palette.kind(.health))
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private func makeQR() {
        loadingQR = true
        qrFailed = false
        Task {
            defer { loadingQR = false }
            if let url = try? await share.makeLink?() {
                qr = Self.qrImage(url.absoluteString)
            } else {
                qrFailed = true
            }
        }
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let big = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(big, from: big.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
