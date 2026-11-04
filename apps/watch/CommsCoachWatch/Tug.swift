import SwiftUI

/// Tug, the tin-can telephone, as the simplified watch glyph: a plain can with a thick rim, two eyes
/// and its string. The full face (brows, mouth, bands) is too busy at this size.
/// The string is the shared record between devices; `pull` 0 hangs it slack, 1 pulls it taut.
struct TugGlyph: View {
    var size: CGFloat
    /// How far the string runs past the can, to the right.
    var reach: CGFloat = 0
    /// Where the string ends, as a fraction of `size` from the top.
    var endY: CGFloat = 0.78
    var pull: Double = 0
    /// Offline: the string hangs short and cut.
    var cut = false
    var showsCan = true
    var showsString = true
    /// Errors: raised inner brows and a sweat drop.
    var worried = false
    /// The practice round's faces: listening (brows up), thinking (eyes closed), speaking (mouth open by `mouth`, 0–1).
    var face: TugFace = .plain

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsString {
                TugString(size: size, reach: reach, endY: endY, pull: pull)
                    .trim(from: 0, to: cut ? 0.42 : 1)
                    .stroke(Palette.tugString, style: StrokeStyle(lineWidth: max(1.5, size * 0.075), lineCap: .round))
            }
            if showsCan {
                TugCan(worried: worried, face: face)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(pull * 5), anchor: UnitPoint(x: 0.5, y: 0.88)) // leans into the tug
                    .offset(x: pull * size * 0.03)
            }
        }
        .frame(width: size + reach, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The can, traced from the mascot sheet's 64-unit drawing.
private struct TugCan: View {
    var worried = false
    var face: TugFace = .plain

    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / 64
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (cx - rx) * k, y: (cy - ry) * k, width: rx * 2 * k, height: ry * 2 * k))
            }
            let outline = StrokeStyle(lineWidth: 2.6 * k, lineJoin: .round)

            var body = Path()
            body.move(to: p(14, 18))
            body.addLine(to: p(14, 47))
            body.addQuadCurve(to: p(32, 56), control: p(14, 56))
            body.addQuadCurve(to: p(50, 47), control: p(50, 56))
            body.addLine(to: p(50, 18))
            body.closeSubpath()
            context.fill(body, with: .color(Palette.tugBody))
            context.stroke(body, with: .color(Palette.tugOutline), style: outline)

            let rim = oval(32, 18, 18, 6.5)
            context.fill(rim, with: .color(Palette.tugRim))
            context.stroke(rim, with: .color(Palette.tugOutline), style: outline)
            context.fill(oval(32, 18.5, 12, 3), with: .color(Palette.tugInner))

            let ink = Palette.tugOutline
            let line = StrokeStyle(lineWidth: 3 * k, lineCap: .round)
            switch face {
            case .thinking:
                // Eyes closed: two short downward arcs.
                var lids = Path()
                for x: CGFloat in [25, 39] {
                    lids.move(to: p(x - 3.6, 36)); lids.addQuadCurve(to: p(x + 3.6, 36), control: p(x, 40.5))
                }
                context.stroke(lids, with: .color(ink), style: line)
            default:
                let big: CGFloat = face == .listening ? 3.9 : 3.4
                context.fill(oval(25, 37, big, big), with: .color(ink))
                context.fill(oval(39, 37, big, big), with: .color(ink))
            }
            if face == .listening {
                // Brows raised high: paying attention.
                var brows = Path()
                brows.move(to: p(20.5, 29.5)); brows.addQuadCurve(to: p(29.5, 29.5), control: p(25, 26))
                brows.move(to: p(34.5, 29.5)); brows.addQuadCurve(to: p(43.5, 29.5), control: p(39, 26))
                context.stroke(brows, with: .color(ink), style: line)
            }
            if case .speaking(let open) = face {
                let o = CGFloat(max(0, min(1, open)))
                if o < 0.08 {
                    var smile = Path()
                    smile.move(to: p(27.5, 45)); smile.addQuadCurve(to: p(36.5, 45), control: p(32, 48.5))
                    context.stroke(smile, with: .color(ink), style: line)
                } else {
                    context.fill(oval(32, 46, 4.6, 1.4 + 3.6 * o), with: .color(ink))
                }
            }

            if worried {
                // Brows with their inner ends raised, and one sweat drop beside the rim.
                var brows = Path()
                brows.move(to: p(19.5, 31)); brows.addLine(to: p(28, 28))
                brows.move(to: p(36, 28)); brows.addLine(to: p(44.5, 31))
                context.stroke(brows, with: .color(Palette.tugOutline), style: StrokeStyle(lineWidth: 3.2 * k, lineCap: .round))
                var drop = Path()
                drop.move(to: p(57, 21))
                drop.addCurve(to: p(57, 34), control1: p(53, 27), control2: p(51.5, 34))
                drop.addCurve(to: p(57, 21), control1: p(62.5, 34), control2: p(61, 27))
                drop.closeSubpath()
                context.fill(drop, with: .color(Palette.worry))
                context.stroke(drop, with: .color(Palette.tugOutline), style: StrokeStyle(lineWidth: 1.6 * k, lineJoin: .round))
            }
        }
    }
}

