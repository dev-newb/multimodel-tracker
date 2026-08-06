import SwiftUI

/// Which 100% treatment is showing. Advances every third viewing — see
/// `Store.noteMaxedViewing()`.
enum MaxedStyle: Int, CaseIterable {
    // Raw values are persisted in mmt.maxedFixed, so existing cases keep
    // theirs. Fracture (1) was dropped for glitch at Rich's request.
    case flatline = 0, glitch = 1, bleed = 2, deadChannel = 3
    case blackHole = 4, drown = 5, petrify = 6, neonBurnout = 7

    var displayName: String {
        switch self {
        case .flatline:    return "Flatline"
        case .glitch:      return "Glitch"
        case .bleed:       return "Bleed"
        case .deadChannel: return "Dead channel"
        case .blackHole:   return "Black hole"
        case .drown:       return "Drown"
        case .petrify:     return "Petrify"
        case .neonBurnout: return "Neon burnout"
        }
    }
}

/// Replaces the plain capsule when a pool is fully burned. All three styles
/// draw from a TimelineView clock instead of SwiftUI animation state: a
/// popover's content view leaves the window on every close, and repeatForever
/// animations do not reliably resume when it comes back — a clock can't
/// get stuck.
///
/// Not a bar in the row's layout — LimitRow keeps a plain 5pt strip there and
/// hangs this on the ROW's background, bottom-aligned, so every label and
/// number paints on top ("effects need to render behind all text"). The
/// canvas is taller than the strip because Canvas clips to its own bounds —
/// an EKG drawn at negative y inside a 5pt canvas simply vanishes (verified
/// via --render-maxed: the trimmed path existed at y -10 and drew nothing).
struct MaxedBar: View {
    let style: MaxedStyle
    /// Reset on every appearance so the one-shot intros replay per viewing.
    @State private var opened = Date()

