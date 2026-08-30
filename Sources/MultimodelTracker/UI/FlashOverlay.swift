import SwiftUI
import AppKit

/// The menu-bar alert flashes: when an alert fires, the badge numbers fade
/// out, an animated word ("Reset!", "Banked Rst!", "On Fire!") plays for
/// exactly as long as the alert sound, and the badge fades back.
///
/// Every style is drawn with SwiftUI's GraphicsContext, ONCE — the Config
/// previews draw it live in a Canvas, and the status item rasterises the
/// same painter into per-frame NSImages via ImageRenderer. Particles are
/// deterministic functions of time (seeded lanes, no mutable state), which
/// is what lets one painter serve both paths and stay resumable.
enum FlashEvent: String, CaseIterable, Identifiable {
    case reset, banked, burn, limit
    var id: String { rawValue }

    var text: String {
        switch self {
        case .reset:  return "Reset!"
        case .banked: return "Banked Rst!"
        case .burn:   return "On Fire!"
        case .limit:  return "Usage limit!"
        }
    }
    /// Matches the sound rows' wording — reset/banked are Codex-only events.
    var displayName: String {
        switch self {
        case .reset:  return "Limit reset early (Codex)"
        case .banked: return "Banked reset added (Codex)"
        case .burn:   return "Burning tokens"
        case .limit:  return "Usage limit reached"
        }
    }
    var soundKind: SoundKind {
        switch self {
        case .reset: return .reset
        case .banked: return .banked
        case .burn: return .burn
        case .limit: return .limit
        }
    }
    /// Approved in the Flash Lab; order is the gallery's order. The limit
    /// styles are variations on the sound: a fist meeting a rock wall.
    var styleNames: [String] {
        switch self {
        case .reset:  return ["Skyroll", "Cloud Drift", "Heaven Rays", "Ascension"]
        case .banked: return ["Bill Sheen", "Coin Flip", "Money Rain", "Vault Fill"]
        case .burn:   return ["Ember Rise", "Ignition", "Flame Lick", "Coalglow"]
        case .limit:  return ["Slam", "Crackline", "Rubble", "Quake"]
        }
    }
    static let styleCount = 4
}

// MARK: - palette

struct FlashPalette {
    let from: Color, to: Color          // body gradient ends
    let glow: Color
    let extra: Color                    // clouds / sheen / gold / unlit, per event
    let core: Color, mid: Color, edge: Color   // fire ramp

    static func palette(_ event: FlashEvent, darkBar: Bool) -> FlashPalette {
        func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
            Color(red: r / 255, green: g / 255, blue: b / 255, opacity: a)
        }
        switch (event, darkBar) {
        case (.reset, true):
            return .init(from: c(125,199,245), to: c(46,90,214), glow: c(120,190,255,0.85),
                         extra: c(255,255,255,0.5), core: c(225,240,255), mid: c(125,199,245), edge: c(46,90,214))
        case (.reset, false):
            return .init(from: c(58,142,220), to: c(22,52,150), glow: c(90,150,235,0.55),
                         extra: c(255,255,255,0.75), core: c(235,244,255), mid: c(58,142,220), edge: c(22,52,150))
        case (.banked, true):
            return .init(from: c(138,224,167), to: c(24,138,76), glow: c(90,220,140,0.7),
                         extra: c(212,177,74), core: c(230,255,235), mid: c(138,224,167), edge: c(24,138,76))
        case (.banked, false):
            return .init(from: c(42,150,88), to: c(13,92,49), glow: c(40,160,90,0.45),
                         extra: c(163,126,32), core: c(255,255,255), mid: c(42,150,88), edge: c(13,92,49))
        case (.burn, true):
            return .init(from: c(255,224,120), to: c(206,44,18), glow: c(255,120,30,0.8),
                         extra: c(96,88,82), core: c(255,224,120), mid: c(255,122,26), edge: c(206,44,18))
        case (.burn, false):
            return .init(from: c(235,150,10), to: c(168,28,10), glow: c(255,120,30,0.5),
                         extra: c(168,160,152), core: c(235,150,10), mid: c(222,84,16), edge: c(168,28,10))
        // Stone: light face → shadowed base; extra = dust, core/mid = the
        // bright and amber of a fresh crack, edge = deep rock shadow.
        case (.limit, true):
            return .init(from: c(201,196,188), to: c(110,103,94), glow: c(214,196,168,0.55),
                         extra: c(214,196,168), core: c(255,244,214), mid: c(255,184,77), edge: c(74,66,58))
        case (.limit, false):
            return .init(from: c(124,116,106), to: c(62,56,49), glow: c(160,140,110,0.5),
                         extra: c(164,144,114), core: c(255,238,200), mid: c(196,120,20), edge: c(46,40,34))
        }
    }
}

private func mixColor(_ a: Color, _ b: Color, _ t: Double) -> Color {
    let ca = NSColor(a).usingColorSpace(.sRGB)!, cb = NSColor(b).usingColorSpace(.sRGB)!
    let u = CGFloat(min(max(t, 0), 1))
    return Color(red: ca.redComponent + (cb.redComponent - ca.redComponent) * u,
                 green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * u,
                 blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * u)
}

