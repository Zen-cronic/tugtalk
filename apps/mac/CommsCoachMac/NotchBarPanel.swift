import AppKit
import CoreText
import ScreenContextCore
import SwiftUI

/// What the top bar's view needs from its controller: sizes, whether it is open, and its actions.
@MainActor
final class NotchBarUI: ObservableObject {
    /// Drives the spring: the label grows to the open panel's size.
    @Published var expanded = false
    /// The open panel's body is in the view tree (from just before it opens until it has shrunk back).
    @Published var mounted = false
    /// The camera housing's width, or nil on a display without a notch.
    @Published var housingWidth: CGFloat?
    /// The status row's height: the menu bar's.
    @Published var band: CGFloat = 24
    @Published var barSize = CGSize(width: 120, height: 24)
    /// The left wing: from the bar's left edge to the housing (or to the right wing without a notch).
    @Published var leftWing: CGFloat = 0
    /// The right wing's width; zero when there is nothing to show or the menu bar has no room.
    @Published var rightWing: CGFloat = 0
    /// Where the housing starts in the open panel, from its left edge.
    @Published var openHousingX: CGFloat = 0
    /// The open body's measured height.
    @Published var bodyHeight: CGFloat = 0
    /// Which of the two latest cards came last.
    @Published var latest: Latest = .none
    @Published var holdingTalk = false
    /// The settings view is showing in place of the card.
    @Published var settingsOpen = false
    /// A card opened the panel by itself (it shows compact until the pointer rests on it).
    @Published var openedByCard = false
    /// The pointer has rested on the panel: show everything.
    @Published var dwelled = false

    enum Latest { case none, round, card }

    static let openWidth: CGFloat = 432
    /// Room under the open panel for the spring's overshoot.
    static let slack: CGFloat = 24
    static let inset: CGFloat = 10

    var openHeight: CGFloat { band + bodyHeight }
    var glyph: CGFloat { housingWidth == nil ? 16 : 18 }

    var onPointer: (Bool) -> Void = { _ in }
    var onBarClick: () -> Void = {}
    var onClose: () -> Void = {}
    var onTalkDown: () -> Void = {}
    var onTalkUp: () -> Void = {}
    var onReadWindow: () -> Void = {}
    var onHide: () -> Void = {}
    var onHome: (TugHome) -> Void = { _ in }
}

extension MascotPhase {
    /// The companion's state as the top bar shows it.
    func barInput(talking: Bool, now: Date = Date()) -> NotchBarInput {
        switch self {
        case .idle: .idle
        case .listening: .readingWindow
        case .thinking, .voiceThinking: .thinking
        case .speaking: .contextCard(talking: talking)
        case .nudging(_, let opened): .nudge(opened: opened)
        case .blocked: .blocked
        case .offline(_, let retryable): .offline(retryable: retryable)
        case .permission, .micPermission: .permission
        case .notice: .notice
        case .hidden: .hidden
        case .voiceListening(let since): .voiceListening(seconds: Int(now.timeIntervalSince(since)))
        case .voiceSpeaking(let card): .voiceReply(finished: card.finished, endsRound: card.endsRound)
        case .voiceError(_, let retryable): .voiceError(retryable: retryable)
        }
    }
}

extension Tok {
    /// The bar's sunflower. Light: the field token. Dark: the same hue at lower brightness, a deeper ochre, so the
    /// bar sits in a dark menu bar without glaring. Ink on it is 6.6:1.
    static func barField(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark ? NSColor(srgbRed: 200 / 255, green: 146 / 255, blue: 43 / 255, alpha: 1) : field
    }
}

/// The status word: Anybody at width 104, one weight lighter and smaller than a card heading, so it sits in the
/// menu bar like menu text. Measured with the same font, so the wing fits it exactly.
@MainActor
enum BarType {
    static let size: CGFloat = 12
    static let ctFont: CTFont = {
        TypeFace.register()
        let axes: [Int: CGFloat] = [0x77647468: 104, 0x77676874: 700]
        let attributes: [CFString: Any] = [kCTFontNameAttribute: "Anybody-Thin", kCTFontVariationAttribute: axes as CFDictionary]
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
    }()
    static var word: Font { (CTFontCopyFamilyName(ctFont) as String) == "Anybody" ? Font(ctFont) : .system(size: size, weight: .semibold) }

    static func width(_ text: String) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont])
        return ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), nil, nil, nil)))
    }

    /// The right wing's mark, in points.
    static func markWidth(_ mark: NotchBarStatus.Mark) -> CGFloat {
        switch mark {
        case .none: 0
        case .recordLight: 52
        case .dots: 18
        case .wave: 15
        case .symbol: 16
        }
    }
}

/// The label that hangs from the top edge: square top corners against the screen edge or the menu bar,
/// rounded bottom corners. `open` leaves the top edge out, for the outline.
struct HangingLabel: Shape {
    var radius: CGFloat
    var open = false

