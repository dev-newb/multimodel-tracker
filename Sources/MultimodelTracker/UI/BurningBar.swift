import SwiftUI

/// What a pool that is burning tokens fast looks like. Same clock-driven
/// Canvas approach as MaxedBar — see that file for why animation state is
/// avoided inside a popover.
enum BurnStyle: Int, CaseIterable {
    case firestorm = 0, coalBed = 1, blowtorch = 2, comet = 3, fuse = 4

    /// One full loop, for the Accounts preview.
    var cycleSeconds: Double {
        switch self {
        case .firestorm: return 1.5
        case .coalBed:   return 2.6
        case .blowtorch: return 1.5
        case .comet:     return 1.0
        case .fuse:      return 1.6
        }
    }

    var displayName: String {
        switch self {
        case .firestorm: return "Firestorm"
        case .coalBed:   return "Coal bed"
        case .blowtorch: return "Blowtorch"
        case .comet:     return "Comet"
        case .fuse:      return "Fuse"
        }
    }

    /// Firestorm and coal bed set the whole fill alight; the rest burn at the
    /// leading edge. Used to decide how much headroom the row needs.
    var isWholeBar: Bool { self == .firestorm || self == .coalBed }
}

/// Replaces the plain fill while a pool is climbing fast. Draws the fill
/// itself, so `fraction` decides where the fire stops — fire must never burn
/// over the empty part of the track.
struct BurningBar: View {
    let style: BurnStyle
    let fraction: Double

    static let barH = 5.0
    static let above = 12.0     // headroom for flames and embers
    static let below = 4.0
    private static let canvasH = above + barH + below

    /// When false the clock stops and a single frame is drawn. See
    /// Store.uiVisible.
    var animating = true

    @ViewBuilder
    var body: some View {
        // See MaxedBar: a hidden view gets no timeline at all.
        if animating {
            TimelineView(.animation) { context in
                canvas(at: context.date.timeIntervalSinceReferenceDate)
            }
            .frame(height: Self.canvasH)
            .allowsHitTesting(false)
        } else {
            canvas(at: 0)
                .frame(height: Self.canvasH)
                .allowsHitTesting(false)
        }
    }

    private func canvas(at t: Double) -> some View {
        Canvas { ctx, size in
            let w = max(2, size.width * min(max(fraction, 0), 1))
            Self.drawTrack(ctx, size)
            switch style {
            case .firestorm: Self.drawFirestorm(ctx, size, w: w, t: t)
            case .coalBed:   Self.drawCoalBed(ctx, size, w: w, t: t)
            case .blowtorch: Self.drawBlowtorch(ctx, size, w: w, t: t)
            case .comet:     Self.drawComet(ctx, size, w: w, t: t)
            case .fuse:      Self.drawFuse(ctx, size, w: w, t: t)
            }
        }
    }

    private static let ember  = Color(red: 1.0, green: 0.80, blue: 0.30)
    private static let flame  = Color(red: 1.0, green: 0.48, blue: 0.12)
    private static let deep   = Color(red: 0.78, green: 0.20, blue: 0.09)

