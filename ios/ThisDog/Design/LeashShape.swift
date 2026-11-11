import SwiftUI

/// Die Leine als glatte Linie durch Punkte, damit sie überall gleich locker aussieht: im Monat, auf der Zeitleine.
struct LeashShape: Shape {
    var points: [CGPoint]
    func path(in rect: CGRect) -> Path { Self.curve(points) }

    /// Catmull-Rom: läuft durch jeden Punkt, ohne Ecken.
    static func curve(_ P: [CGPoint]) -> Path {
        var path = Path()
        guard let first = P.first else { return path }
        path.move(to: first)
        for i in 0..<max(0, P.count - 1) {
            let p0 = i > 0 ? P[i - 1] : P[i], p1 = P[i], p2 = P[i + 1], p3 = i + 2 < P.count ? P[i + 2] : p2
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    /// Eine Schlinge um `center`: Die Leine läuft in Richtung `along` hinein, kreuzt sich und läuft geradeaus weiter.
    static func loop(center c: CGPoint, along u: CGVector, radius r: CGFloat, side: CGFloat) -> [CGPoint] {
        let drift = r * 0.42
        return (0...16).map { m in
            let w = -CGFloat.pi + CGFloat(m) / 16 * 2 * .pi
            let a = drift * w - r * sin(w), o = r * (1 + cos(w)) * side
            return CGPoint(x: c.x + u.dx * a - u.dy * o, y: c.y + u.dy * a + u.dx * o)
        }
    }
}