    func path(in r: CGRect) -> Path {
        let k = min(radius, r.height / 2, r.width / 2)
        var p = Path()
        if open {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
        } else {
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - k))
        p.addQuadCurve(to: CGPoint(x: r.minX + k, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - k), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        if !open { p.closeSubpath() }
        return p
    }
}

/// Tug's string from the glyph. Collapsed it is the glyph's own short curl, or held up for "Your turn"; open, it
/// drops into the panel and the card hangs from it. Animatable, so the spring swings it.
struct DropString: Shape {
    var drop: CGFloat
    var raise: CGFloat
    let root: CGPoint
    let unit: CGFloat
    let hook: CGPoint

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(drop, raise) }
        set { drop = newValue.first; raise = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        func mix(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k) }
        func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: root.x + dx * unit, y: root.y + dy * unit) }
        // The glyph's curl (TugGlyph's string, in its 18-unit box), or held up beside the can.
        let c1 = mix(mix(at(1.4, 4.4), at(3.0, 4.5), raise), CGPoint(x: root.x + 12, y: root.y + 18), drop)
        let c2 = mix(mix(at(6.2, 4.0), at(11.5, -2), raise), CGPoint(x: hook.x - 7, y: hook.y - 14), drop)
        let end = mix(mix(at(9.2, -1.2), at(9.6, -11.5), raise), hook, drop)
        var p = Path()
        p.move(to: root)
        p.addCurve(to: end, control1: c1, control2: c2)
        return p
    }
}