    private static func drawTrack(_ ctx: GraphicsContext, _ size: CGSize) {
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: above, width: size.width, height: barH),
                      cornerRadius: barH / 2), with: .color(.primary.opacity(0.10)))
    }

    private static func barPath(_ w: Double) -> Path {
        Path(roundedRect: CGRect(x: 0, y: above, width: w, height: barH), cornerRadius: barH / 2)
    }

    // MARK: firestorm — a hot band races through, embers lift off along it

    private static func drawFirestorm(_ ctx: GraphicsContext, _ size: CGSize, w: Double, t: Double) {
        var c = ctx
        c.clip(to: barPath(w))
        // Faster and hotter than the first cut, which read as a gentle sweep.
        // First and last stops are the SAME colour so the loop has no seam.
        let span = w * 1.15
        let shift = (t / 0.55).truncatingRemainder(dividingBy: 1) * span
        let stops: [Color] = [deep, flame, ember, flame, deep, ember, deep]
        for i in -1...2 {
            let x = -span + shift + Double(i) * span
            c.fill(Path(CGRect(x: x, y: above, width: span, height: barH)),
                   with: .linearGradient(Gradient(colors: stops),
                                         startPoint: CGPoint(x: x, y: 0),
                                         endPoint: CGPoint(x: x + span, y: 0)))
        }
        // Flare-ups: the whole stretch surges every second or so.
        if let p = FX.eventProgress(t, slot: 1.1, jitter: 0.4, duration: 0.25, salt: 61) {
            c.fill(Path(CGRect(x: 0, y: above, width: w, height: barH)),
                   with: .color(ember.opacity(0.5 * sin(.pi * p))))
        }

        // Twice the embers, thrown higher and wider.
        for i in 0..<12 {
            let phase = (t / 0.9 + Double(i) * 0.083).truncatingRemainder(dividingBy: 1)
            let x = w * (0.04 + 0.08 * Double(i))
            guard x < w else { continue }
            let drift = (FX.hash01(i, 3) - 0.5) * 14
            let y = above + barH - 1 - 22 * phase
            let r = (1.0 + FX.hash01(i, 8) * 1.4) * (1 - phase * 0.55)
            ctx.fill(Path(ellipseIn: CGRect(x: x + drift * phase, y: y, width: r * 2, height: r * 2)),
                     with: .color(ember.opacity(0.95 * (1 - phase))))
        }
    }

    // MARK: coal bed — embers breathing, ash drifting off

    private static func drawCoalBed(_ ctx: GraphicsContext, _ size: CGSize, w: Double, t: Double) {
        var c = ctx
        c.clip(to: barPath(w))
        // The demo's CSS version tiled a background and showed a seam where
        // the tile wrapped. Here the hotspots are drawn as discrete blobs on a
        // continuous base, so there is no repeating texture to seam.
        c.fill(Path(CGRect(x: 0, y: above, width: w, height: barH)),
               with: .color(Color(red: 0.36, green: 0.11, blue: 0.05)))
        let breathe = 0.75 + 0.35 * (1 + sin(2 * .pi * t / 2.6)) / 2
        // Overlapping and wide: narrow coals with gaps between them read as
        // dashes, not a bed.
        for i in 0..<9 {
            // Each coal drifts at its own speed and wraps independently, so
            // no shared period can line them up into a visible edge.
            let speed = 0.055 + 0.02 * Double(i % 3)
            let x = ((Double(i) * 0.145 + t * speed).truncatingRemainder(dividingBy: 1.3) - 0.15) * w
            let heat = (1 + sin(2 * .pi * (t / 1.9 + Double(i) * 0.31))) / 2
            let rw = w * 0.26
            let rect = CGRect(x: x - rw / 2, y: above - 1.5, width: rw, height: barH + 3)
            c.fill(Path(ellipseIn: rect),
                   with: .color(flame.opacity(0.22 + 0.5 * heat * breathe)))
        }
        for i in 0..<4 {
            let phase = (t / 2.4 + Double(i) * 0.27).truncatingRemainder(dividingBy: 1)
            let x = w * (0.15 + 0.24 * Double(i))
            guard x < w else { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: x - 4 * phase, y: above - 13 * phase,
                                            width: 1.8, height: 1.8)),
                     with: .color(Color(white: 0.62).opacity(0.55 * (1 - phase))))
        }
    }

    // MARK: blowtorch — a jet off the leading edge

    private static func drawBlowtorch(_ ctx: GraphicsContext, _ size: CGSize, w: Double, t: Double) {
        // Fill ramps to white-hot at the tip so the jet grows OUT of the bar
        // rather than being pasted onto a flat red end.
        ctx.fill(barPath(w), with: .linearGradient(
            Gradient(stops: [.init(color: deep, location: 0),
                             .init(color: flame, location: 0.72),
                             .init(color: ember, location: 0.94),
                             .init(color: Color(red: 1, green: 0.95, blue: 0.78), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
        let pulse = 0.85 + 0.3 * (1 + sin(2 * .pi * t / 0.28)) / 2

        // The TAIL: reaches back over the bar and tapers to nothing, twice as
        // long as before so it blends in gradually instead of stopping dead.
        // Only the tail is doubled — the hot tip keeps its length.
        var tail = Path()
        let midY = above + barH / 2
        let tailLen = min(w * 0.55, 78.0)
        let tailStart = w - tailLen
        tail.move(to: CGPoint(x: tailStart, y: midY))
        // Upper edge swells from zero at the back to full height at the torch.
        for step in 0...18 {
            let f = Double(step) / 18
            let x = tailStart + tailLen * f
            let h = 4.2 * pow(f, 2.1) * pulse      // gradual, not linear
            tail.addLine(to: CGPoint(x: x, y: midY - h))
        }
        for step in stride(from: 18, through: 0, by: -1) {
            let f = Double(step) / 18
            let x = tailStart + tailLen * f
            let h = 4.2 * pow(f, 2.1) * pulse
            tail.addLine(to: CGPoint(x: x, y: midY + h))
        }
        tail.closeSubpath()
        ctx.fill(tail, with: .linearGradient(
            Gradient(colors: [flame.opacity(0), flame.opacity(0.45), ember.opacity(0.7)]),
            startPoint: CGPoint(x: tailStart, y: 0), endPoint: CGPoint(x: w, y: 0)))

        // Three nested tongues ahead of the bar, unchanged in length.
        let layers: [(len: Double, h: Double, colour: Color, inset: Double)] = [
            (26, 9, flame.opacity(0.40), 10),
            (18, 6.5, ember.opacity(0.60), 7),
            (11, 4, Color(red: 1, green: 0.97, blue: 0.85).opacity(0.85), 4),
        ]
        for l in layers {
            let len = l.len * pulse
            var p = Path()
            p.move(to: CGPoint(x: w - l.inset, y: midY - l.h / 2))
            p.addQuadCurve(to: CGPoint(x: w + len, y: midY),
                           control: CGPoint(x: w + len * 0.45, y: midY - l.h / 2))
            p.addQuadCurve(to: CGPoint(x: w - l.inset, y: midY + l.h / 2),
                           control: CGPoint(x: w + len * 0.45, y: midY + l.h / 2))
            p.closeSubpath()
            ctx.fill(p, with: .color(l.colour))
        }
    }

    // MARK: comet — burning head throwing a tail back down the bar

    private static func drawComet(_ ctx: GraphicsContext, _ size: CGSize, w: Double, t: Double) {
        ctx.fill(barPath(w), with: .linearGradient(
            Gradient(colors: [deep, flame]), startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
        var c = ctx
        c.clip(to: barPath(w))
        // More tails, moving faster and reaching further back.
        for i in 0..<5 {
            let phase = (t / 0.7 + Double(i) * 0.2).truncatingRemainder(dividingBy: 1)
            let len = w * 0.32
            let x = w - len - 30 * phase
            c.fill(Path(roundedRect: CGRect(x: x, y: above + 0.5, width: len, height: barH - 1),
                        cornerRadius: 1.5),
                   with: .linearGradient(
                        Gradient(colors: [ember.opacity(0), ember.opacity(0.9 * (1 - phase))]),
                        startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + len, y: 0)))
        }
        // Head: harder pulse than before.
        let pulse = 0.7 + 0.7 * (1 + sin(2 * .pi * t / 0.32)) / 2
        let r = 5.2 * pulse
        ctx.fill(Path(ellipseIn: CGRect(x: w - r, y: above + barH / 2 - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(
                    Gradient(colors: [Color(red: 1, green: 0.97, blue: 0.82), ember.opacity(0)]),
                    center: CGPoint(x: w, y: above + barH / 2), startRadius: 0, endRadius: r))

        // Sparks thrown off the head: up fast, then falling under gravity, so
        // each traces a parabola rather than a straight line.
        for i in 0..<7 {
            let life = 1.15
            let phase = (t / life + Double(i) * 0.143).truncatingRemainder(dividingBy: 1)
            let vx = 6 + FX.hash01(i, 2) * 16          // forward speed
            let vy = 15 + FX.hash01(i, 5) * 13         // initial upward speed
            let g = 46.0
            let x = w + vx * phase
            // Classic projectile: rises, slows, falls back past the start.
            let y = above + barH / 2 - (vy * phase - 0.5 * g * phase * phase)
            let size = 1.0 + FX.hash01(i, 9) * 0.8
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: size * 2, height: size * 2)),
                     with: .color(ember.opacity(0.95 * (1 - phase * phase))))
        }
    }

    // MARK: fuse — a burning tip spitting sparks

    private static func drawFuse(_ ctx: GraphicsContext, _ size: CGSize, w: Double, t: Double) {
        ctx.fill(barPath(w), with: .linearGradient(
            Gradient(colors: [deep, flame]), startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
        // Stepped flicker: a fuse tip sputters, it does not pulse smoothly.
        let steps: [Double] = [1, 0.72, 1.25, 0.9, 1.15, 0.8]
        let flick = steps[Int(t / 0.16) % steps.count]
        let r = 3.6 * flick
        ctx.fill(Path(ellipseIn: CGRect(x: w - r, y: above + barH / 2 - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(
                    Gradient(colors: [Color(red: 1, green: 0.99, blue: 0.90), ember.opacity(0)]),
                    center: CGPoint(x: w, y: above + barH / 2), startRadius: 0, endRadius: r))

        // A real fuse throws a shower, not four arcs. Fourteen sparks on
        // staggered lifetimes, each with its own direction and gravity.
        for i in 0..<14 {
            let life = 0.75
            let phase = (t / life + Double(i) * 0.0714).truncatingRemainder(dividingBy: 1)
            let angle = (FX.hash01(i, 11) - 0.5) * 2.4      // spread, radians
            let speed = 12 + FX.hash01(i, 4) * 22
            let x = w + cos(angle) * speed * phase
            let y = above + barH / 2 - sin(angle) * speed * phase + 30 * phase * phase
            let s = 0.8 + FX.hash01(i, 6) * 0.9
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s * 2, height: s * 2)),
                     with: .color(ember.opacity(0.95 * (1 - phase))))
        }
    }
}