/// Deterministic pseudo-random in 0..<1 — shader-style sin hash. The same
/// seeds always give the same value, so "particles" are pure functions of
/// time and two independent renderers draw identical frames.
private func prand(_ a: Double, _ b: Double = 0, _ c: Double = 0) -> Double {
    abs(sin(a * 12.9898 + b * 78.233 + c * 37.719) * 43758.5453)
        .truncatingRemainder(dividingBy: 1)
}

// MARK: - the painters

/// Everything a painter needs. Coordinates: the text's midline is y = 0,
/// its left edge x = 0; `charX`/`charW` are per-character metrics.
struct FlashEnv {
    var t: Double                 // seconds since the flash began
    var k: Double                 // crossfade 0...1 (1 = effect fully on)
    var fontSize: Double
    var scale: Double             // 1 = menu bar; previews run larger
    var textWidth: Double
    var chars: [String]
    var charX: [Double]
    var charW: [Double]
    var pal: FlashPalette
}

enum FlashPaint {
    static func paint(_ ctx: inout GraphicsContext, event: FlashEvent, style: Int, env: FlashEnv) {
        switch (event, style) {
        case (.reset, 0):  skyroll(&ctx, env)
        case (.reset, 1):  drift(&ctx, env)
        case (.reset, 2):  rays(&ctx, env)
        case (.reset, _):  ascend(&ctx, env)
        case (.banked, 0): sheen(&ctx, env)
        case (.banked, 1): coinflip(&ctx, env)
        case (.banked, 2): rain(&ctx, env)
        case (.banked, _): vault(&ctx, env)
        case (.burn, 0):   embers(&ctx, env)
        case (.burn, 1):   ignite(&ctx, env)
        case (.burn, 2):   flare(&ctx, env)
        case (.burn, _):   coals(&ctx, env)
        case (.limit, 0):  slam(&ctx, env)
        case (.limit, 1):  crackline(&ctx, env)
        case (.limit, 2):  rubble(&ctx, env)
        case (.limit, _):  quake(&ctx, env)
        }
    }

    private static func charText(_ s: String, _ env: FlashEnv, _ style: some ShapeStyle) -> Text {
        Text(s).font(.system(size: env.fontSize, weight: .bold)).foregroundStyle(style)
    }

    /// Draws every character, colouring each via `style(i)`, offset via `dy(i)`.
    private static func drawWord(_ ctx: inout GraphicsContext, _ env: FlashEnv,
                                 style: (Int) -> AnyShapeStyle, dy: (Int) -> Double = { _ in 0 }) {
        for i in env.chars.indices {
            let t = charText(env.chars[i], env, style(i))
            ctx.draw(ctx.resolve(t), at: CGPoint(x: env.charX[i], y: dy(i)), anchor: .leading)
        }
    }

    private static func verticalRamp(_ top: Color, _ bottom: Color) -> AnyShapeStyle {
        AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
    }

    // ---- reset ----

