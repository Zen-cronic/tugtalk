import AppKit
import SwiftUI

// Tug, the tin-can telephone. Drawn in code from the 64-unit traces: a steel can with an open rim,
// two bands, an ink outline, a face, and a string tail that runs toward whatever Tug is showing.
// The face and the string do the acting; the body only leans and bobs. No scale animation.

/// How the string lies. Each mode is also a Reduce Motion still at its rest time.
enum TugStringMode: Equatable {
    case slack      // idle: a loose loop
    case taut       // listening: pulled straight, with a small live tremor
    case coil       // thinking: one loop that slowly turns
    case ripple     // speaking: a wave runs along it
    case beckon     // follow-up or challenge: the end curls like a beckoning finger
    case tug        // nudge: tugged from the other end
    case cut        // offline: cut, the far end left behind
    case knot       // error: a knot in it
    case none       // drawn separately (Tug on a title bar, lowering the label)
}

/// Everything that varies between states. Interpolated when the state changes.
struct TugPose: Equatable {
    var lean: Double = 0          // degrees, positive toward the string side
    var bob: Double = 0           // units, positive down
    var turn: Double = 0          // -1…1: rim and face turned toward (+) or away from (-) the string side
    var eyeOpen: Double = 1
    var lookX: Double = 0, lookY: Double = 0
    var happyEyes = false
    var browNear: Double = 0, browFar: Double = 0   // raise, in units; "near" is the string side
    var worried: Double = 0       // inner brow ends up
    var smile: Double = 0.5       // -1 frown … 1 grin
    var mouthOpen: Double = 0
    var showFace = true
    var string: TugStringMode = .slack
    var stringAmount: Double = 1  // mode strength (tremor, wave height, pull)

    static func lerp(_ a: TugPose, _ b: TugPose, _ k: Double) -> TugPose {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        var p = b
        p.lean = m(a.lean, b.lean); p.bob = m(a.bob, b.bob); p.turn = m(a.turn, b.turn)
        p.eyeOpen = m(a.eyeOpen, b.eyeOpen); p.lookX = m(a.lookX, b.lookX); p.lookY = m(a.lookY, b.lookY)
        p.browNear = m(a.browNear, b.browNear); p.browFar = m(a.browFar, b.browFar); p.worried = m(a.worried, b.worried)
        p.smile = m(a.smile, b.smile); p.mouthOpen = m(a.mouthOpen, b.mouthOpen)
        p.happyEyes = k < 0.5 ? a.happyEyes : b.happyEyes
        p.showFace = k < 0.5 ? a.showFace : b.showFace
        return p
    }
}

extension TugPose {
    /// The pose for a state at time `t`. With Reduce Motion `t` is fixed, so each state is one still.
    init(phase: MascotPhase, t: Double, talking: Bool, animated: Bool) {
        self.init()
        let blinkCycle = 5.2 + 1.3 * sin(t / 9)
        let blink = animated && t.truncatingRemainder(dividingBy: blinkCycle) < 0.14
        switch phase {
        case .idle, .hidden, .notice:
            bob = animated ? 0.9 * sin(t * 2 * .pi / 3.6) : 0
            smile = 0.45
            string = .slack
        case .listening:
            turn = 0.7; lookX = 1.2; eyeOpen = 1.12; browNear = 0.8; browFar = 0.8
            smile = 0.05; mouthOpen = 0.25
            string = .taut; stringAmount = 0.35
        case .voiceListening:
            turn = 0.8; lookX = 1.4; eyeOpen = 1.15; browNear = 1; browFar = 0.6
            smile = 0.1; mouthOpen = 0.2
            string = .taut; stringAmount = 1
        case .thinking, .voiceThinking:
            lookY = -2.2; lookX = -0.6; browFar = 1.6; smile = 0.1
            string = .coil
        case .speaking:
            smile = 0.65
            if talking {
                mouthOpen = animated ? 0.25 + 0.55 * abs(sin(t * 10)) : 0.5
                string = .ripple
            } else {
                string = .slack
            }
            turn = 0.35; lookX = 0.8
        case .voiceSpeaking(let card):
            let sparring = card.move == .follow_up || card.move == .challenge
            if card.endsRound {
                happyEyes = card.finished; smile = 0.9
                mouthOpen = card.finished ? 0 : (animated ? 0.25 + 0.55 * abs(sin(t * 11)) : 0.5)
                string = card.finished ? .slack : .ripple
            } else if !card.finished {
                mouthOpen = animated ? 0.25 + 0.6 * abs(sin(t * 11)) : 0.5
                smile = 0.5; string = .ripple
                if sparring { lean = 4; browNear = 1.6; turn = 0.4 }
            } else {
                // Follow-up or challenge: leans in, one brow up, the string beckons.
                lean = 6; turn = 0.5; lookX = 1; browNear = 2.2; browFar = -0.2
                smile = 0.4; string = .beckon
            }
        case .nudging(_, let opened):
            smile = 0.8; eyeOpen = 1.1; browNear = 1; browFar = 1
            if animated && !opened {
                // A sharp tug every 1.4 s, then a settle.
                let c = t.truncatingRemainder(dividingBy: 1.4)
                let pull = c < 0.08 ? c / 0.08 : max(0, 1 - (c - 0.08) / 0.55)
                stringAmount = pull; lean = 7 * pull; lookX = 1.6 * pull
            } else {
                stringAmount = opened ? 0.2 : 0.7; lean = opened ? 0 : 4
            }
            string = .tug
        case .blocked:
            showFace = false; turn = -1; string = .slack
        case .offline:
            eyeOpen = 0.35; worried = 1.2; smile = -0.45; lean = -3; string = .cut
        case .voiceError:
            eyeOpen = 0.55; worried = 1; smile = -0.3; string = .knot
        case .permission, .micPermission:
            turn = 0.5; lookX = 1; browNear = 0.9; browFar = 0.9; smile = 0.4; string = .slack
        }
        if blink && !happyEyes { eyeOpen = 0.08 }
    }
}