/// The whole top bar: the collapsed label, or the open panel it grows into.
struct NotchBarView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var ui: NotchBarUI
    @Environment(\.reduceMotionOn) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var size: CGSize {
        ui.expanded ? CGSize(width: NotchBarUI.openWidth, height: ui.openHeight) : ui.barSize
    }

    private var spring: Animation? { reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2) }
    private var swing: Animation? { reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.34) }

    private var status: NotchBarStatus { NotchBarStatus.make(model.phase.barInput(talking: model.talking)) }

    var body: some View {
        label
            .animation(spring, value: ui.expanded)
            .animation(spring, value: ui.openHeight)
            .animation(spring, value: ui.barSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.tugAwake, !model.isPresenting)
    }

    private var bandFill: NSColor { status.inverted ? Tok.inkFixed : Tok.barField(scheme) }

    private var label: some View {
        let shape = HangingLabel(radius: 12)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(Tok.surface))
            Rectangle().fill(Color(bandFill)).frame(height: ui.band)
            Rectangle().fill(Color(Tok.cardEdge).opacity(0.35)).frame(height: 0.5).offset(y: ui.band)
                .opacity(ui.expanded ? 1 : 0)
            string
            VStack(alignment: .leading, spacing: 0) {
                row.frame(width: size.width, height: ui.band)
                if ui.mounted {
                    NotchBarBody(model: model, ui: ui)
                        .frame(width: NotchBarUI.openWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geo in Color.clear.preference(key: BodyHeight.self, value: geo.size.height) })
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        // One edge in both looks: a hairline, no offset lip.
        .overlay(HangingLabel(radius: 12, open: true).stroke(Color(Tok.cardEdge).opacity(0.6), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onHover { ui.onPointer($0) }
        .onPreferenceChange(BodyHeight.self) { height in
            if abs(ui.bodyHeight - height) > 0.5 { ui.bodyHeight = height }
        }
    }

    /// Where the string leaves the glyph, in the label's coordinates: under the can, so a breath never shows a gap.
    private var root: CGPoint {
        let unit = ui.glyph / 18
        return CGPoint(x: NotchBarUI.inset + 8 * unit, y: (ui.band - ui.glyph) / 2 + 13.6 * unit)
    }

    /// The hook the card hangs from, just above its heading.
    private var hook: CGPoint { CGPoint(x: root.x + 3, y: ui.band + 10) }

    private var string: some View {
        let shape = DropString(drop: ui.expanded ? 1 : 0, raise: status.face == .turn ? 1 : 0, root: root, unit: ui.glyph / 18, hook: hook)
        let onBand = status.inverted ? Tok.field : Tok.inkFixed
        return ZStack(alignment: .topLeading) {
            shape.stroke(Color(onBand), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .mask(alignment: .top) { Rectangle().frame(height: ui.band) }
            shape.stroke(Tok.tugString(scheme), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .mask(alignment: .top) { Rectangle().padding(.top, ui.band) }
            Circle().strokeBorder(Tok.tugString(scheme), lineWidth: 1.5)
                .background(Circle().fill(Color(Tok.surface)))
                .frame(width: 7, height: 7)
                .position(hook)
                .opacity(ui.expanded ? 1 : 0)
        }
        .animation(swing, value: ui.expanded)
        .animation(swing, value: status.face)
        .allowsHitTesting(false)
    }

    private var isListening: Bool { if case .voiceListening = model.phase { return true } else { return false } }

    private var row: some View {
        // The clock ticks once a second only while the microphone is open, for the timer.
        TimelineView(.animation(minimumInterval: 1, paused: !isListening)) { context in
            let status = NotchBarStatus.make(model.phase.barInput(talking: model.talking, now: context.date))
            let conflict = model.hotkeyNotice != nil && status.mark == .none && !status.inverted
            let mark: NotchBarStatus.Mark = conflict ? .symbol("exclamationmark.circle") : status.mark
            let ink = status.inverted ? Tok.field : Tok.inkFixed
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    TugGlyphFace(face: status.face, onInk: status.inverted, awake: !model.isPresenting)
                        .frame(width: ui.glyph, height: ui.glyph)
                    Text(status.word).font(BarType.word).lineLimit(1).fixedSize()
                    // No room past the notch: the record light comes over beside the word.
                    if ui.rightWing == 0, !ui.expanded, case .recordLight = mark { RecordLight() }
                }
                .padding(.leading, NotchBarUI.inset)
                .frame(width: ui.expanded && ui.housingWidth != nil ? ui.openHousingX : ui.leftWing, alignment: .leading)
                if let housing = ui.housingWidth { Color.clear.frame(width: housing) }
                // A mark only when there is one and room for it; otherwise the row still fills the label.
                if mark != .none, ui.rightWing > 0 || ui.expanded {
                    BarMark(mark: mark)
                        .padding(.trailing, NotchBarUI.inset)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color(ink))
            // Everything on the band is drawn for its own ground, not the system look.
            .environment(\.colorScheme, .light)
            .contentShape(Rectangle())
            .onTapGesture { ui.onBarClick() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(MascotName), \(status.word)")
            .accessibilityValue(conflict ? model.hotkeyNotice!.replacingOccurrences(of: "⌃⌥", with: "Control Option ") : accessibilityDetail(status))
            .accessibilityHint(ui.expanded ? "Closes the panel." : "Opens the panel.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { ui.onBarClick() }
        }
    }

    private func accessibilityDetail(_ status: NotchBarStatus) -> String {
        if status.inverted { return "Hold Control Option T to answer." }
        switch status.mark {
        case .none: return "Hold Control Option T and talk."
        case .recordLight(let time): return "Recording, \(time)"
        default: return ""
        }
    }
}

private struct BodyHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The one small mark past the notch: the record light, three dots, a wave, or an icon.
struct BarMark: View {
    let mark: NotchBarStatus.Mark

    var body: some View {
        switch mark {
        case .none: EmptyView()
        case .recordLight(let time):
            HStack(spacing: 5) {
                RecordLight()
                Text(time).font(TypeFace.mono(12, weight: 600)).monospacedDigit()
            }
        case .dots: BarDots()
        case .wave: SpeakingWave(color: Tok.inkFixed)
        case .symbol(let name): Image(systemName: name).font(.system(size: 12, weight: .semibold))
        }
    }
}

/// Three full-ink dots that rise in turn: Tug is thinking. Still with Reduce Motion.
struct BarDots: View {
    @Environment(\.reduceMotionOn) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let lift = reduceMotion ? 0 : max(0, sin(t * 2 * .pi / 1.2 - Double(i) * 0.8)) * 2
                    Circle().fill(Color(Tok.inkFixed)).frame(width: 4, height: 4).offset(y: -lift)
                }
            }
        }
        .frame(width: 18, height: 10)
    }
}

/// The record light on sunflower: a white disc with an ink edge, so the red reads against yellow, and the red
/// dot inside it, the same saturated red in both looks, with a thin red ring that breathes while the microphone is open.
struct RecordLight: View {
    static let side: CGFloat = 14
    @Environment(\.reduceMotionOn) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2)
            ZStack {
                Circle().fill(Color(Tok.labelWhite))
                Circle().strokeBorder(Color(Tok.inkFixed), lineWidth: 1)
                // The dot stays the full record red; only a thin ring inside the disc breathes.
                Circle().strokeBorder(Color(Tok.record).opacity(0.2 + 0.6 * pulse), lineWidth: 1.2).frame(width: 11, height: 11)
                Circle().fill(Color(Tok.record)).frame(width: 7, height: 7)
            }
            .frame(width: Self.side, height: Self.side)
        }
        .accessibilityLabel("Recording")
    }
}