    private static func skyroll(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: p.glow, radius: 6 * env.scale))
            var l = layer
            // Rolling gradient, sampled per character at its centre.
            drawWord(&l, env, style: { i in
                let u = 0.5 + 0.5 * sin(env.t * 1.6 - Double(i) * 0.55)
                return AnyShapeStyle(mixColor(p.from, p.to, u))
            }, dy: { i in sin(env.t * 1.3 + Double(i)) * 0.6 * env.scale })
            // Clouds drift THROUGH the glyphs.
            l.blendMode = .sourceAtop
            for b in 0..<3 {
                let bx = ((env.t * (10 + Double(b) * 6) * env.scale)
                          + Double(b) * env.textWidth / 2.6)
                    .truncatingRemainder(dividingBy: env.textWidth * 1.3) - env.textWidth * 0.15
                let r = env.fontSize * 0.9
                l.fill(Path(ellipseIn: CGRect(x: bx - r, y: -r, width: r * 2, height: r * 2)),
                       with: .radialGradient(Gradient(colors: [p.extra, p.extra.opacity(0)]),
                                             center: CGPoint(x: bx, y: 0), startRadius: 0, endRadius: r))
            }
        }
    }

    private static func drift(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: p.glow, radius: 4 * env.scale))
            var l = layer
            drawWord(&l, env, style: { _ in verticalRamp(mixColor(p.from, p.to, 0.1), mixColor(p.from, p.to, 0.9)) },
                     dy: { i in sin(env.t * 0.8 + Double(i) * 0.35) * 0.5 * env.scale })
            l.blendMode = .sourceAtop
            for b in 0..<3 {
                let speed = (b % 2 == 1 ? -1.0 : 1.0) * (6 + Double(b) * 5) * env.scale
                let span = env.textWidth * 1.4
                let bx = (((env.t * speed).truncatingRemainder(dividingBy: span)) + span)
                    .truncatingRemainder(dividingBy: span) - env.textWidth * 0.2
                let puls = 0.28 + 0.16 * sin(env.t * 0.9 + Double(b) * 2.1)
                let w = env.fontSize * 1.2
                l.fill(Path(CGRect(x: bx - w, y: -env.fontSize, width: w * 2, height: env.fontSize * 2)),
                       with: .linearGradient(Gradient(stops: [
                            .init(color: .white.opacity(0), location: 0),
                            .init(color: .white.opacity(puls), location: 0.5),
                            .init(color: .white.opacity(0), location: 1)]),
                          startPoint: CGPoint(x: bx - w, y: 0), endPoint: CGPoint(x: bx + w, y: 0)))
            }
        }
    }

    private static func rays(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        let breathe = 0.5 + 0.5 * sin(env.t * 0.7)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: p.glow, radius: (4 + 3 * breathe) * env.scale))
            var l = layer
            drawWord(&l, env, style: { _ in
                verticalRamp(mixColor(p.from, p.to, 0.15 + 0.2 * breathe), mixColor(p.from, p.to, 0.95)) })
            l.blendMode = .sourceAtop
            for r in 0..<2 {
                let span = env.textWidth * 1.6
                let rx = ((env.t * (16 + Double(r) * 9) * env.scale).truncatingRemainder(dividingBy: span))
                    - env.textWidth * 0.3 + Double(r) * env.textWidth * 0.5
                var band = l
                band.translateBy(x: rx, y: 0)
                band.rotate(by: .radians(-0.45))
                let w = 8 * env.scale
                band.fill(Path(CGRect(x: -w, y: -env.fontSize * 1.6, width: w * 2, height: env.fontSize * 3.2)),
                          with: .linearGradient(Gradient(stops: [
                                .init(color: .white.opacity(0), location: 0),
                                .init(color: Color(red: 1, green: 1, blue: 0.94).opacity(0.75), location: 0.5),
                                .init(color: .white.opacity(0), location: 1)]),
                             startPoint: CGPoint(x: -w, y: 0), endPoint: CGPoint(x: w, y: 0)))
            }
        }
    }

    private static func ascend(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: p.glow, radius: 5 * env.scale))
            var l = layer
            drawWord(&l, env, style: { _ in
                AnyShapeStyle(LinearGradient(stops: [
                    .init(color: p.core, location: 0),
                    .init(color: mixColor(p.from, p.to, 0.35), location: 0.45),
                    .init(color: p.to, location: 1)], startPoint: .top, endPoint: .bottom))
            }, dy: { i in sin(env.t * 1.1 + Double(i) * 0.5) * 1.2 * env.scale - 0.6 * env.scale })
        }
        // Twinkles: 7 deterministic lanes, each a little plus-shaped star.
        for lane in 0..<7 {
            let life = 0.9 + prand(Double(lane), 1) * 0.8
            let cycle = (env.t / life + prand(Double(lane), 2)).rounded(.down)
            let age = (env.t / life + prand(Double(lane), 2)) - cycle
            guard prand(Double(lane), cycle, 3) < 0.55 else { continue }
            let a = sin(age * .pi) * 0.9 * env.k
            let x = prand(Double(lane), cycle, 4) * env.textWidth
            let y = (prand(Double(lane), cycle, 5) - 0.5) * env.fontSize * 1.5
            let r = (0.8 + prand(Double(lane), cycle, 6) * 0.9) * env.scale
            var star = Path()
            star.move(to: CGPoint(x: x - r * 1.6, y: y)); star.addLine(to: CGPoint(x: x + r * 1.6, y: y))
            star.move(to: CGPoint(x: x, y: y - r * 1.6)); star.addLine(to: CGPoint(x: x, y: y + r * 1.6))
            ctx.stroke(star, with: .color(Color(red: 0.92, green: 0.96, blue: 1).opacity(a)),
                       lineWidth: 1 * env.scale)
        }
    }

    // ---- banked ----

    private static func sheen(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: p.glow, radius: 5 * env.scale))
            var l = layer
            drawWord(&l, env, style: { _ in verticalRamp(mixColor(p.from, p.to, 0.15), mixColor(p.from, p.to, 0.95)) })
            l.blendMode = .sourceAtop
            let sxp = ((env.t * 0.9).truncatingRemainder(dividingBy: 1.7)) * env.textWidth * 1.5
                - env.textWidth * 0.25
            let w = 9 * env.scale
            l.fill(Path(CGRect(x: sxp - w, y: -env.fontSize, width: w * 2, height: env.fontSize * 2)),
                   with: .linearGradient(Gradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: p.core.opacity(0.85), location: 0.5),
                        .init(color: .white.opacity(0), location: 1)]),
                      startPoint: CGPoint(x: sxp - w, y: 0), endPoint: CGPoint(x: sxp + w, y: 0)))
        }
    }

    private static func coinflip(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: p.glow, radius: 3 * env.scale))
            for i in env.chars.indices {
                let spin = cos(env.t * 2.6 + Double(i) * 0.65)
                let face = spin >= 0
                let style: AnyShapeStyle = face
                    ? verticalRamp(mixColor(p.from, p.to, 0.1), mixColor(p.from, p.to, 0.95))
                    : verticalRamp(mixColor(p.extra, Color(red: 1, green: 0.93, blue: 0.67), 0.35),
                                   mixColor(p.extra, Color(red: 0.35, green: 0.26, blue: 0.04), 0.5))
                var l = layer
                l.translateBy(x: env.charX[i] + env.charW[i] / 2, y: 0)
                l.scaleBy(x: max(abs(spin), 0.14), y: 1)
                let t = charText(env.chars[i], env, style)
                l.draw(l.resolve(t), at: CGPoint(x: -env.charW[i] / 2, y: 0), anchor: .leading)
            }
        }
    }

    private static func rain(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        // Falling glyphs behind the word: 12 deterministic lanes.
        for lane in 0..<12 {
            let life = 0.9 + prand(Double(lane), 11) * 0.7
            let pos = env.t / life + prand(Double(lane), 12)
            let cycle = pos.rounded(.down), age = pos - cycle
            guard prand(Double(lane), cycle, 13) < 0.8 else { continue }
            let x = prand(Double(lane), cycle, 14) * env.textWidth
            let y = -env.fontSize * 0.9 + age * env.fontSize * 1.9
            let a = (0.55 + prand(Double(lane), cycle, 15) * 0.25) * env.k
            let s = env.fontSize * (0.4 + prand(Double(lane), cycle, 16) * 0.25)
            let g = prand(Double(lane), cycle, 17) < 0.75 ? "$" : "¢"
            let t = Text(g).font(.system(size: s, weight: .bold, design: .monospaced))
                .foregroundStyle(p.from.opacity(a))
            ctx.draw(ctx.resolve(t), at: CGPoint(x: x, y: y), anchor: .center)
        }
        let pulse = 0.5 + 0.5 * sin(env.t * 2.2)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: p.glow, radius: (3 + 3 * pulse) * env.scale))
            var l = layer
            drawWord(&l, env, style: { _ in
                verticalRamp(mixColor(p.from, p.to, 0.1 + 0.15 * pulse), p.to) })
        }
    }

    private static func vault(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        let level = min(env.t / 2, 1)          // fill once, stay full
        ctx.drawLayer { layer in
            var l = layer
            // Dark, empty vault text.
            drawWord(&l, env, style: { _ in
                verticalRamp(mixColor(p.to, Color(red: 0.04, green: 0.16, blue: 0.09), 0.55),
                             mixColor(p.to, Color(red: 0.02, green: 0.10, blue: 0.06), 0.7)) })
            l.blendMode = .sourceAtop
            // Liquid money, rising with a rippling surface.
            let top = env.fontSize * 0.62 - level * env.fontSize * 1.24
            var liquid = Path()
            liquid.move(to: CGPoint(x: 0, y: env.fontSize))
            liquid.addLine(to: CGPoint(x: 0, y: top))
            var x = 0.0
            while x <= env.textWidth {
                liquid.addLine(to: CGPoint(x: x, y: top + sin(env.t * 5 + x / (7 * env.scale)) * 1.1 * env.scale))
                x += 4 * env.scale
            }
            liquid.addLine(to: CGPoint(x: env.textWidth, y: env.fontSize))
            liquid.closeSubpath()
            l.fill(liquid, with: .linearGradient(
                Gradient(colors: [mixColor(p.from, p.to, 0.15), mixColor(p.from, p.to, 0.9)]),
                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: env.fontSize * 0.62)))
            // Full: only the gold glint repeats, ping-ponging so each pass
            // resumes where the last one ended.
            if level >= 1 {
                let u = ((env.t - 2) * 0.55).truncatingRemainder(dividingBy: 2)
                let pos = u < 1 ? u : 2 - u
                let gx = pos * env.textWidth * 1.3 - env.textWidth * 0.15
                let w = 8 * env.scale
                l.fill(Path(CGRect(x: gx - w, y: -env.fontSize, width: w * 2, height: env.fontSize * 2)),
                       with: .linearGradient(Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color(red: 1, green: 0.94, blue: 0.71).opacity(0.9), location: 0.5),
                            .init(color: .clear, location: 1)]),
                          startPoint: CGPoint(x: gx - w, y: 0), endPoint: CGPoint(x: gx + w, y: 0)))
            }
        }
    }

    // ---- burn ----

    private static func embers(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            for i in env.chars.indices {
                let flick = 0.75 + 0.25 * sin(env.t * 12 + Double(i) * 2.3) * sin(env.t * 19 + Double(i) * 5.1)
                var l = layer
                l.addFilter(.shadow(color: p.glow, radius: (5 + 3 * flick) * env.scale))
                l.opacity = 0.82 + 0.18 * flick
                let style = AnyShapeStyle(LinearGradient(stops: [
                    .init(color: mixColor(p.mid, p.edge, 0.85), location: 0),
                    .init(color: mixColor(p.mid, p.core, flick * 0.4), location: 0.45),
                    .init(color: mixColor(p.core, p.mid, 0.1), location: 1)],
                    startPoint: .top, endPoint: .bottom))
                let t = charText(env.chars[i], env, style)
                l.draw(l.resolve(t), at: CGPoint(x: env.charX[i],
                                                 y: sin(env.t * 14 + Double(i) * 3.1) * 1.1 * env.scale),
                       anchor: .leading)
            }
        }
        // Rising embers: 3 lanes per character.
        for i in env.chars.indices where env.chars[i] != " " {
            for lane in 0..<3 {
                let seed = Double(i) * 10 + Double(lane)
                let life = 0.7 + prand(seed, 21) * 0.5
                let pos = env.t / life + prand(seed, 22)
                let cycle = pos.rounded(.down), age = pos - cycle
                guard prand(seed, cycle, 23) < 0.5 else { continue }
                let x0 = env.charX[i] + env.charW[i] * (0.2 + prand(seed, cycle, 24) * 0.6)
                let drift = (prand(seed, cycle, 25) - 0.5) * 8 * env.scale
                let x = x0 + drift * age + sin(env.t * 9 + seed) * 0.5 * env.scale
                // Travel in font units — the menu bar clips at its top edge,
                // exactly like the real one, so embers die within the bar.
                let y = -env.fontSize * 0.55 - age * env.fontSize * (0.3 + prand(seed, cycle, 26) * 0.3)
                let a = (1 - age) * 0.9 * env.k
                let col = age < 0.5 ? mixColor(p.core, p.mid, age * 2) : mixColor(p.mid, p.edge, (age - 0.5) * 2)
                let r = (0.5 + prand(seed, cycle, 27) * 0.7) * env.scale
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(col.opacity(a)))
            }
        }
    }

    private static func ignite(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        let front = ((env.t * 0.5).truncatingRemainder(dividingBy: 1.5)) * env.textWidth * 1.3
            - env.textWidth * 0.15
        ctx.drawLayer { layer in
            for i in env.chars.indices {
                let cx = env.charX[i] + env.charW[i] / 2
                var l = layer
                if cx > front + 8 * env.scale {                      // unburnt
                    let t = charText(env.chars[i], env, AnyShapeStyle(mixColor(p.extra, p.edge, 0.12)))
                    l.draw(l.resolve(t), at: CGPoint(x: env.charX[i], y: 0), anchor: .leading)
                } else if cx > front - 6 * env.scale {               // white-hot front
                    l.addFilter(.shadow(color: Color(red: 1, green: 0.94, blue: 0.75).opacity(0.95),
                                        radius: 9 * env.scale))
                    let t = charText(env.chars[i], env,
                                     AnyShapeStyle(Color(red: 1, green: 0.96, blue: 0.85)))
                    l.draw(l.resolve(t), at: CGPoint(x: env.charX[i], y: 0), anchor: .leading)
                } else {                                             // burning behind it
                    let flick = 0.7 + 0.3 * sin(env.t * 13 + Double(i) * 2.9)
                    l.addFilter(.shadow(color: p.glow, radius: (4 + 3 * flick) * env.scale))
                    let style = AnyShapeStyle(LinearGradient(colors: [
                        mixColor(p.mid, p.edge, 0.8), mixColor(p.core, p.mid, 0.15)],
                        startPoint: .top, endPoint: .bottom))
                    let t = charText(env.chars[i], env, style)
                    l.draw(l.resolve(t), at: CGPoint(x: env.charX[i],
                                                     y: sin(env.t * 12 + Double(i) * 3.3) * 0.9 * env.scale),
                           anchor: .leading)
                }
            }
        }
    }

    private static func flare(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            for i in env.chars.indices {
                let flick = 0.7 + 0.3 * sin(env.t * 10 + Double(i) * 2.1)
                var l = layer
                l.addFilter(.shadow(color: p.glow, radius: (5 + 4 * flick) * env.scale))
                let style = AnyShapeStyle(LinearGradient(stops: [
                    .init(color: mixColor(p.mid, p.edge, 0.6), location: 0),
                    .init(color: mixColor(p.core, p.mid, 0.7), location: 0.4),
                    .init(color: mixColor(p.core, Color(red: 1, green: 0.96, blue: 0.82), 0.5), location: 1)],
                    startPoint: .top, endPoint: .bottom))
                let t = charText(env.chars[i], env, style)
                l.draw(l.resolve(t), at: CGPoint(x: env.charX[i], y: 0), anchor: .leading)
            }
        }
        // Dense particle fire growing out of the letter tops — additive, no
        // hard baseline; flecks cool core→mid→edge as they rise.
        ctx.drawLayer { layer in
            var l = layer
            l.blendMode = .plusLighter
            for i in env.chars.indices where env.chars[i] != " " {
                for lane in 0..<6 {
                    let seed = Double(i) * 17 + Double(lane)
                    let life = 0.4 + prand(seed, 31) * 0.35
                    let pos = env.t / life + prand(seed, 32)
                    let cycle = pos.rounded(.down), age = pos - cycle
                    guard prand(seed, cycle, 33) < 0.6 else { continue }
                    let x0 = env.charX[i] + env.charW[i] * (0.15 + prand(seed, cycle, 34) * 0.7)
                    let x = x0 + (prand(seed, cycle, 35) - 0.5) * 5 * env.scale * age
                        + sin(env.t * 8 + seed) * 0.3 * env.scale
                    let y = -env.fontSize * (0.45 + prand(seed, cycle, 37) * 0.2)
                        - age * env.fontSize * (0.3 + prand(seed, cycle, 36) * 0.25) * (1 - age * 0.35)
                    let fade = (1 - age) * (1 - age)
                    let col = age < 0.3 ? mixColor(p.core, p.mid, age / 0.3)
                                        : mixColor(p.mid, p.edge, (age - 0.3) / 0.7)
                    let r = (0.6 + prand(seed, cycle, 38) * 0.7) * env.scale * (1 - age * 0.55)
                    l.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                           with: .color(col.opacity(fade * 0.55 * env.k)))
                }
            }
        }
    }

    private static func coals(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            for i in env.chars.indices {
                let pulse = 0.5 + 0.5 * sin(env.t * 1.4 + Double(i) * 2.7)
                var l = layer
                l.addFilter(.shadow(color: p.glow, radius: (1.5 + 6 * pulse) * env.scale))
                let style = AnyShapeStyle(LinearGradient(colors: [
                    mixColor(Color(red: 0.23, green: 0.10, blue: 0.07), p.edge, 0.3 + 0.4 * pulse),
                    mixColor(p.edge, p.mid, 0.25 + 0.65 * pulse)],
                    startPoint: .top, endPoint: .bottom))
                let t = charText(env.chars[i], env, style)
                l.draw(l.resolve(t), at: CGPoint(x: env.charX[i], y: 0), anchor: .leading)
            }
        }
        // Rare spark pops.
        for lane in 0..<2 {
            let period = 2.2 + prand(Double(lane), 41) * 1.4
            let pos = env.t / period + prand(Double(lane), 42)
            let cycle = pos.rounded(.down)
            let age = (pos - cycle) * period / 0.35
            guard age < 1 else { continue }
            let ci = Int(prand(Double(lane), cycle, 43) * Double(env.chars.count))
                .clamped(to: 0...(env.chars.count - 1))
            let x = env.charX[ci] + env.charW[ci] / 2
            let y = (prand(Double(lane), cycle, 44) - 0.4) * env.fontSize * 0.5 - age * 4 * env.scale
            let r = (1 - age * 0.6) * 1.1 * env.scale
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(Color(red: 1, green: 0.93, blue: 0.71).opacity((1 - age) * env.k)))
        }
    }
}