/// Draws Tug in a square. `facesRight` puts the string on the right, toward a pill or card there.
struct TugCanvas: View {
    let pose: TugPose
    var facesRight = true
    var t: Double = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 64
            var ctx = context
            if !facesRight { ctx.translateBy(x: size.width, y: 0); ctx.scaleBy(x: -1, y: 1) }
            ctx.translateBy(x: (size.width - 64 * s) / 2 * (facesRight ? 1 : 1), y: (size.height - 64 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            TugDrawing.draw(in: ctx, pose: pose, t: t, string: Tok.tugString(scheme), halo: scheme == .dark)
        }
        .accessibilityHidden(true)
    }
}

enum TugDrawing {
    static let outline: CGFloat = 2.6
    /// The body's pivot: the middle of the base.
    static let pivot = CGPoint(x: 32, y: 56)

    /// `halo` draws a light rim around the can, so its ink outline still reads on a dark ground.
    static func draw(in ctx: GraphicsContext, pose: TugPose, t: Double, string: Color, halo: Bool = false) {
        let ink = Color(Tok.metalOutline)
        var body = ctx
        body.translateBy(x: 0, y: pose.bob)
        body.translateBy(x: pivot.x, y: pivot.y)
        body.rotate(by: .degrees(pose.lean))
        body.translateBy(x: -pivot.x, y: -pivot.y)

        // The string leaves the base, so it follows the lean.
        let start = rotated(CGPoint(x: 32, y: 55), by: pose.lean).applying(.init(translationX: 0, y: pose.bob))
        let stroke = StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round)
        for piece in stringPieces(pose.string, from: start, amount: pose.stringAmount, t: t) {
            ctx.stroke(piece, with: .color(string), style: stroke)
        }
        if pose.string == .knot {
            let knot = Path(ellipseIn: CGRect(x: 45, y: 54.6, width: 4.4, height: 4.4))
            ctx.stroke(knot, with: .color(string), style: StrokeStyle(lineWidth: 2.4))
        }

