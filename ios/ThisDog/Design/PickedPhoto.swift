import ImageIO
import PhotosUI
import SwiftUI
import UIKit

/// Fotos aus der Mediathek laden – auch HEIC, HDR und sehr große Bilder (48 MP).
///
/// `UIImage(data:)` dekodiert ein HEIC vom iPhone in voller Größe und mit HDR. Daraus ließ sich beim
/// Verkleinern kein JPEG mehr machen, das Hochladen blieb still stehen (bearbeitete Fotos gingen, weil
/// Fotos sie schon als normales Bild ablegt). Hier wird gleich beim Dekodieren verkleinert, gedreht und
/// in normalen Farbumfang (SDR) gebracht.
enum PickedPhoto {
    /// Lädt das Foto; `nil`, wenn es sich nicht laden ließ.
    static func image(_ item: PhotosPickerItem, maxPixel: CGFloat = 2400) async -> UIImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return image(data, maxPixel: maxPixel)
    }

    static func image(_ data: Data, maxPixel: CGFloat = 2400) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

extension UIGraphicsImageRendererFormat {
    /// Für Bilder, die als JPEG weitergehen: ein Pixel je Punkt (nicht dreifach wie der Bildschirm) und
    /// normaler Farbumfang – aus einem HDR-Bild entstünde sonst kein JPEG.
    static var photo: UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.preferredRange = .standard
        return f
    }
}