/// The open panel's body: one container with the card that hangs from Tug's string and one row of actions, or the
/// settings view behind the gear.
struct NotchBarBody: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var ui: NotchBarUI

    private var status: NotchBarStatus { NotchBarStatus.make(model.phase.barInput(talking: model.talking)) }
    /// A card that opened the panel by itself shows one or two lines until the pointer rests on it.
    private var compact: Bool { status.showsCard && status.compact && ui.openedByCard && !ui.dwelled }
    private var yourTurn: Bool { status.inverted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ui.settingsOpen {
                NotchBarSettings(model: model, onHome: ui.onHome, onDone: { ui.settingsOpen = false })
            } else {
                card
                if !compact { actions }
            }
        }
        .padding(.top, 20).padding(.horizontal, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { SampleCornerTag(shown: showsSample).padding(.top, 1).padding(.trailing, 8) }
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if status.showsCard {
                liveCard
            } else {
                latestCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var liveCard: some View {
        switch model.phase {
        case .voiceSpeaking(let card):
            ReplyCard(card: card, compact: compact, onClose: close, onLayout: { model.layoutNeeded() })
        case .speaking(let card):
            ContextCardView(card: card, compact: compact, pointing: model.pointing, onClose: close, onUndo: { model.onUndo() })
        case .notice(let text):
            HStack(alignment: .top, spacing: 8) {
                NoticeText(text: text)
                Spacer(minLength: 4)
                CloseButton(action: close)
            }
        default:
            HStack(alignment: .center, spacing: 8) {
                if CardTone(model.phase) == .problem { Image(systemName: model.phase.symbol).font(.system(size: 14, weight: .bold)) }
                Text(noWidow(model.phase.heading)).font(TypeFace.display(17, weight: 800)).lineLimit(2)
                Spacer(minLength: 4)
                CloseButton(action: close)
            }
            .foregroundStyle(Color(Tok.ink))
            CardBody(model: model)
        }
    }

    private func close() { model.dismiss(); ui.onClose() }

    @ViewBuilder private var latestCard: some View {
        if let notice = model.hotkeyNotice {
            Text("Shortcut").font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted))
            NoticeText(text: notice)
        } else if ui.latest == .round, let round = model.latestVoiceCard {
            HStack {
                Text("Latest round").font(TypeFace.body(12, weight: 600))
                Spacer()
                if let n = round.round { Text("Round \(n)").font(TypeFace.body(12, weight: 600)) }
            }
            .foregroundStyle(Color(Tok.muted))
            if let number = LatestRoundNumber.make(summary: round.summary, latest: round.metrics) { RoundNumber(number: number) }
            SaidDisclosure(quote: round.quote, transcript: round.transcriptSnippet, onLayout: { model.layoutNeeded() })
            RecordingNote(note: round.recordingNote)
        } else if ui.latest == .card, let card = model.lastCard {
            Text("Latest card · \(card.appName)").font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted))
            CoachText(card.observation)
            Instruction(label: "Next step", text: card.nextStep)
        } else {
            Text("No round yet").font(TypeFace.display(17, weight: 800)).foregroundStyle(Color(Tok.ink))
            ShortcutLine(text: "Hold ⌃⌥T and answer out loud.", font: TypeFace.body(14, weight: 600), ink: Tok.muted)
        }
    }

    /// The card on show has a primary button of its own (Retry, Continue): Talk steps back to a plain button.
    private var talkIsPrimary: Bool { !(status.showsCard && !status.compact) }

    private var actions: some View {
        HStack(spacing: 6) {
            // In "Your turn" the yellow chip is the one talk prompt.
            if !yourTurn { NotchTalkButton(ui: ui, primary: talkIsPrimary) }
            Button("Read this window") { ui.onReadWindow() }
                .buttonStyle(BarButtonStyle())
                .accessibilityHint("Reads the window in front, like Control-Option-Space.")
            if model.lastCard != nil {
                Button("Ask Muse") { model.onAskMuse() }
                    .buttonStyle(BarButtonStyle())
                    .help("Open this in Muse, Meta's assistant")
                    .accessibilityHint("Opens this in Muse, Meta's assistant.")
            }
            Spacer(minLength: 0)
            IconButton(symbol: "gearshape", label: "Settings") { ui.settingsOpen = true }
            IconButton(symbol: "eye.slash", label: "Hide Tug (⌃⌥H)") { ui.onHide() }
        }
    }

    private var showsSample: Bool {
        if ui.settingsOpen { return false }
        switch model.phase {
        case .voiceSpeaking(let card): return card.isPreview
        case .speaking(let card): return card.isPreview
        default:
            if status.showsCard { return false }
            if ui.latest == .round { return model.latestVoiceCard?.isPreview ?? false }
            if ui.latest == .card { return model.lastCard?.isPreview ?? false }
            return false
        }
    }
}

/// The panel's secondary buttons: the cart button's look on one line, with a little less padding so the one row of
/// actions fits the panel. At least 32 pt tall.
struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        configuration.label
            .font(TypeFace.body(14, weight: 650)).lineLimit(1).fixedSize()
            .foregroundStyle(Color(Tok.ink))
            .padding(.horizontal, 11).frame(minHeight: 32)
            .background(shape.fill(Color(Tok.surface)))
            .overlay(shape.strokeBorder(Color(Tok.edge), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(shape)
    }
}