        // Body, bands, rim and opening.
        let can = Path { p in
            p.move(to: CGPoint(x: 14, y: 18)); p.addLine(to: CGPoint(x: 14, y: 47))
            p.addQuadCurve(to: CGPoint(x: 32, y: 56), control: CGPoint(x: 14, y: 56))
            p.addQuadCurve(to: CGPoint(x: 50, y: 47), control: CGPoint(x: 50, y: 56))
            p.addLine(to: CGPoint(x: 50, y: 18)); p.closeSubpath()
        }
        if halo {
            let light = Color(Tok.metalLight).opacity(0.55)
            body.stroke(can, with: .color(light), style: StrokeStyle(lineWidth: outline + 3, lineJoin: .round))
            body.stroke(Path(ellipseIn: CGRect(x: 14 + pose.turn * 1.4, y: 12.5, width: 36, height: 11)), with: .color(light), lineWidth: outline + 3)
        }
        body.fill(can, with: .color(Color(Tok.metal)))
        let bands = Path { p in
            p.move(to: CGPoint(x: 14.5, y: 27)); p.addQuadCurve(to: CGPoint(x: 49.5, y: 27), control: CGPoint(x: 32, y: 31))
            p.move(to: CGPoint(x: 14.5, y: 47)); p.addQuadCurve(to: CGPoint(x: 49.5, y: 47), control: CGPoint(x: 32, y: 51))
        }
        body.stroke(bands, with: .color(Color(Tok.metalLight)), lineWidth: 3)
        if !pose.showFace {
            // The back of the can: a seam where the face would be.
            body.stroke(Path { p in p.move(to: CGPoint(x: 41, y: 30)); p.addLine(to: CGPoint(x: 41, y: 46)) },
                        with: .color(Color(Tok.metalDark)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        body.stroke(can, with: .color(ink), style: StrokeStyle(lineWidth: outline, lineJoin: .round))
        let rimShift = pose.turn * 1.4
        let rim = Path(ellipseIn: CGRect(x: 14 + rimShift, y: 12.5, width: 36, height: 11))
        body.fill(rim, with: .color(Color(Tok.metalLight)))
        body.stroke(rim, with: .color(ink), lineWidth: outline)
        let opening = Path(ellipseIn: CGRect(x: 18.5 + rimShift * 1.8, y: 15.1, width: 27, height: 6.8))
        body.fill(opening, with: .color(Color(Tok.metalDark)))
        body.stroke(opening, with: .color(ink), lineWidth: outline)

        guard pose.showFace else { return }
        drawFace(in: body, pose: pose, ink: ink)
    }

    private static func drawFace(in ctx: GraphicsContext, pose: TugPose, ink: Color) {
        let dx = pose.turn * 3 + pose.lookX, dy = pose.lookY
        let line = StrokeStyle(lineWidth: outline, lineCap: .round, lineJoin: .round)
        // Eyes. The string side is +x.
        for (i, x) in [25.5, 38.5].enumerated() {
            let c = CGPoint(x: x + dx, y: 37 + dy)
            if pose.happyEyes {
                let arc = Path { p in p.move(to: CGPoint(x: c.x - 2.8, y: c.y + 1)); p.addQuadCurve(to: CGPoint(x: c.x + 2.8, y: c.y + 1), control: CGPoint(x: c.x, y: c.y - 3.2)) }
                ctx.stroke(arc, with: .color(ink), style: line)
            } else {
                let h = max(0.9, 5.2 * pose.eyeOpen)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.6, y: c.y - h / 2, width: 5.2, height: h)), with: .color(ink))
            }
            _ = i
        }
        // Brows: left (far from the string) and right (near).
        let far = Path { p in
            let lift = pose.browFar, inner = pose.worried * 1.8
            p.move(to: CGPoint(x: 22 + dx, y: 31.5 + dy - lift))
            p.addQuadCurve(to: CGPoint(x: 28.5 + dx, y: 31 + dy - lift - inner), control: CGPoint(x: 25 + dx, y: 30 + dy - lift - inner * 0.5))
        }
        let near = Path { p in
            let lift = pose.browNear, inner = pose.worried * 1.8
            p.move(to: CGPoint(x: 35.5 + dx, y: 31 + dy - lift - inner))
            p.addQuadCurve(to: CGPoint(x: 42 + dx, y: 31.5 + dy - lift - lift * 0.35), control: CGPoint(x: 39 + dx, y: 30 + dy - lift * 1.25 - inner * 0.5))
        }
        ctx.stroke(far, with: .color(ink), style: line)
        ctx.stroke(near, with: .color(ink), style: line)
        // Mouth: a curve that bends with `smile` and opens downward while talking.
        let mx = 32 + dx * 0.8, my = 42.5 + dy * 0.5
        let curve = pose.smile * 3.2
        let mouth = Path { p in
            p.move(to: CGPoint(x: mx - 3.4, y: my))
            p.addQuadCurve(to: CGPoint(x: mx + 3.4, y: my), control: CGPoint(x: mx, y: my + curve))
            if pose.mouthOpen > 0.05 {
                p.addQuadCurve(to: CGPoint(x: mx - 3.4, y: my), control: CGPoint(x: mx, y: my + curve + pose.mouthOpen * 7))
                p.closeSubpath()
            }
        }
        if pose.mouthOpen > 0.05 { ctx.fill(mouth, with: .color(ink)) }
        ctx.stroke(mouth, with: .color(ink), style: line)
    }

    private static func rotated(_ point: CGPoint, by degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180, x = point.x - pivot.x, y = point.y - pivot.y
        return CGPoint(x: pivot.x + x * cos(a) - y * sin(a), y: pivot.y + x * sin(a) + y * cos(a))
    }

    /// The string's end, on the right edge, level with a pill beside Tug.
    static let end = CGPoint(x: 64, y: 52.5)

    static func stringPieces(_ mode: TugStringMode, from s: CGPoint, amount: Double, t: Double) -> [Path] {
        switch mode {
        case .slack:
            let sway = 0.8 * sin(t * 1.6)
            return [Path { p in
                p.move(to: s)
                p.addCurve(to: CGPoint(x: 44, y: 58 + sway * 0.5), control1: CGPoint(x: s.x - 1, y: 61), control2: CGPoint(x: 40, y: 62 + sway))
                p.addCurve(to: CGPoint(x: 42, y: 54.5), control1: CGPoint(x: 47, y: 55), control2: CGPoint(x: 44, y: 52))
                p.addCurve(to: end, control1: CGPoint(x: 40, y: 58), control2: CGPoint(x: 49, y: 60.5 - sway))
            }]
        case .taut:
            return [polyline(from: s, to: end) { u in sin(.pi * u) * amount * 0.9 * sin(t * 2 * .pi * 7 + u * 3) }]
        case .ripple:
            return [polyline(from: s, to: end) { u in sin(.pi * u) * 2.2 * amount * sin(u * 4 * .pi - t * 9) }]
        case .tug:
            // Pulled toward the far end: from slack (0) to straight (1).
            let sag = (1 - amount) * 4.5
            return [polyline(from: s, to: end) { u in sin(.pi * u) * sag }]
        case .coil:
            let angle = 0.6 * sin(t * 1.1)
            return [Path { p in
                let n = 64
                for i in 0...n {
                    let u = Double(i) / Double(n)
                    var x = s.x + (end.x - s.x) * u, y = s.y + (end.y - s.y) * u + sin(.pi * u) * 1.5
                    if u > 0.3 && u < 0.72 {
                        let w = (u - 0.3) / 0.42, r = 4.4
                        let ox = r * sin(2 * .pi * w), oy = -r * (1 - cos(2 * .pi * w))
                        x += ox * cos(angle) - oy * sin(angle)
                        y += ox * sin(angle) + oy * cos(angle)
                    }
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }]
        case .beckon:
            let curl = 1.2 * sin(t * 2.4)
            return [Path { p in
                p.move(to: s)
                p.addCurve(to: CGPoint(x: 53, y: 47), control1: CGPoint(x: 40, y: 61), control2: CGPoint(x: 51, y: 58))
                p.addCurve(to: CGPoint(x: 48, y: 41), control1: CGPoint(x: 54.5, y: 39), control2: CGPoint(x: 49 + curl * 0.5, y: 36))
                p.addCurve(to: CGPoint(x: 56 + curl, y: 40 - curl), control1: CGPoint(x: 47, y: 45), control2: CGPoint(x: 53, y: 46))
            }]
        case .cut:
            let near = Path { p in
                p.move(to: s)
                p.addCurve(to: CGPoint(x: 41, y: 61), control1: CGPoint(x: s.x + 1, y: 60), control2: CGPoint(x: 37, y: 62))
                p.move(to: CGPoint(x: 41, y: 61)); p.addLine(to: CGPoint(x: 43.2, y: 59.4))
                p.move(to: CGPoint(x: 41, y: 61)); p.addLine(to: CGPoint(x: 43.4, y: 62.2))
            }
            let farEnd = Path { p in p.move(to: CGPoint(x: 57, y: 55.5)); p.addLine(to: end) }
            return [near, farEnd]
        case .knot:
            return stringPieces(.slack, from: s, amount: amount, t: 0)
        case .none:
            return []
        }
    }

    private static func polyline(from a: CGPoint, to b: CGPoint, offset: (Double) -> Double) -> Path {
        Path { p in
            let n = 40
            for i in 0...n {
                let u = Double(i) / Double(n)
                let pt = CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u + offset(u))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }
}

/// Tug, animated for its state. Pose changes ease over 0.28 s; with Reduce Motion the clock stops,
/// each state is its still, and a change is a crossfade.
struct TugView: View {
    let phase: MascotPhase
    var talking = false
    var facesRight = true
    @Environment(\.reduceMotionOn) private var reduceMotion
    @State private var previous: TugPose?
    @State private var changedAt = Date.distantPast
    @State private var shown: MascotPhase?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0.35 : context.date.timeIntervalSinceReferenceDate
            let target = TugPose(phase: phase, t: t, talking: talking, animated: !reduceMotion)
            let k = reduceMotion ? 1 : min(1, context.date.timeIntervalSince(changedAt) / 0.28)
            let eased = 1 - pow(1 - k, 3)
            TugCanvas(pose: previous.map { TugPose.lerp($0, target, eased) } ?? target, facesRight: facesRight, t: t)
        }
        .id(reduceMotion ? phase.name + (talking ? "-talking" : "") : "tug")
        .transition(.opacity.animation(Motion.crossfade))
        .onChange(of: phase.name + (talking ? "-talking" : "")) { _, _ in
            let now = Date()
            if let shown { previous = TugPose(phase: shown, t: now.timeIntervalSinceReferenceDate, talking: false, animated: !reduceMotion) }
            changedAt = now
            shown = phase
        }
        .onAppear { shown = phase }
    }
}

