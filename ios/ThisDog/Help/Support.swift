import SwiftUI
import UIKit

/// Der Gerätecode (wie in api/lib-support.php): 9 Zeichen, Crockford-Base32, das neunte eine
/// Prüfziffer. Er nennt App-Fassung, System und Geräteart – kein Gerät, kein Konto, keine Person.
enum DeviceCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 0 iOS, 1 iPadOS, 2 Android · Geräteart: 0 iPhone, 1 iPhone Duo, 2 iPad
    static func encode(platform: Int, os: Int, kind: Int, ramLog2: Int, major: Int, minor: Int, build: Int) -> String {
        var v: UInt64 = 0
        v |= UInt64(platform & 3) << 36
        v |= UInt64(os & 63) << 30
        v |= UInt64(kind & 7) << 27
        v |= UInt64(ramLog2 & 7) << 24
        v |= UInt64(major & 15) << 20
        v |= UInt64(minor & 63) << 14
        v |= UInt64(build & 16383)
        var vals = (0..<8).reversed().map { Int((v >> UInt64($0 * 5)) & 31) }
        vals.append(vals.enumerated().reduce(0) { $0 + $1.element * ($1.offset + 1) } % 31)
        let s = String(vals.map { alphabet[$0] })
        return "\(s.prefix(3))-\(s.dropFirst(3).prefix(3))-\(s.suffix(3))"
    }

    /// Ob dieses Gerät aufgeklappt war (die breite Seitenspalte des Duo) – gemerkt, sobald es einmal vorkam.
    /// Nur aufgeklappt hält ein Telefon bei voller Höhe eine breite Seitenspalte frei. Jedes iPhone mit Kamerainsel
    /// tut das auch, aber nur quer, und dann ist es senkrecht kompakt.
    static func looksLikeDuo(hasSideColumn: Bool, isPhone: Bool, verticallyCompact: Bool) -> Bool {
        hasSideColumn && isPhone && !verticallyCompact
    }

    static var seenDuo: Bool {
        get { UserDefaults.standard.bool(forKey: "geraet.duo") }
        set { UserDefaults.standard.set(newValue, forKey: "geraet.duo") }
    }

    static var current: String {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let os = Int(UIDevice.current.systemVersion.split(separator: ".").first ?? "0") ?? 0
        let gb = max(1, Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
        let ram = min(7, max(0, Int((log2(gb)).rounded())))
        let version = (Bundle.main.infoDictionary?[String(localized: "CFBundleShortVersionString")] as? String ?? "0.0").split(separator: ".").compactMap { Int($0) }
        let build = Int(Bundle.main.infoDictionary?[String(localized: "CFBundleVersion")] as? String ?? "0") ?? 0
        return encode(platform: pad ? 1 : 0, os: os, kind: pad ? 2 : (seenDuo ? 1 : 0), ramLog2: ram,
                      major: version.first ?? 0, minor: version.dropFirst().first ?? 0, build: build)
    }

    /// „ThisDog 0.1 (1), iOS 27, iPhone“ – für die Anzeige neben dem Code.
    static var description: String {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let v = Bundle.main.infoDictionary?[String(localized: "CFBundleShortVersionString")] as? String ?? "?"
        let b = Bundle.main.infoDictionary?[String(localized: "CFBundleVersion")] as? String ?? "?"
        let os = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "?"
        return String(localized: "ThisDog \(v) (\(b)), \(pad ? "iPadOS" : "iOS") \(os), \(pad ? "iPad" : (seenDuo ? "iPhone Duo" : "iPhone"))")
    }
}

enum Support {
    /// Schickt eine Anfrage; gibt die Nummer zurück („T-0001“).
    static func send(kind: String, email: String, text: String) async throws -> String {
        struct Body: Encodable { let kind: String; let email: String; let text: String; let code: String; let via = "app" }
        struct Answer: Decodable { let number: String }
        let a: Answer = try await Api().post("support.php", body: Body(kind: kind, email: email, text: text, code: DeviceCode.current))
        return a.number
    }
}

/// In den Einstellungen: Gerätecode zum Kopieren und „Problem melden“.
struct HelpSection: View {
    @Environment(Account.self) private var account
    @State private var copied = false
    @State private var reporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Support").font(.display(20, weight: .semibold)).foregroundStyle(Palette.ink)
            Button { reporting = true } label: {
                Label("Problem melden", icon: "melden").font(.body.weight(.semibold)).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gerätecode").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink2)
                    Text(DeviceCode.current).font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(Palette.ink).textSelection(.enabled)
                    Text(DeviceCode.description).font(.caption).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Button(copied ? String(localized: "Kopiert") : String(localized: "Kopieren")) {
                    UIPasteboard.general.string = DeviceCode.current
                    copied = true
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("Schreibst du an thisdog.app/support, gib den Gerätecode mit an. Er nennt Fassung, System und Gerät.")
                .font(.footnote).foregroundStyle(Palette.ink2)
        }
        .sheet(isPresented: $reporting) { SupportSheet() }
    }
}

/// Problem melden: Worum geht es, was ist passiert, wohin die Antwort geht. Der Gerätecode geht mit.
struct SupportSheet: View {
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "problem"
    @State private var text = ""
    @State private var email = ""
    @State private var sending = false
    @State private var number: String?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                if let number {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Angekommen", icon: "haken-kreis").font(.headline).foregroundStyle(Palette.verdict(.ok))
                            Text("Deine Nachricht hat die Nummer \(number). Die Antwort kommt per E-Mail an \(email), meist innerhalb von zwei Tagen.")
                                .foregroundStyle(Palette.ink2)
                        }
                    }
                } else {
                    Section {
                        Picker("Worum geht es?", selection: $kind) {
                            Text("Problem").tag("problem"); Text("Frage").tag("frage"); Text("Idee").tag("idee")
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("Was ist passiert?") {
                        TextField("Was hast du gemacht, was ist passiert, was hast du erwartet?", text: $text, axis: .vertical)
                            .lineLimit(5...12)
                    }
                    Section {
                        TextField("E-Mail-Adresse", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Antwort an") } footer: {
                        Text("Mit geht der Gerätecode \(DeviceCode.current): Fassung, System und Gerät. Deine Daten im Rudel bleiben, wo sie sind.")
                    }
                    if let message { Section { Text(message).foregroundStyle(Palette.kind(.health)) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .glassBar(number == nil ? String(localized: "Problem melden") : String(localized: "Danke")) {
                if number == nil {
                    BarTextItem(title: String(localized: "Abbrechen"), cancel: true) { dismiss() }
                    BarTextItem(title: String(localized: "Senden"), disabled: sending || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 || !email.contains("@")) { send() }
                } else {
                    BarTextItem(title: String(localized: "Fertig")) { dismiss() }
                }
            }
        }
        .tint(Palette.accent)
        .onAppear { if email.isEmpty, case .signedIn(let mail?) = account.state { email = mail } }
    }

    private func send() {
        sending = true; message = nil
        Task {
            do {
                number = try await Support.send(kind: kind, email: email.trimmingCharacters(in: .whitespaces), text: text)
            } catch Api.Failure.server("invalid_email") {
                message = String(localized: "Die E-Mail-Adresse stimmt nicht.")
            } catch Api.Failure.server("rate_limited") {
                message = String(localized: "Gerade kamen zu viele Nachrichten. Versuch es in einer Viertelstunde noch einmal.")
            } catch {
                message = String(localized: "Nicht gesendet. Prüfe die Verbindung und versuch es noch einmal.")
            }
            sending = false
        }
    }
}