/// "Sample": one small tag in the panel's corner on Debug previews. Never in a normal build, and `-noSampleTag YES`
/// hides it in captures for the video.
struct SampleCornerTag: View {
    let shown: Bool
    var body: some View {
        #if DEBUG
        if shown, !UserDefaults.standard.bool(forKey: "noSampleTag") {
            Text("Sample").font(TypeFace.body(11, weight: 600)).foregroundStyle(Color(Tok.muted))
                .padding(.horizontal, 6).frame(height: 18)
                .thinEdge(radius: 5)
        }
        #endif
    }
}

struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(Tok.ink))
        .accessibilityLabel("Close card")
    }
}

/// A square button with an icon, a thin edge and a tooltip; VoiceOver reads its label.
struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(Tok.ink))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .thinEdge(radius: 9)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A spoken reply. Compact: what kind of move and the question, in one or two lines. On hover: your words behind
/// one disclosure, one measured number, and the one talk prompt.
struct ReplyCard: View {
    let card: VoiceCard
    let compact: Bool
    var onClose: () -> Void
    var onLayout: () -> Void

    private var yourTurn: Bool { card.finished && !card.endsRound }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(card.endsRound ? "Round done" : card.moveTitle).font(TypeFace.display(compact ? 15 : 17, weight: 800))
            Spacer(minLength: 4)
            if let round = card.round { Text("Round \(round)").font(TypeFace.body(12, weight: 650)).foregroundStyle(Color(Tok.muted)) }
            CloseButton(action: onClose)
        }
        .foregroundStyle(Color(Tok.ink))
        if let summary = card.summary, let number = LatestRoundNumber.make(summary: summary, latest: nil) {
            RoundNumber(number: number)
        }
        Text(noWidow(card.question)).font(TypeFace.body(15, weight: 600)).lineSpacing(2.5).foregroundStyle(Color(Tok.ink))
            .lineLimit(compact ? 2 : nil).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Question: \(card.question)")
        if !compact {
            if card.summary == nil {
                SaidDisclosure(quote: card.quote, transcript: card.transcriptSnippet, onLayout: onLayout)
                if let stat = LatestRoundNumber.make(summary: nil, latest: card.metrics) {
                    HabitCount(count: stat.value, habit: stat.habit, caption: "in this answer")
                }
                RecordingNote(note: card.recordingNote)
            } else {
                ShortcutLine(text: "Hold ⌃⌥T to start again", font: TypeFace.body(13, weight: 600), ink: Tok.muted)
            }
        }
        if yourTurn { TurnChip() }
    }
}

/// A saved context card. Compact: the observation in two lines. On hover: the next step and Undo.
struct ContextCardView: View {
    let card: ContextCard
    let compact: Bool
    let pointing: Bool
    var onClose: () -> Void
    var onUndo: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(card.replayed ? "Already saved" : "Card saved").font(TypeFace.display(compact ? 15 : 17, weight: 800))
            Spacer(minLength: 4)
            CloseButton(action: onClose)
        }
        .foregroundStyle(Color(Tok.ink))
        Text(noWidow(card.observation)).font(TypeFace.body(15, weight: 600)).lineSpacing(2.5).foregroundStyle(Color(Tok.ink))
            .lineLimit(compact ? 2 : nil).fixedSize(horizontal: false, vertical: true)
        if !compact {
            Instruction(label: "Next step", text: card.nextStep)
            if pointing {
                Label { Text("Circled on your \(card.appName) window").font(TypeFace.body(13, weight: 550)) } icon: { Image(systemName: "circle.circle") }
                    .foregroundStyle(Color(Tok.ink))
            }
            if !card.isPreview { Button("Undo", action: onUndo).buttonStyle(CartButtonStyle(primary: false)) }
        }
    }
}

/// "You said “I think”", which opens to the transcript with those words marked. One control for both.
struct SaidDisclosure: View {
    let quote: String?
    let transcript: String
    var onLayout: () -> Void
    @State private var open = false

    var body: some View {
        if quote != nil || !transcript.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    open.toggle()
                    onLayout()
                } label: {
                    HStack(spacing: 6) {
                        Text(quote == nil ? "What you said" : "You said").font(TypeFace.body(12, weight: 550)).foregroundStyle(Color(Tok.muted))
                        if let quote { Text("\u{201C}\(quote)\u{201D}").font(TypeFace.body(15, weight: 700)).foregroundStyle(Color(Tok.ink)) }
                        if !transcript.isEmpty {
                            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(Tok.muted))
                        }
                    }
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .thinEdge(radius: 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(transcript.isEmpty)
                .accessibilityLabel(quote.map { "You said \($0)" } ?? "What you said")
                .accessibilityHint(open ? "Hides what you said." : "Shows what you said.")
                if open, !transcript.isEmpty { Transcript(text: transcript, mark: quote) }
            }
        }
    }
}