/// The small Tug: one colour, no bands, a thick rim, eyes at least 2 px, and a 1.6 pt string in one
/// clean curve. Drawn for the menu bar (18 pt, template) and anywhere Tug is 24 pt or smaller.
enum TugGlyph {
    /// Geometry in an 18 × 18 box, y down.
    static func paths() -> (solid: NSBezierPath, holes: NSBezierPath, string: NSBezierPath) {
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 2.6, y: 4.4))
        body.line(to: NSPoint(x: 2.6, y: 12.4))
        body.curve(to: NSPoint(x: 8, y: 15.7), controlPoint1: NSPoint(x: 2.6, y: 15.2), controlPoint2: NSPoint(x: 5.2, y: 15.7))
        body.curve(to: NSPoint(x: 13.4, y: 12.4), controlPoint1: NSPoint(x: 10.8, y: 15.7), controlPoint2: NSPoint(x: 13.4, y: 15.2))
        body.line(to: NSPoint(x: 13.4, y: 4.4))
        body.close()
        // The rim, as wide as the can, with a clear opening.
        body.append(NSBezierPath(ovalIn: NSRect(x: 2.2, y: 1.9, width: 11.6, height: 5.0)))
        let holes = NSBezierPath(ovalIn: NSRect(x: 4.3, y: 3.2, width: 7.4, height: 2.3))
        holes.append(NSBezierPath(ovalIn: NSRect(x: 4.9, y: 8.5, width: 2.4, height: 2.7)))
        holes.append(NSBezierPath(ovalIn: NSRect(x: 8.7, y: 8.5, width: 2.4, height: 2.7)))
        let string = NSBezierPath()
        string.move(to: NSPoint(x: 8, y: 15.4))
        string.curve(to: NSPoint(x: 17.2, y: 12.4), controlPoint1: NSPoint(x: 9.4, y: 18.0), controlPoint2: NSPoint(x: 14.2, y: 17.6))
        string.lineWidth = 1.6
        string.lineCapStyle = .round
        return (body, holes, string)
    }

    /// A single-colour image. `template` lets the menu bar tint it for light, dark and highlighted.
    static func image(size: CGFloat = 18, color: NSColor = .black, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let g = NSGraphicsContext.current else { return false }
            let k = rect.width / 18
            g.cgContext.scaleBy(x: k, y: k)
            let (solid, holes, string) = paths()
            color.setFill(); color.setStroke()
            solid.fill()
            string.stroke()
            g.compositingOperation = .clear
            holes.fill()
            g.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "\(MascotName)"
        return image
    }
}
