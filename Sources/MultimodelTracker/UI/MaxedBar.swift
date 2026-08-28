import SwiftUI

/// Which 100% treatment is showing. Advances every third viewing — see
/// `Store.noteMaxedViewing()`.
enum MaxedStyle: Int, CaseIterable {
    // Raw values are persisted in mmt.maxedFixed, so surviving cases keep
    // theirs. Fracture (1) became glitch; flatline (0) was removed outright —
    // a stored 0 no longer resolves, which effectiveMaxedStyle treats as
    // "cycle". Style arithmetic must use allCases indices, never rawValue.
    // blackHole (4) removed at Rich's request — its middle-out collapse read
    // as arbitrary; a stored maxedFixed of 4 now falls back to cycling.
    case glitch = 1, bleed = 2, deadChannel = 3
    case drown = 5, petrify = 6, neonBurnout = 7

    /// One full loop of this effect, used by the Accounts preview to show
    /// each style for three complete cycles before moving on. Petrify is
    /// static, so its "cycle" is just a sensible dwell time.
    var cycleSeconds: Double {
        switch self {
        case .glitch:      return 2.0
        case .bleed:       return 2.9
        case .deadChannel: return 2.0
        case .drown:       return 5.0
        case .petrify:     return 2.0
        case .neonBurnout: return 2.8
        }
    }

    var displayName: String {
        switch self {
        case .glitch:      return "Glitch"
        case .bleed:       return "Bleed"
        case .deadChannel: return "Dead channel"
        case .drown:       return "Drown"
        case .petrify:     return "Petrify"
        case .neonBurnout: return "Neon burnout"
        }
    }
}

