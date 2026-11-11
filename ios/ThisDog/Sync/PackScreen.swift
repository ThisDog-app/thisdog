import SwiftUI

/// Das Rudel: einladen (per Link oder QR-Code), beitreten, Mitglieder sehen, den eigenen Namen setzen, verlassen.
/// Ein Konto entsteht dabei von selbst; eine E-Mail-Adresse braucht nur, wer das Telefon wechseln will.
struct PackScreen: View {
    @Environment(Account.self) private var account
    @Environment(DogStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var myName = ""
    @State private var invite: URL?
    @State private var working = false
    @State private var message: String?
    @State private var confirmsLeave = false
    @State private var confirmsRevoke = false
    @State private var recovery: String?
    @State private var recoveryInput = ""
    @State private var scans = false
    @State private var choosesRole = false
    @State private var inviteRole = "sitter"
    @State private var inviteExpires: Date?
    @State private var shownMember: Member?
    @State private var showsEmail = false
    @FocusState private var nameFocus: Bool
    /// Gemerkt je Rudel: Wurde der Wiederherstellungsschlüssel schon kopiert oder gedruckt?
    @AppStorage("recoverySaved") private var recoverySaved = ""

    var body: some View {
        TwoPane(parent: store.profile.name.isEmpty ? String(localized: "ThisDog") : store.profile.name, title: String(localized: "Rudel"), close: { dismiss() }) {
            Text("Rudel").font(.display(44)).foregroundStyle(Palette.ink)
            switch account.state {
            case .unknown:
                ProgressView()
            case .signedOut, .linkSent:
                Text("Im Rudel habt ihr dieselben Termine und Gesundheitsdaten. Was einer einträgt, haben alle.")
                    .font(.body).foregroundStyle(Palette.ink2)
            case .signedIn:
                memberList
            }
        } right: {
            // Fehlt der Schlüssel, geht ohne ihn nichts: Das steht deshalb ganz oben.
            if account.keyMissing { keyMissingNote }
            switch account.state {
            case .signedOut, .linkSent:
                startActions
            case .signedIn:
                packActions
            case .unknown:
                EmptyView()
            }
            if let message = message ?? account.joinMessage {
                Text(message).font(.subheadline).foregroundStyle(Palette.kind(.health))
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: account.state)
        .sheet(item: $shownMember) { m in
            MemberSheet(memberID: m.id)
        }
        .sheet(isPresented: $scans) {
            InviteScannerSheet { url in account.open(url) }
        }
        // Die Einladung von vorhin ist wieder da, solange sie gilt – zum Weiterschicken an den nächsten Sitter.
        .task(id: account.currentPack?.id) {
            guard invite == nil, account.isOwner, let last = await account.lastInvite() else { return }
            invite = last.url
            inviteRole = last.role
            inviteExpires = last.expires
        }
        .onDisappear { saveName() }
        .sheet(isPresented: Binding(get: { recovery != nil }, set: { if !$0 { recovery = nil } })) {
            if let recovery {
                RecoverySheet(code: recovery) { markRecoverySaved() }
            }
        }
        .onAppear {
            #if DEBUG
            // Zum Ansehen: `-schluessel` zeigt den Wiederherstellungsschlüssel mit einem Beispiel.
            if ProcessInfo.processInfo.arguments.contains("-schluessel") { recovery = RecoveryCode.encode(.init(size: .bits256)) }
            #endif
        }
    }

    private var recoveryIsSaved: Bool {
        guard let id = account.currentPack?.id else { return false }
        return recoverySaved.split(separator: ",").contains(Substring(String(id)))
    }

    private func markRecoverySaved() {
        guard let id = account.currentPack?.id, !recoveryIsSaved else { return }
        recoverySaved = recoverySaved.isEmpty ? String(id) : recoverySaved + ",\(id)"
    }

    /// Für den Fall, dass alle Telefone weg sind.
    @ViewBuilder
    private var recoverySection: some View {
        if let code = account.recoveryCode ?? demoRecovery {
            VStack(alignment: .leading, spacing: 8) {
                Text("Falls alle Telefone weg sind").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
                Text(recoveryIsSaved
                     ? String(localized: "Du hast den Wiederherstellungsschlüssel schon gesichert.")
                     : String(localized: "Sichere den Wiederherstellungsschlüssel. Ohne ihn sind die Daten deines Hundes dann verloren, auch wir kommen nicht heran."))
                    .font(.subheadline)
                    .foregroundStyle(recoveryIsSaved ? Palette.ink2 : Palette.ink)
                Button(recoveryIsSaved ? String(localized: "Noch einmal ansehen") : String(localized: "Schlüssel sichern")) { recovery = code }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var demoRecovery: String? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-rudeldemo"), !account.keyMissing { return RecoveryCode.encode(.init(size: .bits256)) }
        #endif
        return nil
    }

    /// Das Rudel ist verschlüsselt, der Schlüssel aber noch nicht auf diesem Gerät.
    private var keyMissingNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Schlüssel fehlt", icon: "schluessel").font(.headline).foregroundStyle(Palette.ink)
            Text("Die Daten des Rudels sind verschlüsselt, und der Schlüssel liegt nur auf euren Geräten. Tippe auf einem Gerät, das schon dabei ist, auf „Rudelmitglied einladen“ und öffne den Link hier, oder gib euren Wiederherstellungsschlüssel ein. Mit demselben Apple-Account kommt er auch von selbst über den iCloud-Schlüsselbund.")
                .font(.subheadline).foregroundStyle(Palette.ink2)
            TextField("Wiederherstellungsschlüssel", text: $recoveryInput, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(12)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button("Daten wiederherstellen") {
                run {
                    try await account.restore(code: recoveryInput)
                    recoveryInput = ""
                    markRecoverySaved()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || recoveryInput.isEmpty)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Mitglieder

    /// Wer dazugehört und wann zuletzt abgeglichen wurde.
    @ViewBuilder
    private var memberList: some View {
        if let pack = account.currentPack {
            VStack(spacing: 0) {
                ForEach(pack.members) { m in
                    // Antippen: Rolle und Mitteilungen. Das eigene Mitglied immer, andere nur als Besitzer.
                    let opens = m.id == account.me || account.isOwner
                    Button { if opens { shownMember = m } } label: {
                    HStack(spacing: 14) {
                        if m.id == account.me {
                            AvatarPicker(id: Avatar.member(m.id), name: m.name, size: 46, label: String(localized: "Dein Bild im Rudel"))
                        } else {
                            AvatarView(image: store.avatarImage(Avatar.member(m.id)), name: m.name, size: 46)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                            Text(m.id == account.me ? String(localized: "Du · \(m.roleLabel)") : String(localized: "\(m.roleLabel) · seit \(Self.since(m.joinedAt))"))
                                .font(.subheadline).foregroundStyle(Palette.ink2)
                        }
                        Spacer()
                        if opens {
                            if m.notifies.isEmpty { Image(systemName: "bell.slash").font(.footnote).foregroundStyle(Palette.ink3).accessibilityLabel("keine Mitteilungen") }
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink3)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!opens)
                    .accessibilityIdentifier("mitglied-\(m.name)")
                    if m.id != pack.members.last?.id { Divider().overlay(Palette.line).padding(.leading, 60) }
                }
            }
            .transition(.opacity)
        }
        Text(syncLine).font(.footnote).foregroundStyle(Palette.ink3)
    }

    /// Noch kein Konto: einladen oder einer Einladung folgen. Beides legt das Konto selbst an.
    private var startActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            inviteButton
            Button { scans = true } label: {
                Label("Einladung scannen", icon: "kamera").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Text("Hast du einen Einladungslink bekommen? Öffne ihn einfach auf diesem Telefon.")
                .font(.subheadline).foregroundStyle(Palette.ink2)
            if showsEmail || account.codeFor != nil {
                SignInForm(intro: String(localized: "Mit deiner E-Mail-Adresse kommst du an dein bisheriges Konto. Du bekommst einen Code, ein Passwort brauchst du nicht."))
            } else {
                Button("Ich habe schon ein Konto mit E-Mail") { withAnimation(.snappy) { showsEmail = true } }
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var inviteButton: some View {
        Button {
            choosesRole = true
        } label: {
            Label("Rudelmitglied einladen", icon: "person-plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(working)
        .confirmationDialog("Wer kommt dazu?", isPresented: $choosesRole, titleVisibility: .visible) {
            Button("Hundesitter") { makeInvite("sitter") }
            Button("Besitzer") { makeInvite("owner") }
        } message: {
            Text("Hundesitter sehen alles und tragen ein, bekommen aber nur Mitteilungen, die sie selbst einschalten. Besitzer bekommen alle Mitteilungen, laden ein und vergeben Rollen.")
        }
    }

    private func makeInvite(_ role: String) {
        inviteRole = role
        run {
            let i = try await account.invite(role: role)
            invite = i.url
            inviteExpires = Date(timeIntervalSince1970: i.expiresAt / 1000)
        }
    }

    /// Wer neu dazukommt, heißt beim Server erst „Rudelmitglied“.
    private var needsName: Bool {
        guard let pack = account.currentPack else { return false }
        let mine = pack.members.first { $0.id == account.me }?.name ?? ""
        return account.justJoined || mine.isEmpty || mine == "Rudelmitglied"
    }

    private func saveName() {
        let name = myName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let pack = account.currentPack,
              name != pack.members.first(where: { $0.id == account.me })?.name else { return }
        Task { await account.setName(name) }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if needsName {
                Text("Wie heißt du?").font(.display(22, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Damit die anderen sehen, wer mit \(dogName) unterwegs war.")
                    .font(.subheadline).foregroundStyle(Palette.ink2)
            } else {
                Text("Dein Name im Rudel").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
            }
            TextField("z. B. Anna", text: $myName)
                .textContentType(.givenName)
                .submitLabel(.done)
                .focused($nameFocus)
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onSubmit { saveName(); account.justJoined = false }
        }
    }

    private var dogName: String { store.profile.name.isEmpty ? String(localized: "dem Hund") : store.profile.name }

    /// Einladen (Link und QR-Code), den eigenen Namen ändern, verlassen.
    private var packActions: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let pack = account.currentPack {
                // Frisch dazugekommen: zuerst der Name, alles andere hat Zeit.
                if needsName { nameField }

                if let invite {
                    VStack(spacing: 14) {
                        Text(inviteRole == "sitter" ? String(localized: "Einladung als Hundesitter") : String(localized: "Einladung als Besitzer"))
                            .font(.headline).foregroundStyle(Palette.ink)
                        QRCodeView(text: invite.absoluteString)
                            .frame(maxWidth: 260)
                        Text(inviteExpires.map { String(localized: "Scannt den Code mit der Kamera, oder teilt den Link. Er gilt bis \($0.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())), für alle, die ihr einladet.") }
                             ?? String(localized: "Scannt den Code mit der Kamera, oder teilt den Link. Er gilt sieben Tage, für alle, die ihr einladet."))
                            .font(.subheadline).foregroundStyle(Palette.ink2)
                            .multilineTextAlignment(.center)
                        ShareLink(item: invite, subject: Text("Komm in mein Rudel bei ThisDog"),
                                  message: Text("Mit diesem Link kommst du in unser Rudel. Er gilt sieben Tage.")) {
                            Label("Link teilen", icon: "teilen")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button("Andere Einladung") { self.invite = nil; account.forgetInvite() }
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                } else if account.isOwner {
                    inviteButton
                } else {
                    Text("Neue Mitglieder laden die Besitzer ein.")
                        .font(.subheadline).foregroundStyle(Palette.ink2)
                }

                // Ein Link ging an die falsche Person oder ist nicht mehr nötig: alle auf einmal ungültig machen.
                if account.isOwner, (pack.openInvites ?? 0) > 0 {
                    Button("Einladungslinks ungültig machen", role: .destructive) { confirmsRevoke = true }
                        .font(.subheadline)
                        .disabled(working)
                        .accessibilityIdentifier("einladungen-ungueltig")
                }

                if !needsName { nameField }

                Button("Einladung in ein anderes Rudel scannen") { scans = true }
                    .font(.subheadline.weight(.medium))
            }

            recoverySection

            if (account.currentPack?.members.count ?? 0) > 1 {
                Button("Rudel verlassen", role: .destructive) { confirmsLeave = true }
                    .font(.subheadline)
            }
        }
        .onAppear {
            myName = account.currentPack?.members.first { $0.id == account.me }?.name ?? ""
            if myName == "Rudelmitglied" { myName = "" }
        }
        .onChange(of: account.currentPack?.members.first { $0.id == account.me }?.name) { _, name in
            if myName.isEmpty, let name, name != "Rudelmitglied" { myName = name }
        }
        .confirmationDialog("Einladungslinks ungültig machen?", isPresented: $confirmsRevoke, titleVisibility: .visible) {
            Button("Ungültig machen", role: .destructive) {
                run {
                    try await account.revokeInvites()
                    invite = nil
                    inviteExpires = nil
                }
            }
        } message: {
            Text(account.currentPack?.openInvites == 1
                 ? String(localized: "Mit dem offenen Einladungslink kommt dann niemand mehr ins Rudel. Wer schon dabei ist, bleibt.")
                 : String(localized: "Mit den \(account.currentPack?.openInvites ?? 0) offenen Einladungslinks kommt dann niemand mehr ins Rudel. Wer schon dabei ist, bleibt."))
        }
        .confirmationDialog("Rudel verlassen?", isPresented: $confirmsLeave, titleVisibility: .visible) {
            Button("Verlassen", role: .destructive) { run { try await account.leave() } }
        } message: {
            Text("Die gemeinsamen Termine verschwinden von diesem Gerät. Die anderen behalten sie.")
        }
    }

    private var syncLine: String {
        if account.syncing { return String(localized: "Wird abgeglichen …") }
        if let e = account.lastError { return e }
        guard let d = account.lastSync else { return String(localized: "Noch nicht abgeglichen") }
        return String(localized: "Abgeglichen um \(d.formatted(date: .omitted, time: .shortened)) Uhr")
    }

    static func since(_ seconds: Int) -> String {
        Day(date: Date(timeIntervalSince1970: TimeInterval(seconds))).shortText
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        message = nil
        Task {
            do { try await work() } catch { message = Self.text(for: error) }
            working = false
        }
    }

    static func text(for error: Error) -> String {
        switch error as? RecoveryCode.Failure {
        case .invalid: return String(localized: "Dieser Schlüssel stimmt nicht. Prüf jedes Zeichen noch einmal.")
        case .wrongPack: return String(localized: "Dieser Schlüssel gehört zu einem anderen Rudel.")
        case nil: break
        }
        return switch error as? Api.Failure {
        case .offline: String(localized: "Keine Verbindung. Versuch es gleich noch einmal.")
        case .server("bad_code"): String(localized: "Der Code stimmt nicht.")
        case .server("too_many_tries"): String(localized: "Zu viele Versuche. Fordere einen neuen Link an.")
        case .server("expired"): String(localized: "Der Link ist abgelaufen. Fordere einen neuen an.")
        case .server("rate_limited"): String(localized: "Zu viele Anfragen. Warte ein paar Minuten.")
        case .server("invalid_email"): String(localized: "Diese Adresse stimmt nicht.")
        case .server("invite_used"): String(localized: "Diese Einladung wurde schon benutzt. Bitte um eine neue.")
        case .server("invite_expired"): String(localized: "Diese Einladung ist abgelaufen. Bitte um eine neue.")
        case .server("invite_unknown"): String(localized: "Diese Einladung gibt es nicht.")
        case .server("pack_full"): String(localized: "Das Rudel ist voll.")
        case .server("key_missing"): String(localized: "Auf diesem Gerät fehlt der Schlüssel des Rudels.")
        case .server("use_code"): String(localized: "Gib den Code aus der Mail hier in der App ein.")
        default: String(localized: "Das hat nicht geklappt. Versuch es gleich noch einmal.")
        }
    }
}