/// A notice: its first sentence on one line with the keys as keycaps, the rest underneath in muted text that wraps.
struct NoticeText: View {
    let text: String
    var body: some View {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
        // The first line ends on the keycaps, without a stray full stop after them.
        let first = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? text
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        VStack(alignment: .leading, spacing: 4) {
            ShortcutLine(text: first, font: TypeFace.body(15, weight: 650))
            if !rest.isEmpty {
                Text(rest).font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.replacingOccurrences(of: "⌃⌥", with: "Control Option "))
    }
}

/// "Recording kept": shown when Keep my recordings is on and the server kept this answer's audio.
struct RecordingNote: View {
    let note: String?
    var body: some View {
        if let note {
            Label { Text(note).font(TypeFace.body(13, weight: 550)) } icon: { Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)) }
                .foregroundStyle(Color(Tok.muted))
        }
    }
}

/// "Your turn · hold ⌃⌥T": the one talk prompt once a question has been asked. Its edge pulses slowly; still with
/// Reduce Motion.
struct TurnChip: View {
    @Environment(\.reduceMotionOn) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let pulse = reduceMotion ? 1 : 0.55 + 0.45 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.0)
            HStack(spacing: 8) {
                Text("Your turn").font(TypeFace.body(14, weight: 700))
                ShortcutLine(text: "hold ⌃⌥T", font: TypeFace.body(13, weight: 600), ink: Tok.inkFixed)
            }
            .foregroundStyle(Color(Tok.inkFixed))
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(Tok.barField(scheme))))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(Tok.inkFixed).opacity(0.25 + 0.5 * pulse), lineWidth: 1.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your turn. Hold Control Option T to answer.")
    }
}

/// The habit's word for a count, with "unsure words" for hedges.
enum HabitWord {
    static func word(_ habit: RoundSummary.Habit, _ count: Int) -> String {
        switch habit {
        case .filler: count == 1 ? "filler" : "fillers"
        case .hedge: count == 1 ? "unsure word" : "unsure words"
        case .restart: count == 1 ? "restart" : "restarts"
        }
    }
}

/// A measured habit as a chip in its own colour, in Hanken Grotesk in both looks, always with its word.
struct HabitCount: View {
    let count: Int
    let habit: RoundSummary.Habit
    var caption: String? = nil
    /// False beside a big number that already says it.
    var showsCount = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let (fill, edge) = HabitChip.colours(habit)
        let dark = scheme == .dark
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if showsCount { Text("\(count)").font(TypeFace.body(15, weight: 800)).monospacedDigit() }
                Text(HabitWord.word(habit, count)).font(TypeFace.body(13, weight: 650))
            }
            .foregroundStyle(Color(dark ? Tok.ink : Tok.inkFixed))
            .padding(.horizontal, 9).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(dark ? edge : fill).opacity(dark ? 0.3 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(edge).opacity(0.6), lineWidth: 1))
            if let caption { Text(caption).font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Measured by code: \(count) \(HabitWord.word(habit, count))\(caption.map { " \($0)" } ?? "")")
    }
}

/// The round's one big number. An improvement sits on sunflower with the change in words; otherwise the habit's chip.
struct RoundNumber: View {
    let number: LatestRoundNumber
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(number.value)").font(TypeFace.display(44, weight: 850)).monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                if number.improved {
                    Text(HabitWord.word(number.habit, number.value)).font(TypeFace.body(16, weight: 750))
                } else {
                    HabitCount(count: number.value, habit: number.habit, showsCount: false)
                }
                Text(number.caption).font(TypeFace.body(13, weight: 550)).foregroundStyle(Color(number.improved ? Tok.inkFixed : Tok.muted))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(number.improved ? Tok.inkFixed : Tok.ink))
        .padding(.horizontal, number.improved ? 14 : 0).padding(.vertical, number.improved ? 6 : 0)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(number.improved ? Color(Tok.barField(scheme)) : Color.clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number.value) \(HabitWord.word(number.habit, number.value)) \(number.caption)")
    }
}

