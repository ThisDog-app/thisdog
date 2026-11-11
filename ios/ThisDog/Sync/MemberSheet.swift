import SwiftUI

/// Ein Mitglied des Rudels: Rolle und Mitteilungen.
///
/// Besitzer legen für jeden fest, welche Mitteilungen er bekommen *darf*, und vergeben Rollen. Jeder schaltet für
/// sich ein, welche er *will*. Hundesitter haben anfangs nichts eingeschaltet – sie bekommen nur, was sie selbst wollen.
struct MemberSheet: View {
    let memberID: Int
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var message: String?
    @State private var confirmsRemove = false

    private var member: Member? { account.currentPack?.members.first { $0.id == memberID } }
    private var isMe: Bool { memberID == account.me }

    var body: some View {
        NavigationStack {
            Form {
                if let m = member {
                    if account.isOwner {
                        Section {
                            Picker("Rolle", selection: Binding(get: { m.isOwner ? "owner" : "sitter" }, set: { role in
                                run { try await account.setRole(role, of: m.id) }
                            })) {
                                Text("Besitzer").tag("owner")
                                Text("Hundesitter").tag("sitter")
                            }
                            .pickerStyle(.segmented)
                        } header: { Text("Rolle") } footer: {
                            Text(m.isOwner
                                 ? String(localized: "Besitzer laden ein, vergeben Rollen und legen fest, wer welche Mitteilungen bekommen darf.")
                                 : String(localized: "Hundesitter sehen alles und tragen ein, bekommen aber nur Mitteilungen, die sie selbst einschalten."))
                        }
                    }
                    if isMe { mine(m) } else if account.isOwner { allowed(m); removeSection(m) }
                    if let message {
                        Section { Text(message).foregroundStyle(Palette.kind(.health)) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .disabled(working)
            .glassBar(member.map { isMe ? String(localized: "Du im Rudel") : $0.name } ?? "") {
                BarTextItem(title: String(localized: "Fertig")) { dismiss() }
            }
        }
        .tint(Palette.accent)
        .presentationDetents([.medium, .large])
    }

    /// Die eigenen Mitteilungen. Was die Besitzer nicht freigegeben haben, bleibt aus.
    private func mine(_ m: Member) -> some View {
        Section {
            ForEach(NotifyKind.allCases) { kind in
                let allowed = (m.notifyAllowed ?? []).contains(kind.rawValue)
                // Besitzer dürfen sich selbst alles erlauben; Hundesitter nur, was freigegeben ist.
                let usable = allowed || m.isOwner
                Toggle(isOn: Binding(get: { allowed && (m.notifyWanted ?? []).contains(kind.rawValue) }, set: { on in
                    var wanted = Set(m.notifyWanted ?? [])
                    if on { wanted.insert(kind.rawValue) } else { wanted.remove(kind.rawValue) }
                    let list = NotifyKind.allCases.map(\.rawValue).filter(wanted.contains)
                    var allow: [String]? = nil
                    if on, !allowed, m.isOwner { allow = NotifyKind.allCases.map(\.rawValue).filter { (m.notifyAllowed ?? []).contains($0) || $0 == kind.rawValue } }
                    run {
                        try await account.setNotify(of: m.id, allowed: allow, wanted: list)
                        if on { await PushRegistration.askPermission() }
                    }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(usable ? kind.detail : String(localized: "Von den Besitzern nicht freigegeben."))
                            .font(.footnote).foregroundStyle(Palette.ink2)
                    }
                }
                .disabled(!usable)
            }
        } header: { Text("Meine Mitteilungen") } footer: {
            Text("Gilt für dieses Rudel. Ob Mitteilungen überhaupt erscheinen, legst du außerdem in den Einstellungen deines Telefons fest.")
        }
    }

    /// Als Besitzer: was dieses Mitglied bekommen darf. Ob es das auch will, entscheidet es selbst.
    private func allowed(_ m: Member) -> some View {
        Section {
            ForEach(NotifyKind.allCases) { kind in
                Toggle(isOn: Binding(get: { (m.notifyAllowed ?? []).contains(kind.rawValue) }, set: { on in
                    var set = Set(m.notifyAllowed ?? [])
                    if on { set.insert(kind.rawValue) } else { set.remove(kind.rawValue) }
                    run { try await account.setNotify(of: m.id, allowed: NotifyKind.allCases.map(\.rawValue).filter(set.contains)) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(kind.detail).font(.footnote).foregroundStyle(Palette.ink2)
                    }
                }
            }
        } header: { Text("Darf Mitteilungen bekommen bei") } footer: {
            let on = m.notifies.map(\.title)
            Text(on.isEmpty
                 ? String(localized: "\(m.name) bekommt gerade keine Mitteilungen. Einschalten kann \(m.name) sie selbst.")
                 : String(localized: "\(m.name) bekommt gerade: \(on.joined(separator: ", ")). Was davon, entscheidet \(m.name) selbst."))
        }
    }

    /// Als Besitzer: jemanden aus dem Rudel nehmen – mit Rückfrage.
    private func removeSection(_ m: Member) -> some View {
        Section {
            Button(String(localized: "Aus dem Rudel entfernen"), role: .destructive) { confirmsRemove = true }
                .accessibilityIdentifier("mitglied-entfernen")
        }
        .confirmationDialog(String(localized: "\(m.name) aus dem Rudel entfernen?"), isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button(String(localized: "Entfernen"), role: .destructive) {
                run {
                    try await account.remove(member: m.id)
                    dismiss()
                }
            }
        } message: {
            Text("\(m.name) kommt sofort nicht mehr an die Daten des Rudels. Was schon auf dem Telefon von \(m.name) ist, bleibt dort.")
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        message = nil
        Task {
            do { try await work() } catch {
                message = switch error as? Api.Failure {
                case .server("last_owner"): String(localized: "Ein Rudel braucht mindestens einen Besitzer.")
                case .server("not_owner"): String(localized: "Das dürfen nur Besitzer.")
                case .server("use_leave"): String(localized: "Dich selbst nimmst du mit „Rudel verlassen“ heraus.")
                case .server("not_a_member"): String(localized: "Diese Person ist nicht mehr im Rudel.")
                default: PackScreen.text(for: error)
                }
            }
            working = false
        }
    }
}
