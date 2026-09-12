import SwiftUI
import AppKit

/// The app icon — the "Rings" concept, drawn in code so the .icns is
/// reproducible and crisp at every size (16 → 1024). Same superellipse
/// squircle and vendor-accent arcs shown in the icon bakeoff: clay /
/// teal / blue at the pools' fill levels. Rendered by `--render-appicon`.
struct AppIconView: View {
    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 1024
            var xf = CGAffineTransform(scaleX: k, y: k)
            let sq = Path(Self.squircle(1024).copy(using: &xf) ?? Self.squircle(1024))

            // Ground: charcoal with a slight warm-purple bias, lighter at the
            // top for depth.
            ctx.fill(sq, with: .linearGradient(
                Gradient(colors: [Color(hex: 0x241F2E), Color(hex: 0x0C0B10)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            ctx.drawLayer { l in
                l.clip(to: sq)
                // Top gloss.
                l.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0)]),
                    center: CGPoint(x: size.width * 0.5, y: size.height * 0.02),
                    startRadius: 0, endRadius: size.width * 0.9))

                let c = CGPoint(x: 512 * k, y: 512 * k)
                let w = 70 * k
                func ring(_ r: CGFloat, _ col: Color, _ pct: CGFloat) {
                    var track = Path()
                    track.addArc(center: c, radius: r * k, startAngle: .zero,
                                 endAngle: .degrees(360), clockwise: false)
                    l.stroke(track, with: .color(.white.opacity(0.09)), style: StrokeStyle(lineWidth: w))
                    var p = Path()
                    p.addArc(center: c, radius: r * k, startAngle: .degrees(-90),
                             endAngle: .degrees(-90 + 360 * Double(pct)), clockwise: false)
                    l.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: w, lineCap: .round))
                }
                ring(322, Color(hex: 0xDA7A52), 0.63)   // Anthropic clay
                ring(230, Color(hex: 0x12B48C), 0.41)   // OpenAI teal
                ring(138, Color(hex: 0x4C8DF6), 0.86)   // Google blue
            }
            // Inner light edge.
            ctx.stroke(sq, with: .color(.white.opacity(0.08)), lineWidth: 3 * k)
        }
    }

    /// Superellipse (n=5) squircle — the macOS icon shape, matched to the
    /// approved bakeoff mock.
    static func squircle(_ s: CGFloat, n: CGFloat = 5, steps: Int = 180) -> CGPath {
        let a = s / 2, cx = s / 2, cy = s / 2
        let path = CGMutablePath()
        for i in 0...steps {
            let t = 2 * Double.pi * Double(i) / Double(steps)
            let ct = cos(t), st = sin(t)
            let x = cx + a * CGFloat(copysign(pow(abs(ct), 2 / Double(n)), ct))
            let y = cy + a * CGFloat(copysign(pow(abs(st), 2 / Double(n)), st))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