/// Hold to talk, like holding ⌃⌥T: pressing opens the microphone, letting go sends the answer.
struct NotchTalkButton: View {
    @ObservedObject var ui: NotchBarUI
    var primary = true
    var body: some View {
        HStack(spacing: 7) {
            if ui.holdingTalk { RecordDot() } else { Image(systemName: "mic.fill").font(.system(size: 13, weight: .bold)) }
            Text(ui.holdingTalk ? "Listening" : "Talk").font(TypeFace.body(14, weight: 650))
        }
        .foregroundStyle(Color(primary ? Tok.onAction : Tok.ink))
        .fixedSize()
        .padding(.horizontal, 12).frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(primary ? Tok.action : Tok.surface)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(Tok.edge), lineWidth: primary ? 0 : 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !ui.holdingTalk { ui.holdingTalk = true; ui.onTalkDown() } }
            .onEnded { _ in ui.onTalkUp() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talk")
        .accessibilityHint("Hold to talk, let go to send. Control-Option-T does the same.")
        .accessibilityAddTraits(.isButton)
    }
}

/// The settings view behind the gear: the reply voice, the language, where Tug lives, and hiding in meetings.
struct NotchBarSettings: View {
    @ObservedObject var model: CompanionModel
    var onHome: (TugHome) -> Void
    var onDone: () -> Void
    @State private var voice = Settings.replyVoice
    @State private var language = Settings.voiceLanguage
    @State private var home = Settings.tugHome
    @State private var hideInMeetings = Settings.autoHideInMeetings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings").font(TypeFace.display(17, weight: 800)).foregroundStyle(Color(Tok.ink))
                Spacer()
                Button("Done", action: onDone).buttonStyle(CartButtonStyle(primary: false))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Voice") {
                    CartSegmented(label: "Voice", options: Settings.ReplyVoice.allCases.map { ($0, $0.title) }, selection: $voice)
                }
                row("Language") {
                    CartSegmented(label: "Language", options: [(VoiceLanguage.en, "English"), (.fr, "French")], selection: $language)
                }
                row("Tug lives in") {
                    CartSegmented(label: "Where Tug lives", options: TugHome.allCases.map { ($0, $0.title) }, selection: $home)
                }
                row("Presenting") {
                    CartSegmented(label: "Presenting", options: [(true, "Hide in meetings"), (false, "Always show")], selection: $hideInMeetings)
                }
            }
        }
        .onChange(of: voice) { _, v in Settings.replyVoice = v }
        .onChange(of: language) { _, v in Settings.voiceLanguage = v }
        .onChange(of: home) { _, v in onHome(v) }
        .onChange(of: hideInMeetings) { _, v in
            Settings.autoHideInMeetings = v
            if !v { model.inMeetingApp = false }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title).font(TypeFace.body(13, weight: 600)).foregroundStyle(Color(Tok.muted)).gridColumnAlignment(.leading)
            content()
        }
    }
}