/// Tug's face in the practice round. `.plain` is the everyday glyph.
enum TugFace: Equatable {
    case plain, listening, thinking
    case speaking(Double)
}

/// Tug saying the question: the mouth opens and closes while `talking`, and rests in a small smile after.
/// With Reduce Motion the mouth stays half open while it talks.
struct TugSpeaking: View {
    var size: CGFloat
    var talking: Bool
    var reach: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if talking && !reduceMotion {
            // A 15 Hz TimelineView here rebuilt the screen on every frame, and the real watch dropped taps on the
            // buttons beside it. The mouth now steps about twice a second, the rate of the recording clock.
            TimelineView(.periodic(from: .now, by: 0.45)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2
                TugGlyph(size: size, reach: reach, face: .speaking(step == 0 ? 0.9 : 0.35))
            }
        } else {
            TugGlyph(size: size, reach: reach, face: .speaking(talking ? 0.5 : 0))
        }
    }
}

/// Tug listening while you answer: brows up and the string pulled taut, with a small live tremor in the lean.
/// With Reduce Motion it holds still.
struct TugListening: View {
    var size: CGFloat
    var reach: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taut = false

    var body: some View {
        if reduceMotion {
            TugGlyph(size: size, reach: reach, pull: 1, face: .listening)
        } else {
            // The tremor is a repeating animation, as on the recording light, not a TimelineView: a 20 Hz
            // TimelineView rebuilt the screen on every frame, and the real watch dropped taps on Stop (build 9).
            TugGlyph(size: size, reach: reach, pull: taut ? 1 : 0.72, face: .listening)
                .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: taut)
                .onAppear { taut = true }
        }
    }
}

/// The string from the bottom of the can to its far end. Animatable, so a tug moves it smoothly.
private struct TugString: Shape {
    let size: CGFloat
    let reach: CGFloat
    let endY: CGFloat
    var pull: Double

    var animatableData: Double {
        get { pull }
        set { pull = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let start = CGPoint(x: size * 0.5, y: size * 0.86)
        let end = CGPoint(x: size + reach, y: size * endY)
        let sag = size * 0.2
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        let slack1 = CGPoint(x: start.x + size * 0.05, y: start.y + sag)
        let slack2 = CGPoint(x: end.x - (end.x - start.x) * 0.4, y: max(start.y, end.y) + sag)
        let t = CGFloat(pull)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: lerp(slack1, lerp(start, end, 1 / 3), t), control2: lerp(slack2, lerp(start, end, 2 / 3), t))
        return path
    }
}

/// Analyzing: Tug gives its string a short tug, then lets it go slack, on a loop.
/// With Reduce Motion the can stays still and only the slack and taut strings crossfade.
struct TugWorking: View {
    var size: CGFloat = 52
    /// The practice round's "Thinking": the same tug, with the eyes closed.
    var face: TugFace = .plain
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taut = false

    private enum Beat: CaseIterable { case rest, tug, hold, release }

    var body: some View {
        if reduceMotion {
            ZStack {
                TugGlyph(size: size, reach: size * 0.7, pull: 0, showsCan: false).opacity(taut ? 0 : 1)
                TugGlyph(size: size, reach: size * 0.7, pull: 1, showsCan: false).opacity(taut ? 1 : 0)
                TugGlyph(size: size, reach: size * 0.7, pull: 0, showsString: false, face: face)
            }
            .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever()) { taut = true } }
        } else {
            PhaseAnimator(Beat.allCases) { beat in
                TugGlyph(size: size, reach: size * 0.7, pull: beat == .tug || beat == .hold ? 1 : 0, face: face)
            } animation: { beat in
                switch beat {
                case .tug: .spring(duration: 0.28, bounce: 0.45)
                case .hold: .linear(duration: 0.25)
                case .release: .easeOut(duration: 0.7)
                case .rest: .linear(duration: 0.5)
                }
            }
        }
    }
}
