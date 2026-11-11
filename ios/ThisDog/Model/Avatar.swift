import SwiftUI
import UIKit

/// Ein Bild für den Hund oder ein Rudelmitglied. Läuft durch den Abgleich wie alles andere:
/// `dog` für den Hund, `member-<Konto>` für jede Person – so hat jedes Gerät im Rudel dieselben Bilder.
struct Avatar: SyncedItem, Hashable {
    static let kind = "avatar"
    static let dog = "dog"
    static func member(_ account: Int) -> String { "member-\(account)" }

    let id: String
    /// JPEG, Base64 – quadratisch und klein, damit es in einen Datensatz passt.
    var jpeg: String
    var u: Double = 0

    /// Höchstens so viele Zeichen Base64 – der Server nimmt 80 000 je Datensatz, mit Luft für den Rest.
    static let maxLength = 60_000

    /// Quadratisch zugeschnitten (Mitte), 320 px, JPEG – bei Fotos gut 20 KB. Ist es zu groß
    /// (sehr unruhige Bilder), sinkt erst die Qualität, dann die Größe.
    static func prepare(_ data: Data) -> String? {
        guard let image = PickedPhoto.image(data, maxPixel: 1200), min(image.size.width, image.size.height) > 0 else { return nil }
        for side in [320.0, 240.0] {
            let square = render(image, side: side)
            for q in [0.72, 0.6, 0.45, 0.3] {
                if let s = square.jpegData(compressionQuality: q)?.base64EncodedString(), s.count <= maxLength { return s }
            }
        }
        return nil
    }

    private static func render(_ image: UIImage, side: CGFloat) -> UIImage {
        let size = image.size
        let scale = side / min(size.width, size.height)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: .photo).image { _ in
            image.draw(in: CGRect(x: (side - size.width * scale) / 2, y: (side - size.height * scale) / 2,
                                  width: size.width * scale, height: size.height * scale))
        }
    }
}
