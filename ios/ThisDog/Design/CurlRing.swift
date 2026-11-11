import SwiftUI

/// Ein Ring wie eine Locke des Logos: fast geschlossen, am offenen Ende ein Punkt.
struct CurlRing: View {
    var color: Color
    var lineWidth: CGFloat = 1.6

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2 - lineWidth
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let start = Angle.degrees(-60)
            let dot = CGPoint(x: c.x + r * cos(start.radians), y: c.y + r * sin(start.radians))
            ZStack {
                Path { p in
                    p.addArc(center: c, radius: r, startAngle: start, endAngle: .degrees(250), clockwise: false)
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle()
                    .fill(color)
                    .frame(width: lineWidth * 3.2, height: lineWidth * 3.2)
                    .position(dot)
            }
        }
    }
}