/// Deterministic pseudo-randomness for the effects. These draw functions are
/// pure functions of time with no per-frame state, so `Double.random` would
/// re-roll 60 times a second and strobe. Hashing the EVENT INDEX instead gives
/// a value that is random across events but rock steady within one.
enum FX {
    static func hash01(_ a: Int, _ salt: Int = 0) -> Double {
        var z = UInt64(bitPattern: Int64(a &* 0x9E3779B9 &+ salt &* 0x85EBCA6B))
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z % 100_000) / 100_000
    }

    /// Progress through an event that recurs at a randomised interval.
    /// `slot` is the MIDPOINT of the desired range and `jitter` half its
    /// width, so gaps land in `slot ± jitter`: (4.5, 1.5) gives 3-6 seconds.
    /// Returns 0...1 while an event is running, nil otherwise. Checks the
    /// previous slot too, since an event can start late and still be playing.
    static func eventProgress(_ t: Double, slot: Double, jitter: Double,
                              duration: Double, salt: Int) -> Double? {
        let n = (t / slot).rounded(.down)
        for candidate in [n, n - 1] {
            let start = candidate * slot + hash01(Int(candidate), salt) * jitter
            let p = (t - start) / duration
            if p >= 0, p <= 1 { return p }
        }
        return nil
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

    static let barH = 5.0                // matches LimitRow's capsule height
    /// A few points of headroom so halos, rings and bubbles aren't hard-
    /// clipped at the bar's top edge — small enough that nothing reaches the
    /// label. The bar strip itself still lands exactly on the capsule slot:
    /// the row bottom-aligns this canvas and offsets by `below`, so `above`
    /// only grows the canvas upward.
    static let above = 4.0
    /// Room below for bleed drops to complete their fall instead of being
    /// cut off mid-drip (16pt fall + stretched drop needs ~22).
    static let below = 22.0
    private static let canvasH = above + barH + below

    /// When false the clock stops and a single frame is drawn. See
    /// Store.uiVisible.
    var animating = true

    /// Reset each time the view appears. Drown uses it to run its
    /// transition ONCE per opening and then hold the drowned state.
    @State private var opened = Date()

    @ViewBuilder
    var body: some View {
        // Two branches rather than one parameterised schedule: the schedule
        // types are unrelated, and more importantly a hidden view must have
        // NO timeline at all — an idle schedule still redraws.
        if animating {
            TimelineView(.animation) { context in
                canvas(at: context.date.timeIntervalSinceReferenceDate,
                       since: context.date.timeIntervalSince(opened))
            }
            .frame(height: Self.canvasH)
            .allowsHitTesting(false)
            .onAppear { opened = Date() }
        } else {
            canvas(at: 0, since: 999)
                .frame(height: Self.canvasH)
                .allowsHitTesting(false)
        }
    }

    private func canvas(at t: Double, since: Double) -> some View {
        Canvas { ctx, size in
            switch style {
            case .glitch:      Self.drawGlitch(ctx, size, t: t)
            case .bleed:       Self.drawBleed(ctx, size, t: t)
            case .deadChannel: Self.drawDeadChannel(ctx, size, t: t)
            case .drown:       Self.drawDrown(ctx, size, t: t, since: since)
            case .petrify:     Self.drawPetrify(ctx, size, t: t)
            case .neonBurnout: Self.drawNeonBurnout(ctx, size, t: t)
            }
        }
    }

    private static let red    = Color(red: 0.91, green: 0.27, blue: 0.23)
    private static let dried  = Color(red: 0.42, green: 0.17, blue: 0.16)
    private static let shardC = Color(red: 0.79, green: 0.28, blue: 0.25)

    private static func easeOut(_ p: Double) -> Double { 1 - pow(1 - min(max(p, 0), 1), 3) }

    // MARK: glitch — slices shear out of register with RGB ghosts

    private static let cyan = Color(red: 0, green: 1, blue: 0.92)
    private static let magenta = Color(red: 1, green: 0, blue: 0.5)

    /// Hot frames are ORANGE, not the red used elsewhere — with red this read
    /// as another burning effect rather than a broken one.
    private static let glitchHot = Color(red: 0.95, green: 0.52, blue: 0.12)

    private static func drawGlitch(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        var c = ctx
        let bar = CGRect(x: 0, y: above, width: size.width, height: barH)
        c.clip(to: Path(roundedRect: bar, cornerRadius: barH / 2))

        // Every 3 seconds a fresh grey share is drawn, 65-95%. Within the
        // cycle each glitch frame lands grey or orange against that share, so
        // the colour flickers unpredictably while staying mostly grey — and
        // how mostly changes every cycle.
        let cycle = (t / 3.0).rounded(.down)
        let greyShare = 0.65 + FX.hash01(Int(cycle), 31) * 0.30

        // 14 steps a second, not the display's 60: at full rate the flicker
        // blurs into an average instead of reading as distinct frames.
        let frame = Int(t * 14)
        let isGrey = FX.hash01(frame, 43) < greyShare
        let greyLevel = 0.34 + FX.hash01(frame, 19) * 0.34
        let base = isGrey ? Color(white: greyLevel) : glitchHot
        c.fill(Path(bar), with: .color(base))

        // Bursts of corruption rather than constant noise — a codec falling
        // apart comes in hits; permanent damage reads as texture.
        let burst = FX.eventProgress(t, slot: 1.6, jitter: 0.6, duration: 0.4, salt: 3)
        let severity = burst.map { sin(.pi * $0) } ?? 0.12

        // Macroblocks: quantised levels, the way a low-quality JPEG bands.
        let cell = 5.0
        let cols = Int(size.width / cell) + 1
        for col in 0..<cols {
            let r = FX.hash01(frame &+ col &* 31, 7)
            guard r < 0.10 + 0.55 * severity else { continue }
            let level = (FX.hash01(frame &+ col &* 57, 9) * 4).rounded(.down) / 4
            // Blocks follow the frame's own family, so an orange frame does
            // not sprout grey confetti and vice versa.
            let blockColour = isGrey
                ? Color(white: 0.18 + level * 0.62)
                : Color(red: 0.55 + 0.45 * level, green: 0.25 + 0.35 * level, blue: 0.08)
            let dy = severity > 0.3 ? (FX.hash01(frame &+ col, 13) - 0.5) * 2 : 0
            c.fill(Path(CGRect(x: Double(col) * cell, y: above + dy,
                               width: cell, height: barH)),
                   with: .color(blockColour))
        }

        // Slices tear horizontally, at full bar height so nothing floats out
        // of the row.
        let slices: [(x: Double, w: Double, period: Double)] = [
            (0.00, 0.30, 0.9), (0.30, 0.45, 1.1), (0.75, 0.25, 0.7),
        ]
        for (i, sl) in slices.enumerated() {
            let step = Int(t / sl.period * 4) &+ i * 7
            let offsets: [Double] = [0, 3, -2, 0, -4, 2, 0, 1]
            let dx = offsets[abs(step) % offsets.count] * (0.5 + severity)
            let rect = CGRect(x: sl.x * size.width + dx, y: above,
                              width: sl.w * size.width, height: barH)
            // Chroma fringes stay cyan/magenta whatever the base: channel
            // separation is the glitch signature, and neither is warm.
            let fringe = 1.5 + 2.5 * severity
            c.fill(Path(rect.offsetBy(dx: fringe, dy: 0)), with: .color(cyan.opacity(0.35)))
            c.fill(Path(rect.offsetBy(dx: -fringe, dy: 0)), with: .color(magenta.opacity(0.35)))
            c.fill(Path(rect), with: .color(base.opacity(0.85)))
        }

        // At the peak of a burst the whole bar drops resolution.
        if severity > 0.6 {
            let big = 11.0
            let n = Int(size.width / big) + 1
            for i in 0..<n {
                let v = FX.hash01(frame &+ i &* 97, 21)
                let chunk = isGrey
                    ? Color(white: 0.22 + v * 0.55)
                    : Color(red: 0.7 + 0.3 * v, green: 0.35 + 0.3 * v, blue: 0.1)
                c.fill(Path(CGRect(x: Double(i) * big, y: above, width: big, height: barH)),
                       with: .color(chunk.opacity(0.8)))
            }
        }
    }

    // MARK: drown — a dark waterline rises over the bar, bubbles escape

    private static func drawDrown(_ ctx: GraphicsContext, _ size: CGSize,
                                  t: Double, since: Double) {
        // The sinking plays ONCE per opening and then holds. Looping it made
        // the bar bob in and out of the water, which read as indecision
        // rather than drowning.
        let submerge = min(1, easeOut(since / 2.2))
        let bar = CGRect(x: 0, y: above + submerge * 2, width: size.width, height: barH)
        ctx.fill(Path(roundedRect: bar, cornerRadius: barH / 2),
                 with: .color(Color(red: 0.76 - 0.34 * submerge,
                                    green: 0.27 - 0.08 * submerge,
                                    blue: 0.23 + 0.10 * submerge)))
        var c = ctx
        c.clip(to: Path(roundedRect: CGRect(x: 0, y: above, width: size.width, height: barH),
                        cornerRadius: barH / 2))
        // Water fills from the bottom as it goes under, then stays.
        let h = barH * submerge
        c.fill(Path(CGRect(x: 0, y: above + barH - h, width: size.width, height: h)),
               with: .color(Color(red: 0.08, green: 0.16, blue: 0.28).opacity(0.85)))
        // A faint surface ripple keeps the drowned state alive without
        // resurfacing the bar.
        if submerge >= 1 {
            let wob = sin(2 * .pi * t / 2.4) * 0.6
            c.fill(Path(CGRect(x: 0, y: above + wob, width: size.width, height: 1.1)),
                   with: .color(Color(red: 0.45, green: 0.66, blue: 0.9).opacity(0.35)))
        }
        // Bubbles escape continuously once it is under.
        guard submerge > 0.35 else { return }
        for (i, x) in [0.18, 0.36, 0.54, 0.72, 0.88].enumerated() {
            let bp = (t / 3.2 + Double(i) * 0.2 + FX.hash01(i, 23) * 0.3)
                .truncatingRemainder(dividingBy: 1)
            let e = bp
            let y = above + barH - 1 - 11 * e
            let r = 0.9 + FX.hash01(i, 31) * 0.8
            ctx.stroke(Path(ellipseIn: CGRect(x: x * size.width + sin(e * 6) * 1.5,
                                              y: y, width: r * 2, height: r * 2)),
                       with: .color(Color(red: 0.63, green: 0.78, blue: 1)
                                        .opacity(0.5 * (1 - e) * submerge)),
                       lineWidth: 0.8)
        }
    }

    // MARK: petrify — colour drains to stone and cracks spider through

    private static func drawPetrify(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let bar = CGRect(x: 0, y: above, width: size.width, height: barH)
        var c = ctx
        c.clip(to: Path(roundedRect: bar, cornerRadius: barH / 2))
        c.fill(Path(bar), with: .color(Color(white: 0.46)))

        // Irregular facets rather than three identical strokes — the repeat
        // read as a printed pattern instead of stone. Each facet gets its own
        // width, tilt and shade from the hash, so no two look alike and the
        // seams between them land at random depths.
        var x = 0.0
        var i = 0
        while x < size.width {
            let fw = 7 + FX.hash01(i, 71) * 16
            let shade = 0.30 + FX.hash01(i, 83) * 0.34
            let tilt = (FX.hash01(i, 97) - 0.5) * 2.2
            var facet = Path()
            facet.move(to: CGPoint(x: x, y: above - 1))
            facet.addLine(to: CGPoint(x: x + fw, y: above - 1 + tilt))
            facet.addLine(to: CGPoint(x: x + fw + tilt, y: above + barH + 1))
            facet.addLine(to: CGPoint(x: x - tilt, y: above + barH + 1))
            facet.closeSubpath()
            c.fill(facet, with: .color(Color(white: shade)))
            // A bright chip along the top edge gives each facet an angle.
            if FX.hash01(i, 101) > 0.45 {
                var chip = Path()
                chip.move(to: CGPoint(x: x + 1, y: above))
                chip.addLine(to: CGPoint(x: x + fw * 0.7, y: above))
                chip.addLine(to: CGPoint(x: x + fw * 0.45, y: above + barH * 0.45))
                chip.closeSubpath()
                c.fill(chip, with: .color(Color(white: min(0.95, shade + 0.26)).opacity(0.7)))
            }
            // Dark fissure at the seam.
            c.stroke(Path { p in
                p.move(to: CGPoint(x: x, y: above - 1))
                p.addLine(to: CGPoint(x: x - tilt, y: above + barH + 1))
            }, with: .color(.black.opacity(0.5)), lineWidth: 0.8)
            x += fw
            i += 1
        }

        // Shimmer: a soft highlight crossing the stone every 3-6 seconds, the
        // only motion this effect has.
        if let p = FX.eventProgress(t, slot: 4.5, jitter: 1.5, duration: 0.75, salt: 17) {
            let bandW = size.width * 0.26
            let bx = -bandW + (size.width + bandW * 2) * p
            let peak = sin(.pi * p)
            c.fill(Path(CGRect(x: bx, y: above - 1, width: bandW, height: barH + 2)),
                   with: .linearGradient(
                        Gradient(colors: [.white.opacity(0),
                                          .white.opacity(0.6 * peak),
                                          .white.opacity(0)]),
                        startPoint: CGPoint(x: bx, y: 0),
                        endPoint: CGPoint(x: bx + bandW, y: 0)))
        }
    }

    // MARK: neon burnout — a tube that can't hold its light

    private static func drawNeonBurnout(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let bar = CGRect(x: 0, y: above, width: size.width, height: barH)
        ctx.fill(Path(roundedRect: bar, cornerRadius: barH / 2),
                 with: .color(Color(red: 0.24, green: 0.11, blue: 0.10)))

        // Baseline: stepped, irregular. A smooth sine reads as a deliberate
        // pulse rather than a tube that cannot hold its light.
        let steps: [Double] = [1, 0.2, 1, 0.35, 0.95, 0.95, 0.15, 0.85,
                               0.85, 0.1, 0.7, 0.7, 0.05, 0.6, 1, 1]
        var lit = steps[Int(t / 0.175) % steps.count]

        // Every 8-16s, a run of very fast strobing, then back to normal.
        if FX.eventProgress(t, slot: 12, jitter: 4, duration: 0.7, salt: 41) != nil {
            lit = FX.hash01(Int(t * 40), 5) < 0.45 ? 0.05 : 1.0
        }

        // Rarely — 60-180s apart — it surges brighter than it ever runs and
        // blooms, for a third of a second.
        var bloom = 0.0
        if let p = FX.eventProgress(t, slot: 120, jitter: 60, duration: 0.35, salt: 77) {
            bloom = sin(.pi * p)
            lit = max(lit, 0.9 + 0.1 * bloom)
        }

        guard lit > 0.08 else { return }
        // Halo first so the tube core stays crisp on top.
        if bloom > 0 {
            ctx.fill(Path(roundedRect: bar.insetBy(dx: -7 * bloom, dy: -7 * bloom),
                          cornerRadius: barH),
                     with: .color(red.opacity(0.22 * bloom)))
        }
        ctx.fill(Path(roundedRect: bar.insetBy(dx: -2.5, dy: -2.5), cornerRadius: barH),
                 with: .color(red.opacity((0.20 + 0.25 * bloom) * lit)))
        ctx.fill(Path(roundedRect: bar.insetBy(dx: -1, dy: -1), cornerRadius: barH),
                 with: .color(red.opacity((0.30 + 0.3 * bloom) * lit)))
        let core = bloom > 0
            ? Color(red: 1, green: 0.55 + 0.35 * bloom, blue: 0.45 + 0.4 * bloom)
            : red
        ctx.fill(Path(roundedRect: bar, cornerRadius: barH / 2), with: .color(core.opacity(lit)))
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
        // Grey and crinkled, not orange — as red it was one more warm bar in
        // a set that already has several, and it read as fire rather than as
        // something leaking out.
        let bar = CGRect(x: 0, y: above, width: size.width, height: barH)
        var c = ctx
        c.clip(to: Path(roundedRect: bar, cornerRadius: barH / 2))
        c.fill(Path(bar), with: .color(Color(white: 0.42)))

        // Crinkle: uneven vertical creases and shading, like foil that has
        // been crushed. Static, so the motion is entirely in the drips.
        var x = 0.0
        var i = 0
        while x < size.width {
            let cw = 3 + FX.hash01(i, 131) * 7
            let shade = 0.30 + FX.hash01(i, 137) * 0.30
            c.fill(Path(CGRect(x: x, y: above, width: cw, height: barH)),
                   with: .linearGradient(
                        Gradient(colors: [Color(white: shade),
                                          Color(white: min(0.86, shade + 0.24)),
                                          Color(white: shade * 0.8)]),
                        startPoint: CGPoint(x: x, y: above),
                        endPoint: CGPoint(x: x + cw, y: above + barH)))
            // A hard crease line at each fold.
            c.stroke(Path { p in
                p.move(to: CGPoint(x: x, y: above))
                p.addLine(to: CGPoint(x: x + (FX.hash01(i, 149) - 0.5) * 2, y: above + barH))
            }, with: .color(.black.opacity(0.42)), lineWidth: 0.7)
            x += cw
            i += 1
        }

        // Drips leaving the underside, grey to match.
        let drops: [(x: Double, phase: Double)] = [(0.22, 0), (0.55, 0.33), (0.81, 0.59)]
        for d in drops {
            let p = (t / 2.9 + d.phase).truncatingRemainder(dividingBy: 1)
            let y = above + barH - 1 + 16 * p * p          // ease-in fall
            let stretch = 1 + 1.4 * p * (1 - p) * 4        // longest mid-fall
            let drop = CGRect(x: d.x * size.width - 1.5, y: y, width: 3, height: 4 * stretch)
            ctx.fill(Path(roundedRect: drop, cornerRadius: 1.5),
                     with: .color(Color(white: 0.55).opacity(0.9 * (1 - p))))
        }
    }
}