    static let barH = 5.0                // matches LimitRow's capsule height
    /// NOTHING is drawn above the bar any more. A tall headroom band put the
    /// EKG up at label height, which read as the effect being detached from
    /// the bar it belongs to. Everything now sits in the bar or in the gap
    /// below it, so the artwork always lines up with the capsule it replaces.
    static let above = 0.0
    static let below = 10.0              // gap below the bar, inside the row
    private static let canvasH = above + barH + below

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let since = context.date.timeIntervalSince(opened)
                switch style {
                case .flatline:    Self.drawFlatline(ctx, size, t: t, since: since)
                case .glitch:      Self.drawGlitch(ctx, size, t: t)
                case .bleed:       Self.drawBleed(ctx, size, t: t)
                case .deadChannel: Self.drawDeadChannel(ctx, size, t: t)
                case .blackHole:   Self.drawBlackHole(ctx, size, t: t)
                case .drown:       Self.drawDrown(ctx, size, t: t)
                case .petrify:     Self.drawPetrify(ctx, size, t: t)
                case .neonBurnout: Self.drawNeonBurnout(ctx, size, t: t)
                }
            }
        }
        .frame(height: Self.canvasH)
        .allowsHitTesting(false)
        .onAppear { opened = Date() }
    }

    private static let red    = Color(red: 0.91, green: 0.27, blue: 0.23)
    private static let dried  = Color(red: 0.42, green: 0.17, blue: 0.16)
    private static let shardC = Color(red: 0.79, green: 0.28, blue: 0.25)

    private static func easeOut(_ p: Double) -> Double { 1 - pow(1 - min(max(p, 0), 1), 3) }

    // MARK: flatline — collapses to a dead line, a heart trace running out above

    private static func drawFlatline(_ ctx: GraphicsContext, _ size: CGSize, t: Double, since: Double) {
        let e = easeOut(since / 0.55)
        let h = barH * (1 - 0.7 * e)
        let barRect = CGRect(x: 0, y: above + (barH - h) / 2, width: size.width, height: h)
        ctx.fill(Path(roundedRect: barRect, cornerRadius: h / 2), with: .color(dried))
        if e < 1 {
            ctx.fill(Path(roundedRect: barRect, cornerRadius: h / 2),
                     with: .color(red.opacity(1 - e)))
        }

        // EKG polyline in the gap BELOW the bar.
        let bandH = 9.0, bandTop = above + barH + 0.5
        let pts: [(Double, Double)] = [(0, 0.5), (0.293, 0.5), (0.31, 0.2), (0.327, 0.8),
                                       (0.347, 0.067), (0.363, 0.5), (1, 0.5)]
        var path = Path()
        path.move(to: CGPoint(x: 0, y: bandTop + 0.5 * bandH))
        for (fx, fy) in pts.dropFirst() {
            path.addLine(to: CGPoint(x: fx * size.width, y: bandTop + fy * bandH))
        }
        let ph = (t / 2.6).truncatingRemainder(dividingBy: 1.3)
        let trace = path.trimmedPath(from: max(0, ph - 0.22), to: min(ph, 1))
        ctx.stroke(trace, with: .color(red.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }

    // MARK: glitch — slices shear out of register with RGB ghosts

    private static let cyan = Color(red: 0, green: 1, blue: 0.92)
    private static let magenta = Color(red: 1, green: 0, blue: 0.5)

    private static func drawGlitch(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        // Slices jump on their own stepped clocks, so the bar never looks
        // like it is simply sliding — it tears.
        let slices: [(x: Double, w: Double, period: Double, top: Double, height: Double)] = [
            (0.00, 0.30, 0.9,  0.0, 0.6),
            (0.30, 0.45, 1.1,  0.4, 0.6),
            (0.75, 0.25, 0.7,  0.0, 1.0),
        ]
        for (i, s) in slices.enumerated() {
            let step = Int(t / s.period * 4) &+ i * 7
            let offsets: [Double] = [0, 3, -2, 0, -4, 2, 0, 1]
            let dx = offsets[abs(step) % offsets.count]
            let rect = CGRect(x: s.x * size.width + dx, y: above + s.top * barH,
                              width: s.w * size.width, height: s.height * barH)
            // Chromatic fringes first, body over them.
            ctx.fill(Path(rect.offsetBy(dx: 2, dy: 0)), with: .color(cyan.opacity(0.35)))
            ctx.fill(Path(rect.offsetBy(dx: -2, dy: 0)), with: .color(magenta.opacity(0.35)))
            ctx.fill(Path(rect), with: .color(red))
        }
    }

    // MARK: black hole — swallowed into a point, then torn back out

    private static func drawBlackHole(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let p = (t / 3.2).truncatingRemainder(dividingBy: 1)
        // Collapse to a sliver, hold, then snap back.
        let scale: Double
        switch p {
        case ..<0.12:  scale = 1
        case ..<0.48:  scale = 1 - 0.98 * easeOut((p - 0.12) / 0.36)
        case ..<0.62:  scale = 0.02
        default:       scale = 0.02 + 0.98 * easeOut((p - 0.62) / 0.38)
        }
        let w = size.width * scale
        let rect = CGRect(x: (size.width - w) / 2, y: above, width: max(1, w), height: barH)
        ctx.fill(Path(roundedRect: rect, cornerRadius: barH / 2), with: .color(red))
        // Ring pulse at the moment it vanishes.
        if p > 0.46, p < 0.75 {
            let e = (p - 0.46) / 0.29
            let r = 3 + 26 * e
            let ring = CGRect(x: size.width / 2 - r, y: above + barH / 2 - r * 0.36,
                              width: r * 2, height: r * 0.72)
            ctx.stroke(Path(ellipseIn: ring), with: .color(red.opacity(0.85 * (1 - e))),
                       lineWidth: 1)
        }
    }

    // MARK: drown — a dark waterline rises over the bar, bubbles escape

    private static func drawDrown(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let p = (t / 5.0).truncatingRemainder(dividingBy: 1)
        let submerge = p < 0.15 ? 0 : (p < 0.55 ? easeOut((p - 0.15) / 0.4)
                                                : (p < 0.9 ? 1 : 1 - easeOut((p - 0.9) / 0.1)))
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: above + submerge * 2, width: size.width, height: barH),
                      cornerRadius: barH / 2),
                 with: .color(Color(red: 0.76, green: 0.27, blue: 0.23)))
        // Water creeps up from the bottom of the bar.
        if submerge > 0 {
            let h = barH * submerge
            var c = ctx
            c.clip(to: Path(roundedRect: CGRect(x: 0, y: above, width: size.width, height: barH),
                            cornerRadius: barH / 2))
            c.fill(Path(CGRect(x: 0, y: above + barH - h, width: size.width, height: h)),
                   with: .color(Color(red: 0.08, green: 0.16, blue: 0.28).opacity(0.85)))
        }
        for (i, x) in [0.30, 0.62, 0.84].enumerated() {
            let bp = (t / 5.0 + Double(i) * 0.27).truncatingRemainder(dividingBy: 1)
            guard bp > 0.5 else { continue }
            let e = (bp - 0.5) / 0.5
            let y = above + barH - 1 - 7 * e
            ctx.stroke(Path(ellipseIn: CGRect(x: x * size.width - 1.5, y: y, width: 3, height: 3)),
                       with: .color(Color(red: 0.63, green: 0.78, blue: 1).opacity(0.55 * (1 - e))),
                       lineWidth: 0.8)
        }
    }

    // MARK: petrify — colour drains to stone and cracks spider through

    private static func drawPetrify(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let p = (t / 5.2).truncatingRemainder(dividingBy: 1)
        let stone = p < 0.12 ? 0 : (p < 0.45 ? easeOut((p - 0.12) / 0.33)
                                             : (p < 0.88 ? 1 : 1 - easeOut((p - 0.88) / 0.12)))
        let colour = Color(red: 0.91 + (0.54 - 0.91) * stone,
                           green: 0.27 + (0.54 - 0.27) * stone,
                           blue: 0.23 + (0.55 - 0.23) * stone)
        let bar = CGRect(x: 0, y: above, width: size.width, height: barH)
        ctx.fill(Path(roundedRect: bar, cornerRadius: barH / 2), with: .color(colour))
        guard stone > 0.35 else { return }
        var c = ctx
        c.clip(to: Path(roundedRect: bar, cornerRadius: barH / 2))
        let alpha = (stone - 0.35) / 0.65
        for x in [0.24, 0.52, 0.76] {
            var path = Path()
            path.move(to: CGPoint(x: x * size.width, y: above))
            path.addLine(to: CGPoint(x: x * size.width + 2.5, y: above + barH * 0.55))
            path.addLine(to: CGPoint(x: x * size.width - 1.5, y: above + barH))
            c.stroke(path, with: .color(.black.opacity(0.55 * alpha)), lineWidth: 0.9)
        }
    }

    // MARK: neon burnout — a tube that can't hold its light

    private static func drawNeonBurnout(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let bar = CGRect(x: 0, y: above, width: size.width, height: barH)
        ctx.fill(Path(roundedRect: bar, cornerRadius: barH / 2),
                 with: .color(Color(red: 0.24, green: 0.11, blue: 0.10)))
        // Stepped, irregular flicker — a steady sine would read as a pulse,
        // not a failing tube.
        let steps: [Double] = [1, 0.2, 1, 0.35, 0.95, 0.95, 0.15, 0.85,
                               0.85, 0.1, 0.7, 0.7, 0.05, 0.6, 1, 1]
        let lit = steps[Int(t / 0.175) % steps.count]
        guard lit > 0.08 else { return }
        // Halo first so the tube core stays crisp on top.
        ctx.fill(Path(roundedRect: bar.insetBy(dx: -2.5, dy: -2.5), cornerRadius: barH),
                 with: .color(red.opacity(0.20 * lit)))
        ctx.fill(Path(roundedRect: bar.insetBy(dx: -1, dy: -1), cornerRadius: barH),
                 with: .color(red.opacity(0.30 * lit)))
        ctx.fill(Path(roundedRect: bar, cornerRadius: barH / 2), with: .color(red.opacity(lit)))
    }

    // MARK: dead channel — the signal is gone, just snow

    /// Deterministic per-(cell, frame) hash — SplitMix64 finisher. Canvas has
    /// no per-frame state to keep an RNG in, and Date-free determinism means
    /// the same frame always draws the same snow.
    private static func hash(_ a: Int, _ b: Int, _ c: Int) -> UInt64 {
        var z = UInt64(bitPattern: Int64(a)) &* 0x9E3779B97F4A7C15
        z ^= UInt64(bitPattern: Int64(b)) &* 0xBF58476D1CE4E5B9
        z ^= UInt64(bitPattern: Int64(c)) &* 0x94D049BB133111EB
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    private static func drawDeadChannel(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        var c = ctx
        c.clip(to: Path(roundedRect: CGRect(x: 0, y: above, width: size.width, height: barH),
                        cornerRadius: barH / 2))
        c.fill(Path(CGRect(x: 0, y: above, width: size.width, height: barH)),
               with: .color(Color(red: 0.14, green: 0.14, blue: 0.15)))
        // New snow field ~12 times a second; global flicker like a set
        // hunting for signal.
        let frame = Int(t / 0.085)
        let flickerSteps: [Double] = [0.8, 0.55, 0.85, 0.7, 0.95, 0.6]
        let flicker = flickerSteps[Int(t / 0.28) % flickerSteps.count]
        let cell = 2.0
        let cols = Int(size.width / cell) + 1
        let rows = Int(barH / cell) + 1
        let levels: [Double] = [0, 0, 0.12, 0.25, 0.42, 0.58, 0.72, 0.86]
        for col in 0..<cols {
            for row in 0..<rows {
                let level = levels[Int(hash(frame, col, row) % UInt64(levels.count))]
                guard level > 0 else { continue }
                c.fill(Path(CGRect(x: Double(col) * cell, y: above + Double(row) * cell,
                                   width: cell, height: cell)),
                       with: .color(Color(white: level).opacity(0.85 * flicker)))
            }
        }
    }

    // MARK: bleed — overfilled, leaking down out of the track

    private static func drawBleed(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: above, width: size.width, height: barH),
                      cornerRadius: barH / 2), with: .color(red))
        let drops: [(x: Double, phase: Double)] = [(0.22, 0), (0.55, 0.33), (0.81, 0.59)]
        for d in drops {
            let p = (t / 2.9 + d.phase).truncatingRemainder(dividingBy: 1)
            let y = above + barH - 1 + 16 * p * p          // ease-in fall
            let stretch = 1 + 1.4 * p * (1 - p) * 4        // longest mid-fall
            let drop = CGRect(x: d.x * size.width - 1.5, y: y, width: 3, height: 4 * stretch)
            ctx.fill(Path(roundedRect: drop, cornerRadius: 1.5),
                     with: .color(red.opacity(0.9 * (1 - p))))
        }
    }
}