extension FlashPaint {
    /// A shared stone treatment: cool vertical gradient, per-char tone
    /// variation so the wall doesn't read as one flat slab.
    private static func stoneStyle(_ env: FlashEnv, _ i: Int, darken: Double = 0) -> AnyShapeStyle {
        let p = env.pal
        let v = prand(Double(i), 51) * 0.18 - darken
        return AnyShapeStyle(LinearGradient(colors: [
            mixColor(p.from, p.to, 0.15 + v),
            mixColor(p.from, p.to, 0.85 + v * 0.5)],
            startPoint: .top, endPoint: .bottom))
    }

    // ---- usage limit: variations on a fist meeting a rock wall ----

    /// Periodic impact: the word takes the hit — a scale punch and decaying
    /// shake — and dust bursts off it, arcing out and falling.
    static func slam(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        let T = 1.7
        let hit = env.t.truncatingRemainder(dividingBy: T)
        let cycle = (env.t / T).rounded(.down)
        let shock = exp(-hit * 6)
        var word = ctx
        word.translateBy(x: env.textWidth / 2 + sin(env.t * 67) * shock * 2.2 * env.scale,
                         y: cos(env.t * 53) * shock * 1.4 * env.scale)
        word.scaleBy(x: 1 + shock * 0.1, y: 1 + shock * 0.1)
        word.translateBy(x: -env.textWidth / 2, y: 0)
        word.drawLayer { layer in
            layer.addFilter(.shadow(color: p.glow, radius: (2 + 4 * shock) * env.scale))
            var l = layer
            drawWord(&l, env, style: { i in stoneStyle(env, i, darken: shock * 0.12) })
        }
        // Dust burst, one puff of lanes per hit.
        let a = hit / 0.9
        if a < 1 {
            for lane in 0..<10 {
                let s = Double(lane)
                guard prand(s, cycle, 52) < 0.85 else { continue }
                let x0 = prand(s, cycle, 53) * env.textWidth
                let vx = (prand(s, cycle, 54) - 0.5) * env.fontSize * 1.3
                let vy = (0.4 + prand(s, cycle, 55) * 0.8) * env.fontSize
                let x = x0 + vx * a
                let y = env.fontSize * 0.45 - vy * a + env.fontSize * 0.9 * a * a
                let r = (0.7 + prand(s, cycle, 56)) * env.scale * (1 - a * 0.4)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(p.extra.opacity((1 - a) * 0.7 * env.k)))
            }
        }
    }

    /// Cracks race through the stone lettering, flare amber-white, then fade
    /// as the next one starts elsewhere.
    static func crackline(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            var l = layer
            drawWord(&l, env, style: { i in stoneStyle(env, i, darken: 0.06) })
            l.blendMode = .sourceAtop
            let T = 2.1
            for j in 0..<2 {
                let local = env.t + Double(j) * T / 2
                let cycle = (local / T).rounded(.down)
                let phase = local.truncatingRemainder(dividingBy: T)
                let grow = min(phase / 0.45, 1)
                let fade = phase < 0.45 ? 1.0 : max(0, 1 - (phase - 0.45) / (T - 0.75))
                guard fade > 0 else { continue }
                let seed = Double(j) * 100 + cycle
                var path = Path()
                let n = 9
                let y0 = (prand(seed, 61) - 0.5) * env.fontSize * 0.5
                path.move(to: CGPoint(x: 0, y: y0))
                let steps = Int(Double(n) * grow * 100) // hundredths for partials
                for k in 1...n {
                    let frac = min(max(Double(steps) / 100 - Double(k - 1), 0), 1)
                    guard frac > 0 else { break }
                    let px = env.textWidth * Double(k) / Double(n)
                    let py = (prand(seed, Double(k), 62) - 0.5) * env.fontSize * 0.7
                    let prevX = env.textWidth * Double(k - 1) / Double(n)
                    let prevY = k == 1 ? y0 : (prand(seed, Double(k - 1), 62) - 0.5) * env.fontSize * 0.7
                    path.addLine(to: CGPoint(x: prevX + (px - prevX) * frac,
                                             y: prevY + (py - prevY) * frac))
                }
                var cracks = l
                cracks.addFilter(.shadow(color: p.mid.opacity(0.9), radius: 3 * env.scale))
                cracks.stroke(path, with: .color(mixColor(p.core, p.mid, 1 - fade).opacity(fade)),
                              lineWidth: (grow < 1 ? 1.2 : 0.9) * env.scale)
            }
        }
    }

    /// The wall gives way: letters shiver while chips break off and fall,
    /// tumbling, past the base.
    static func rubble(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        ctx.drawLayer { layer in
            for i in env.chars.indices {
                var l = layer
                l.addFilter(.shadow(color: p.glow, radius: 1.5 * env.scale))
                let t = charText(env.chars[i], env, stoneStyle(env, i))
                l.draw(l.resolve(t), at: CGPoint(x: env.charX[i],
                                                 y: sin(env.t * 23 + Double(i) * 4.2) * 0.4 * env.scale),
                       anchor: .leading)
            }
        }
        for i in env.chars.indices where env.chars[i] != " " {
            for lane in 0..<3 {
                let s = Double(i) * 13 + Double(lane)
                let life = 0.8 + prand(s, 71) * 0.6
                let pos = env.t / life + prand(s, 72)
                let cycle = pos.rounded(.down), age = pos - cycle
                guard prand(s, cycle, 73) < 0.4 else { continue }
                let x = env.charX[i] + env.charW[i] * (0.1 + prand(s, cycle, 74) * 0.8)
                    + (prand(s, cycle, 75) - 0.5) * 4 * env.scale * age
                let y = -env.fontSize * 0.5 + age * age * env.fontSize * 1.4
                let r = (0.8 + prand(s, cycle, 76) * 0.9) * env.scale
                var chip = ctx
                chip.translateBy(x: x, y: y)
                chip.rotate(by: .radians(age * (2 + prand(s, cycle, 77) * 4)))
                chip.fill(Path(CGRect(x: -r, y: -r * 0.7, width: r * 2, height: r * 1.4)),
                          with: .color(mixColor(p.extra, p.to, prand(s, cycle, 78) * 0.7)
                              .opacity((1 - age) * 0.9 * env.k)))
            }
        }
    }

    /// The whole wall trembles under the blow: per-letter rumble, drifting
    /// dust haze, and thin trickles of dust shaken loose from the top.
    static func quake(_ ctx: inout GraphicsContext, _ env: FlashEnv) {
        let p = env.pal
        let sway = sin(env.t * 3.1) * 0.7 * env.scale
        ctx.drawLayer { layer in
            var l = layer
            l.translateBy(x: sway, y: 0)
            l.drawLayer { inner in
                for i in env.chars.indices {
                    var c = inner
                    c.addFilter(.shadow(color: p.glow, radius: 1.5 * env.scale))
                    let t = charText(env.chars[i], env, stoneStyle(env, i))
                    c.draw(c.resolve(t),
                           at: CGPoint(x: env.charX[i] + sin(env.t * 31 + Double(i) * 2.9) * 0.6 * env.scale,
                                       y: cos(env.t * 27 + Double(i) * 5.3) * 0.7 * env.scale),
                           anchor: .leading)
                }
                inner.blendMode = .sourceAtop
                for b in 0..<2 {
                    let span = env.textWidth * 1.4
                    let bx = (((env.t * (4 + Double(b) * 3) * env.scale)
                        .truncatingRemainder(dividingBy: span)) + span)
                        .truncatingRemainder(dividingBy: span) - env.textWidth * 0.2
                    let w = env.fontSize * 1.1
                    inner.fill(Path(CGRect(x: bx - w, y: -env.fontSize, width: w * 2, height: env.fontSize * 2)),
                               with: .linearGradient(Gradient(stops: [
                                    .init(color: p.extra.opacity(0), location: 0),
                                    .init(color: p.extra.opacity(0.22), location: 0.5),
                                    .init(color: p.extra.opacity(0), location: 1)]),
                                  startPoint: CGPoint(x: bx - w, y: 0), endPoint: CGPoint(x: bx + w, y: 0)))
                }
            }
        }
        // Dust trickles shaken loose.
        for lane in 0..<4 {
            let s = Double(lane)
            let life = 0.55 + prand(s, 81) * 0.4
            let pos = env.t / life + prand(s, 82)
            let cycle = pos.rounded(.down), age = pos - cycle
            guard prand(s, cycle, 83) < 0.5 else { continue }
            let x = prand(s, cycle, 84) * env.textWidth
            let top = -env.fontSize * 0.5 + age * env.fontSize * 0.9
            var trail = Path()
            trail.move(to: CGPoint(x: x, y: top))
            trail.addLine(to: CGPoint(x: x + (prand(s, cycle, 85) - 0.5) * 2 * env.scale,
                                      y: top + env.fontSize * 0.35))
            ctx.stroke(trail, with: .color(p.extra.opacity((1 - age) * 0.5 * env.k)),
                       lineWidth: 0.8 * env.scale)
        }
    }
}