/// A row of choices in a thin edge; the chosen one has a neutral tint and an ink edge. Each choice is a button at
/// least 28 pt tall inside a 32 pt control, and VoiceOver reads which one is selected.
struct CartSegmented<Value: Hashable>: View {
    let label: String
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Button { selection = option.0 } label: {
                    // Ink fill stays for the one primary action, sunflower for the band and good news.
                    Text(option.1).font(TypeFace.body(13, weight: 650))
                        .foregroundStyle(Color(chosen ? Tok.ink : Tok.muted))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chosen ? Color(Tok.rule) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(Tok.ink).opacity(chosen ? 0.55 : 0), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.1)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .thinEdge(radius: 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The small Tug in the bar, with a face per state so it reads at a glance: brows up while listening, eyes closed
/// while thinking, mouth moving while speaking. At rest it bobs and blinks on Core Animation, from the same loops as
/// the big Tug (`TugBreath`, `BlinkSchedule`). Every loop stops while the window is hidden or covered, while
/// presenting, and with Reduce Motion. Its string is drawn by the bar, so it can drop and be held up.
struct TugGlyphFace: NSViewRepresentable {
    let face: NotchBarStatus.Face
    let onInk: Bool
    let awake: Bool
    func makeNSView(context: Context) -> TugGlyphFaceView { TugGlyphFaceView() }
    func updateNSView(_ view: TugGlyphFaceView, context: Context) {
        view.configure(.init(face: face, onInk: onInk, awake: awake && !Motion.forced))
    }
}

final class TugGlyphFaceView: NSView {
    struct Look: Equatable { var face: NotchBarStatus.Face; var onInk: Bool; var awake: Bool }
    enum Art: Hashable { case open, half, shut, brows, mouthOpen, mouthSmall }

    private let can = CALayer()
    private var look: Look?
    private var images: [Art: CGImage] = [:]
    private var built: (CGSize, CGFloat, Bool)?
    private var visible = true
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(can)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ look: Look) {
        guard look != self.look else { return }
        self.look = look
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let look else { return }
        let scale = window?.backingScaleFactor ?? 2
        if built.map({ $0.0 != bounds.size || $0.1 != scale || $0.2 != look.onInk }) ?? true {
            built = (bounds.size, scale, look.onInk)
            let colour = look.onInk ? Tok.field : Tok.inkFixed
            images = [Art.open, .half, .shut, .brows, .mouthOpen, .mouthSmall].reduce(into: [:]) { all, art in
                all[art] = Self.image(bounds.size, scale, art, colour)
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        can.frame = bounds
        can.contentsScale = scale
        CATransaction.commit()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for (name, object) in [(NSWindow.didChangeOcclusionStateNotification, window as AnyObject),
                               (NSApplication.didChangeOcclusionStateNotification, NSApp as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.occlusionChanged() }
            })
        }
        occlusionChanged()
    }

    private func occlusionChanged() {
        guard let window else { return }
        let now = window.isVisible && window.occlusionState.contains(.visible)
        if now != visible { visible = now; refresh() }
    }

    private var moving: Bool { (look?.awake ?? false) && visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func still(_ face: NotchBarStatus.Face) -> Art {
        switch face {
        case .listening: .brows
        case .thinking: .shut
        case .speaking: .mouthOpen
        case .rest, .turn, .still: .open
        }
    }

    private func refresh() {
        guard let look else { return }
        can.removeAllAnimations()
        can.contents = images[still(look.face)]
        guard moving else { return }
        let begin = CACurrentMediaTime()
        switch look.face {
        case .rest:
            let unit = bounds.height / 18
            let moments = TugBreath.moments(count: 36)
            let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bob.values = moments.map { TugBreath.bob(at: $0) * unit * 0.9 }
            bob.keyTimes = moments.map { NSNumber(value: $0 / TugBreath.period) }
            bob.duration = TugBreath.period
            loop(bob, begin, "bob")
            var rng = SystemRandomNumberGenerator()
            let schedule = BlinkSchedule.random(using: &rng)
            let frames = schedule.keyframes
            let arts: [Art] = frames.eyes.map { $0 == .open ? .open : $0 == .half ? .half : .shut }
            let values = arts.compactMap { images[$0] }
            guard values.count == arts.count else { return }
            let blink = CAKeyframeAnimation(keyPath: "contents")
            blink.calculationMode = .discrete
            blink.values = values
            blink.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
            blink.duration = schedule.loop
            loop(blink, begin, "blink")
        case .speaking:
            // The mouth opens and closes about six times a second while Tug speaks.
            guard let open = images[.mouthOpen], let small = images[.mouthSmall] else { return }
            let talk = CAKeyframeAnimation(keyPath: "contents")
            talk.calculationMode = .discrete
            talk.values = [open, small, open, small]
            talk.keyTimes = [0, 0.3, 0.5, 0.8, 1]
            talk.duration = 0.66
            loop(talk, begin, "talk")
        case .listening, .thinking, .turn, .still:
            break
        }
    }

    private func loop(_ animation: CAKeyframeAnimation, _ begin: CFTimeInterval, _ key: String) {
        animation.repeatCount = .infinity
        animation.beginTime = begin
        animation.isRemovedOnCompletion = false
        can.add(animation, forKey: key)
    }

    /// The small one-colour Tug without its string (TugGlyph's can and rim), with the face cut out of it.
    static func image(_ size: CGSize, _ scale: CGFloat, _ art: Art, _ colour: NSColor) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let pixels = NSSize(width: size.width * scale, height: size.height * scale)
        let image = NSImage(size: pixels, flipped: true) { rect in
            guard let g = NSGraphicsContext.current else { return false }
            let k = rect.width / 18
            g.cgContext.scaleBy(x: k, y: k)
            colour.setFill()
            TugGlyph.paths().solid.fill()
            g.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 4.3, y: 3.2, width: 7.4, height: 2.3)).fill()
            for x in [4.9, 8.7] {
                switch art {
                case .open, .mouthOpen, .mouthSmall: NSBezierPath(ovalIn: NSRect(x: x, y: 8.5, width: 2.4, height: 2.7)).fill()
                case .half: NSBezierPath(ovalIn: NSRect(x: x, y: 9.3, width: 2.4, height: 1.3)).fill()
                case .shut: NSBezierPath(roundedRect: NSRect(x: x - 0.1, y: 9.7, width: 2.6, height: 0.8), xRadius: 0.4, yRadius: 0.4).fill()
                case .brows:
                    // Brows raised above wide eyes: listening.
                    NSBezierPath(roundedRect: NSRect(x: x - 0.3, y: 7.0, width: 3.0, height: 1.15), xRadius: 0.55, yRadius: 0.55).fill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: 9.0, width: 2.4, height: 3.0)).fill()
                }
            }
            switch art {
            case .mouthOpen: NSBezierPath(ovalIn: NSRect(x: 6.6, y: 12.0, width: 2.8, height: 2.4)).fill()
            case .mouthSmall: NSBezierPath(roundedRect: NSRect(x: 6.8, y: 12.7, width: 2.4, height: 1.0), xRadius: 0.5, yRadius: 0.5).fill()
            default: break
            }
            g.compositingOperation = .sourceOver
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
