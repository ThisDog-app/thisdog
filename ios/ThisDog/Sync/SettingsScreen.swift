import SwiftUI

/// Einstellungen: Konto, Support, Datenschutz und Impressum.
struct SettingsScreen: View {
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Einstellungen")
                        .font(.display(44))
                        .foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Konto").font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink)
                        switch account.state {
                        case .unknown: ProgressView()
                        case .signedOut, .linkSent: SignInForm(intro: String(localized: "Ein Konto entsteht von selbst, sobald du jemanden ins Rudel einlädst. Hast du schon eins mit E-Mail-Adresse, melde dich hier an."))
                        case .signedIn(let mail): signedIn(mail)
                        }
                        if let message {
                            Text(message).font(.subheadline).foregroundStyle(Palette.kind(.health))
                        }
                    }
                    HelpSection()
                    LegalLinks()
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.paper)
            .glassBar { BarTextItem(title: String(localized: "Fertig")) { dismiss() } }
            .animation(.snappy, value: account.state)
        }
        .tint(Palette.accent)
    }

    private func signedIn(_ mail: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                if let mail, !mail.isEmpty {
                    Text("Angemeldet als").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
                    Text(mail).font(.body).foregroundStyle(Palette.ink).textSelection(.enabled)
                } else {
                    Text("Angemeldet auf diesem Telefon").font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("Ohne E-Mail-Adresse. Alles funktioniert, nur ein neues Telefon findet dieses Konto nicht von selbst.")
                        .font(.subheadline).foregroundStyle(Palette.ink2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if mail?.isEmpty ?? true {
                Text("E-Mail hinzufügen (freiwillig)").font(.display(18, weight: .semibold)).foregroundStyle(Palette.ink)
                SignInForm(intro: String(localized: "Damit kommst du auch von einem neuen Telefon wieder an dein Konto."), action: String(localized: "Code schicken"))
            }
            HStack(spacing: 20) {
                // Ohne Adresse käme man nach dem Abmelden nie wieder an dieses Konto.
                if let mail, !mail.isEmpty {
                    Button("Abmelden") { Task { await account.signOut() } }
                        .foregroundStyle(Palette.ink2)
                }
                Button("Konto löschen", role: .destructive) { confirmsDelete = true }
            }
            .font(.subheadline)
        }
        .confirmationDialog("Konto löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Konto löschen", role: .destructive) {
                message = nil
                Task {
                    do { try await account.deleteAccount() } catch { message = PackScreen.text(for: error) }
                }
            }
        } message: {
            Text("Deine E-Mail-Adresse und deine Anmeldungen verschwinden vom Server, ebenso Rudel, in denen sonst niemand ist, mit allen Daten, Notfallpass und Freundschaften. Die anderen in einem gemeinsamen Rudel behalten die gemeinsamen Daten. Auf diesem Gerät bleibt alles.")
        }
    }
}

/// E-Mail-Adresse eingeben, dann den Code aus der Mail. Im Rudel und in den Einstellungen.
struct SignInForm: View {
    @Environment(Account.self) private var account
    let intro: String
    var action = String(localized: "Anmeldecode schicken")
    @State private var email = ""
    @State private var code = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let mail = account.codeFor { codeEntry(mail) } else { signIn }
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Palette.kind(.health))
            }
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(intro)
                .font(.body).foregroundStyle(Palette.ink2)
            TextField("E-Mail-Adresse", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                run { try await account.requestLink(email: email.trimmingCharacters(in: .whitespaces)) }
            } label: {
                Text(action).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(working || !email.contains("@"))
        }
    }

    private func codeEntry(_ mail: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Die Mail an \(mail) ist unterwegs. Gib den Code daraus ein, oder öffne den Link darin auf diesem Gerät.")
                .font(.body).foregroundStyle(Palette.ink2)
            TextField("Code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.display(34, weight: .semibold, width: 80))
                .multilineTextAlignment(.center)
                .padding(10)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: code) { _, c in
                    code = String(c.filter(\.isNumber).prefix(6))
                    if code.count == 6 { run { try await account.enterCode(code) } }
                }
            Button("Andere Adresse") { account.startOver() }
                .font(.subheadline)
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        message = nil
        Task {
            do { try await work() } catch { message = PackScreen.text(for: error) }
            working = false
        }
    }
}