private extension Int {
    func clamped(to r: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

// MARK: - one rendered frame

/// A single frame of the flash at the status item's size: the badge parts
/// fading out (1-k) over the effect text fading in (k), centred in the
/// pinned slot. Also the body of every Config preview.
struct FlashFrameView: View {
    let event: FlashEvent
    let style: Int
    let t: Double
    let k: Double
    /// The live badge, exactly as renderBadges draws it; empty hides it
    /// (Config previews loop the effect alone).
    var badgeParts: [(String, Color)] = []
    var width: CGFloat
    var height: CGFloat = 22
    var scale: Double = 1
    var darkBar = true

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            if k < 1 && !badgeParts.isEmpty {
                var b = ctx
                b.opacity = 1 - k
                var x = 0.0
                let font = Font.system(size: 11 * scale, weight: .semibold).monospacedDigit()
                for (i, part) in badgeParts.enumerated() {
                    let text = Text((i > 0 ? " " : "") + part.0).font(font).foregroundStyle(part.1)
                    let r = b.resolve(text)
                    b.draw(r, at: CGPoint(x: x, y: midY), anchor: .leading)
                    x += r.measure(in: CGSize(width: 1000, height: 1000)).width
                }
            }
            guard k > 0 else { return }
            // Fit the word into the pinned slot, centred.
            var fontSize = 12.5 * scale
            let chars = event.text.map(String.init)
            func metrics(_ fs: Double) -> ([Double], [Double], Double) {
                var xs: [Double] = [], ws: [Double] = [], x = 0.0
                for ch in chars {
                    let w = ctx.resolve(Text(ch).font(.system(size: fs, weight: .bold)))
                        .measure(in: CGSize(width: 1000, height: 1000)).width
                    xs.append(x); ws.append(w); x += w
                }
                return (xs, ws, x)
            }
            var (xs, ws, tw) = metrics(fontSize)
            let avail = size.width * 0.96
            if tw > avail {
                fontSize *= avail / tw
                (xs, ws, tw) = metrics(fontSize)
            }
            var fx = ctx
            fx.opacity = k
            fx.translateBy(x: (size.width - tw) / 2, y: midY)
            var env = FlashEnv(t: t, k: k, fontSize: fontSize, scale: scale,
                               textWidth: tw, chars: chars, charX: xs, charW: ws,
                               pal: .palette(event, darkBar: darkBar))
            env.k = k
            FlashPaint.paint(&fx, event: event, style: style, env: env)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - status item driver

/// Runs one flash on the status item: pins the item's width, swaps the
/// title for rendered frames at 30fps, and puts everything back when the
/// sound ends. A new alert mid-flash restarts cleanly.
@MainActor
final class FlashController {
    static let fadeIn = 0.35, fadeOut = 0.5

    private weak var statusItem: NSStatusItem?
    private var timer: Timer?
    private var start = Date()
    private var duration: TimeInterval = 5
    private var event: FlashEvent = .reset
    private var style = 0
    private var badgeParts: [(String, Color)] = []
    private var width: CGFloat = 60
    private var onFinish: (() -> Void)?
    var isRunning: Bool { timer != nil }

    init(statusItem: NSStatusItem?) { self.statusItem = statusItem }

    func flash(event: FlashEvent, style: Int, badgeParts: [(String, Color)],
               duration: TimeInterval, onFinish: @escaping () -> Void) {
        guard let item = statusItem, let button = item.button else { return }
        stop()
        self.event = event
        self.style = style
        self.badgeParts = badgeParts
        self.duration = max(duration, 1.5)
        self.onFinish = onFinish
        start = Date()
        // Pin to the badge's current width so neighbours never shift.
        width = max(button.attributedTitle.size().width.rounded(.up), 40)
        item.length = width
        button.imagePosition = .imageOnly
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    private func tick() {
        guard let button = statusItem?.button else { stop(); return }
        let t = Date().timeIntervalSince(start)
        if t >= duration { stop(); return }
        var k = 1.0
        if t < Self.fadeIn { k = t / Self.fadeIn }
        else if t > duration - Self.fadeOut { k = max(0, (duration - t) / Self.fadeOut) }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let view = FlashFrameView(event: event, style: style, t: t, k: k,
                                  badgeParts: badgeParts, width: width, darkBar: dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = (button.window?.backingScaleFactor ?? 2)
        if let img = renderer.nsImage {
            img.isTemplate = false
            button.image = img
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let item = statusItem, let button = item.button {
            button.image = nil
            button.imagePosition = .noImage
            item.length = NSStatusItem.variableLength
        }
        let cb = onFinish; onFinish = nil
        cb?()
    }
}

// MARK: - Config preview

/// The in-app twin of the Flash Lab's inspection view: a dark menu-bar mock
/// at Config width, looping the picked style — or walking all four when the
/// pick is "Cycle each flash", captioned like the bar-effect previews.
struct FlashPreviewBar: View {
    let event: FlashEvent
    /// -1 = cycle; otherwise a pinned style index.
    let pick: Int
    var animating = true
    @State private var began = Date()

    private static let cycleSeconds = 4.0

    var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            let t = context.date.timeIntervalSince(began)
            let style = pick >= 0 ? pick
                : Int(t / Self.cycleSeconds) % FlashEvent.styleCount
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 20) {
                    Image(systemName: "apple.logo").font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.93).opacity(0.8))
                    Spacer()
                    FlashFrameView(event: event, style: style, t: t, k: 1,
                                   width: 190, height: 34, scale: 1.7, darkBar: true)
                    Spacer()
                    Text("9:41").font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.93).opacity(0.7))
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Color(red: 0.09, green: 0.082, blue: 0.10),
                            in: RoundedRectangle(cornerRadius: 8))
                if pick < 0 {
                    Text(event.styleNames[style])
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
