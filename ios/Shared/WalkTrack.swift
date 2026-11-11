import CoreLocation
import Foundation

// MARK: Strecke kodieren

/// Das Polyline-Verfahren von Google: Koordinaten als Differenzen in druckbaren Zeichen.
/// Eine Runde von 5 km mit Punkten alle paar Meter wird so zu wenigen Kilobyte.
enum Polyline {
    static func encode(_ coords: [CLLocationCoordinate2D]) -> String {
        var out = ""
        var lastLat = 0, lastLon = 0
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded()), lon = Int((c.longitude * 1e5).rounded())
            out += chunk(lat - lastLat) + chunk(lon - lastLon)
            lastLat = lat
            lastLon = lon
        }
        return out
    }

    static func decode(_ s: String) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        let bytes = Array(s.utf8)
        var i = 0, lat = 0, lon = 0
        func next() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }
        while i < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            out.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return out
    }

    private static func chunk(_ value: Int) -> String {
        var v = value < 0 ? ~(value << 1) : value << 1
        var out = ""
        while v >= 0x20 {
            out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1F)) + 63)))
            v >>= 5
        }
        out.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
        return out
    }
}

// MARK: Strecke glätten

enum Track {
    static let maxAccuracy: CLLocationAccuracy = 30
    /// Schneller als 7 m/s (25 km/h) läuft niemand mit Hund – das ist ein Sprung der Ortung.
    static let maxSpeed: Double = 7
    static let minStep: Double = 2

    /// Wie weit ein neuer Ortungspunkt zählt; `nil`, wenn er zu nah oder ein Sprung ist.
    static func step(from last: CLLocation, to loc: CLLocation) -> Double? {
        let d = loc.distance(from: last)
        let dt = loc.timestamp.timeIntervalSince(last.timestamp)
        if d < minStep { return nil }
        if dt > 0, d / dt > maxSpeed { return nil }
        return d
    }

    /// Entfernung zweier Punkte in Metern.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func length(_ coords: [CLLocationCoordinate2D]) -> Double {
        zip(coords, coords.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Douglas-Peucker: lässt Punkte weg, die weniger als `tolerance` Meter von der Linie abweichen.
    /// Die Länge der Runde wird vorher gemessen, nicht aus der geglätteten Linie.
    static func simplify(_ coords: [CLLocationCoordinate2D], tolerance: Double = 3) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }
        var keep = [Bool](repeating: false, count: coords.count)
        keep[0] = true
        keep[coords.count - 1] = true
        var stack = [(0, coords.count - 1)]
        while let (a, b) = stack.popLast() {
            var maxD = 0.0, index = 0
            for i in (a + 1)..<b {
                let d = offset(coords[i], from: coords[a], to: coords[b])
                if d > maxD { maxD = d; index = i }
            }
            if maxD > tolerance {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return coords.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    /// Abstand eines Punktes von der Strecke a–b in Metern (eben gerechnet; für eine Runde genau genug).
    private static func offset(_ p: CLLocationCoordinate2D, from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let mPerLat = 111_320.0, mPerLon = 111_320.0 * cos(a.latitude * .pi / 180)
        let (px, py) = ((p.longitude - a.longitude) * mPerLon, (p.latitude - a.latitude) * mPerLat)
        let (bx, by) = ((b.longitude - a.longitude) * mPerLon, (b.latitude - a.latitude) * mPerLat)
        let len2 = bx * bx + by * by
        guard len2 > 0 else { return (px * px + py * py).squareRoot() }
        let t = max(0, min(1, (px * bx + py * by) / len2))
        let (dx, dy) = (px - t * bx, py - t * by)
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: Darstellung

enum WalkText {
    /// „1,84 km“ oder „650 m“.
    static func distance(_ m: Double) -> String {
        if m < 1000 { return String(localized: "\(Int((m / 10).rounded()) * 10) m") }
        return (m / 1000).formatted(.number.precision(.fractionLength(m < 10_000 ? 2 : 1)).locale(AppLocale.current)) + String(localized: " km")
    }

    /// Nur die Zahl, für die großen Anzeigen („1,84“).
    static func km(_ m: Double) -> String {
        (m / 1000).formatted(.number.precision(.fractionLength(2)).locale(AppLocale.current))
    }

    /// „23:41“ oder „1:05:12“.
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// „42 Min.“ oder „1 Std. 5 Min.“.
    static func duration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? String(localized: "\(m / 60) Std. \(m % 60) Min.") : String(localized: "\(m) Min.")
    }

    /// Tempo als „12:52“ (Minuten je Kilometer).
    static func pace(_ minPerKm: Double?) -> String {
        guard let p = minPerKm, p.isFinite, p < 60 else { return "–" }
        let s = Int((p * 60).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
