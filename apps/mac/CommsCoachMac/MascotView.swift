import SwiftUI

/// Layout constants shared with the panel controller.
enum MascotLayout {
    static let character: CGFloat = 76
    static let pad: CGFloat = 10
    static let bubbleWidth: CGFloat = 320
    static let gap: CGFloat = 8
}

/// The whole panel: the character plus a status chip or a speech bubble beside it.
struct MascotRoot: View {
    @ObservedObject var model: CompanionModel
    var onDrag: (DragGesture.Value?) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: MascotLayout.gap) {
            if model.bubbleLeading { side; character } else { character; side }
        }
        .padding(MascotLayout.pad)
        .fixedSize()
    }

    private var character: some View {
        CharacterView(phase: model.phase)
            .frame(width: MascotLayout.character, height: MascotLayout.character)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { onDrag($0) }
                .onEnded { _ in onDrag(nil) })
            .onTapGesture { model.clicked() }
            .onHover { inside in hovering = inside; model.layoutNeeded() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(MascotName) companion")
            .accessibilityValue(model.phase.name)
            .accessibilityHint("Reads the front window when you ask. Also on Control-Option-Space.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.clicked() }
    }

    @ViewBuilder private var side: some View {
        if model.phase.showsBubble {
            BubbleView(model: model).frame(width: MascotLayout.bubbleWidth)
        } else if model.phase != .idle || hovering {
            StatusChip(phase: model.phase).padding(.bottom, 6)
        }
    }
}

/// Icon plus text, so a state never depends on colour alone.
struct StatusChip: View {
    let phase: MascotPhase
    @Environment(\.accessibilityReduceTransparency) private var opaque

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label {
                Text(phase.label(now: context.date)).font(.system(size: 13, weight: .medium)).lineLimit(1)
            } icon: {
                Image(systemName: phase.symbol).foregroundStyle(Color(nsColor: phase.accent)).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(opaque ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)))
            .overlay(Capsule().strokeBorder(Color(nsColor: phase.accent).opacity(0.7), lineWidth: 1))
            .fixedSize()
        }
        .accessibilityHidden(true)
    }
}

/// The original character: a rounded speech-bubble body with two capsule eyes and a mouth arc.
struct CharacterView: View {
    let phase: MascotPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pose = Pose(phase: phase, t: reduceMotion ? 0 : t)
            ZStack {
                if case .thinking = phase {
                    Circle().fill(Color(nsColor: Palette.model).opacity(0.35 + 0.25 * pose.pulse))
                        .blur(radius: 10).scaleEffect(0.95 + 0.15 * pose.pulse)
                }
                BodyShape()
                    .fill(Color(nsColor: pose.bodyColor))
                    .overlay(BodyShape().stroke(Color(nsColor: Palette.ink).opacity(0.85), lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .frame(width: 62, height: 58)
                Face(pose: pose).frame(width: 62, height: 58).offset(y: -4)
                if case .listening = phase {
                    Circle().trim(from: 0, to: reduceMotion ? 1 : 0.15 + 0.85 * pose.progress)
                        .stroke(Color(nsColor: Palette.capture), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 74, height: 74)
                }
                if case .nudging = phase {
                    Circle().fill(Color(nsColor: Palette.record)).overlay(Image(systemName: "bell.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(nsColor: Palette.ink)))
                        .frame(width: 22, height: 22).overlay(Circle().stroke(Color(nsColor: Palette.ink), lineWidth: 2)).offset(x: 26, y: -26)
                }
            }
            .scaleEffect(pose.scale)
            .offset(x: pose.shake, y: pose.bounce)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.35), value: phase.name)
    }
}

/// Animation values derived from the phase and the clock. With Reduce Motion `t` is 0: no movement.
struct Pose {
    var scale: CGFloat = 1, bounce: CGFloat = 0, shake: CGFloat = 0, pulse: CGFloat = 0, progress: CGFloat = 0
    var eyeOpen: CGFloat = 1, eyeLift: CGFloat = 0, mouthOpen: CGFloat = 0, smile: CGFloat = 0.5
    var bodyColor = Palette.cream

