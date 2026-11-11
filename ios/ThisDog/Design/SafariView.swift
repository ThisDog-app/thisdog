import SafariServices
import SwiftUI

/// Eine Webseite in der App (Datenschutz, Impressum), mit Fertig-Button statt Wechsel nach Safari.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Palette.accent)
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

enum Legal: String, Identifiable {
    case privacy = "datenschutz", help = "support", imprint = "impressum"
    var id: String { rawValue }
    var url: URL { URL(string: "https://thisdog.app/\(rawValue)")! }
    var title: String { switch self { case .privacy: String(localized: "Datenschutz"); case .help: String(localized: "Support"); case .imprint: String(localized: "Impressum") } }
}

/// „Datenschutz“ und „Impressum“ als zwei leise Links.
struct LegalLinks: View {
    @State private var shown: Legal?

    var body: some View {
        HStack(spacing: 20) {
            ForEach([Legal.privacy, .imprint]) { l in
                Button(l.title) { shown = l }
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.ink2)
        .sheet(item: $shown) { SafariView(url: $0.url).ignoresSafeArea() }
    }
}
