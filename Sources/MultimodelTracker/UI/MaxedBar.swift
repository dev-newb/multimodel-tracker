import SwiftUI

/// Which 100% treatment is showing. Advances every third viewing — see
/// `Store.noteMaxedViewing()`.
enum MaxedStyle: Int, CaseIterable {
    case flatline, fracture, bleed
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
    static let above = 20.0              // headroom for the EKG trace
    static let below = 21.0              // room for bleed drops to fall
    private static let canvasH = above + barH + below

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let since = context.date.timeIntervalSince(opened)
                switch style {
                case .flatline: Self.drawFlatline(ctx, size, t: t, since: since)
                case .fracture: Self.drawFracture(ctx, size, t: t)
                case .bleed:    Self.drawBleed(ctx, size, t: t)
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

        // EKG polyline in the band above the bar.
        let bandH = 16.0, bandTop = above - bandH - 2
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

    // MARK: fracture — shards sag out of true and smoothly recover, looping

    private static func drawFracture(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let shards: [(x: Double, w: Double, dy: Double, deg: Double, phase: Double)] = [
            (0.000, 0.335, 2.0, -1.4, 0.00),
            (0.345, 0.270, 3.5,  1.1, 0.45),
            (0.625, 0.375, 2.8, -0.7, 0.90),
        ]
        for s in shards {
            // Cosine oscillation: sag, hang, and recover with no snap-back.
            let osc = (1 - cos(2 * .pi * (t / 3.4 + s.phase))) / 2
            let rect = CGRect(x: s.x * size.width, y: above,
                              width: s.w * size.width, height: barH)
            var c = ctx
            c.translateBy(x: rect.midX, y: rect.midY + osc * s.dy)
            c.rotate(by: .degrees(osc * s.deg))
            c.fill(Path(roundedRect: CGRect(x: -rect.width / 2, y: -rect.height / 2,
                                            width: rect.width, height: rect.height),
                        cornerRadius: barH / 2),
                   with: .color(shardC))
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