    init(phase: MascotPhase, t: TimeInterval) {
        let animated = t != 0
        // Blink about every 4 to 7 seconds, for 0.15 s.
        let cycle = 5.5 + 1.5 * sin(t / 11)
        let blink = animated && t.truncatingRemainder(dividingBy: cycle) < 0.15
        eyeOpen = blink ? 0.1 : 1
        switch phase {
        case .idle, .hidden:
            scale = animated ? 1 + 0.025 * CGFloat(sin(t * 2 * .pi / 4)) : 1
        case .listening:
            eyeOpen = 1.15; smile = 0.2
            progress = CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
        case .thinking:
            eyeLift = -4; smile = 0.1
            pulse = animated ? CGFloat(0.5 + 0.5 * sin(t * 2 * .pi / 1.4)) : 0.6
        case .speaking:
            smile = 0.7
            mouthOpen = animated ? CGFloat(abs(sin(t * 9)) * 0.8) : 0.4
        case .nudging(_, let opened):
            smile = 0.8
            if animated && !opened { bounce = -CGFloat(abs(sin(t * 2 * .pi / 1.1))) * 7 }
        case .blocked:
            eyeOpen = 0.25; smile = -0.3
            if animated { shake = CGFloat(sin(t * 28)) * 3 * CGFloat(max(0, 1 - t.truncatingRemainder(dividingBy: 2.0))) }
        case .offline:
            eyeOpen = 0.35; smile = -0.1; bodyColor = Palette.offline
        case .permission:
            eyeOpen = 0.9; smile = 0
        }
    }
}

/// A rounded rectangle with a small tail at the bottom left, like a speech bubble.
struct BodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.84)
        let path = Path(roundedRect: body, cornerRadius: body.height * 0.42, style: .continuous)
        var tail = Path()
        tail.move(to: CGPoint(x: body.minX + body.width * 0.2, y: body.maxY - 8))
        tail.addLine(to: CGPoint(x: body.minX + body.width * 0.14, y: rect.maxY))
        tail.addQuadCurve(to: CGPoint(x: body.minX + body.width * 0.46, y: body.maxY - 8), control: CGPoint(x: body.minX + body.width * 0.32, y: body.maxY + 2))
        tail.closeSubpath()
        // A single outline, so the stroke runs around the tail instead of across it.
        return path.union(tail)
    }
}

struct Face: View {
    let pose: Pose

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let ink = Color(nsColor: Palette.ink)
            ZStack {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Capsule().fill(ink)
                        .frame(width: 7, height: max(2, 15 * pose.eyeOpen))
                        .position(x: w / 2 + side * w * 0.17, y: h * 0.4 + pose.eyeLift)
                }
                Mouth(smile: pose.smile, open: pose.mouthOpen)
                    .stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .frame(width: w * 0.3, height: h * 0.18)
                    .position(x: w / 2, y: h * 0.64)
            }
        }
    }
}

/// A mouth arc. `smile` bends it (negative frowns); `open` drops the lower lip while speaking.
struct Mouth: Shape {
    var smile: CGFloat
    var open: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: mid))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: mid), control: CGPoint(x: rect.midX, y: mid + rect.height * smile))
        if open > 0.05 {
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: mid), control: CGPoint(x: rect.midX, y: mid + rect.height * (smile + open * 1.6)))
        }
        return path
    }
}

/// The speech bubble: a saved card, a waiting nudge, an error with Retry, or the permission explainer.
struct BubbleView: View {
    @ObservedObject var model: CompanionModel
    @Environment(\.accessibilityReduceTransparency) private var opaque

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(opaque ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(nsColor: model.phase.accent).opacity(0.8), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: model.phase.symbol).foregroundStyle(Color(nsColor: model.phase.accent))
            Text(model.phase.label()).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Button { model.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.borderless).accessibilityLabel("Dismiss").keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .speaking(let card):
            VStack(alignment: .leading, spacing: 8) {
                Text(card.summary).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(card.observation).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label { Text(card.nextStep).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "arrow.forward.circle.fill").foregroundStyle(Color(nsColor: Palette.model)) }
                Text(card.isPreview ? "Sample text for previewing the companion" : "\(card.appName) · Muse Spark Open · receipt \(card.receiptID.prefix(8))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("Undo") { model.onUndo() }.disabled(card.isPreview)
                    Button("Ask Muse") { model.onAskMuse() }.disabled(card.isPreview)
                    Spacer()
                }.controlSize(.small)
            }
        case .nudging(let nudge, _):
            VStack(alignment: .leading, spacing: 8) {
                Text(nudge.detail).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text("Goal: \(nudge.goalTitle) · from the shared record").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .offline(_, let retryable):
            HStack {
                Text("Nothing was saved.").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                if retryable { Button("Retry") { model.onRetry() }.controlSize(.small) }
            }
        case .permission:
            VStack(alignment: .leading, spacing: 8) {
                Text("To read a window you choose, macOS needs to allow Screen Recording for \(MascotName). It reads only the front window, and only when you press ⌃⌥Space or click. Pixels never leave this Mac.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Continue") { model.onPermissionContinue() }
                    Button("Open Settings") { model.onOpenSettings() }
                    Spacer()
                }.controlSize(.small)
            }
        default:
            EmptyView()
        }
    }
}
