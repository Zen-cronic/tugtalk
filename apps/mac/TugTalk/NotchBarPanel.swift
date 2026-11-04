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
    /// The bare glyph buttons in the open band, and the card's close button: one size, one right inset.
    static let glyphButton: CGFloat = 28
    static let glyphInset: CGFloat = 4

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

/// The status word: Anybody at width 104, one weight lighter and smaller than a card heading, so it sits in the
/// menu bar like menu text. Measured with the same font, so the wing fits it exactly.
@MainActor
enum BarType {
    static let size: CGFloat = 12
    /// Anybody's width axis for the bar word only: at 12 pt the wide cut (104) turns the heavy "r" into a flag, so the
    /// bar uses a narrower cut of the same face. Cards keep 104.
    static let barWidth: CGFloat = 88
    static let ctFont: CTFont = {
        TypeFace.register()
        let axes: [Int: CGFloat] = [0x77647468: barWidth, 0x77676874: 700]
        let attributes: [CFString: Any] = [kCTFontNameAttribute: "Anybody-Thin", kCTFontVariationAttribute: axes as CFDictionary]
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
    }()
    /// "Your turn": the same face, heavier.
    static let ctHeavy: CTFont = {
        TypeFace.register()
        let axes: [Int: CGFloat] = [0x77647468: barWidth, 0x77676874: 820]
        let attributes: [CFString: Any] = [kCTFontNameAttribute: "Anybody-Thin", kCTFontVariationAttribute: axes as CFDictionary]
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
    }()
    private static var bundled: Bool { (CTFontCopyFamilyName(ctFont) as String) == "Anybody" }
    static func word(heavy: Bool = false) -> Font {
        bundled ? Font(heavy ? ctHeavy : ctFont) : .system(size: size, weight: heavy ? .heavy : .semibold)
    }

    static func width(_ text: String, heavy: Bool = false) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): heavy ? ctHeavy : ctFont])
        return ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), nil, nil, nil)))
    }

    /// The left wing's least content: Tug and the widest common word ("Listening", or the heavier "Your turn"), so the
    /// bar's edge holds still between states.
    static func minimumWord(glyph: CGFloat) -> CGFloat { glyph + 6 + max(width("Listening"), width("Your turn", heavy: true)) }

    /// The right wing's one width for every mark, sized to the widest (record light, timer and camera eye), so it
    /// holds still between states too; each mark sits centred in it. Zero when there is no mark.
    static let markSlot: CGFloat = 78
    static func markWidth(_ mark: NotchBarStatus.Mark) -> CGFloat { mark == .none ? 0 : markSlot }
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
/// drops into the panel's left margin and the card hangs from it. Animatable, so the spring swings it.
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
        let c1 = mix(mix(at(1.4, 4.4), at(3.0, 4.5), raise), CGPoint(x: root.x + 8, y: root.y + 9), drop)
        let c2 = mix(mix(at(6.2, 4.0), at(11.5, -2), raise), CGPoint(x: hook.x - 5, y: hook.y - 8), drop)
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

    private var label: some View {
        let shape = HangingLabel(radius: 12)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(Tok.surface))
            // The wing is sunflower in every state, in both looks.
            Rectangle().fill(Color(Tok.barField(scheme))).frame(height: ui.band)
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

    /// The hook the card hangs from: in the body's left margin, level with the top of the title row.
    private var hook: CGPoint { CGPoint(x: root.x + 1, y: ui.band + NotchBarBody.top + 6) }

    private var string: some View {
        let shape = DropString(drop: ui.expanded ? 1 : 0, raise: status.face == .turn ? 1 : 0, root: root, unit: ui.glyph / 18, hook: hook)
        return ZStack(alignment: .topLeading) {
            shape.stroke(Color(Tok.inkFixed), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
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
            let conflict = model.hotkeyNotice != nil && status.mark == .none && !status.emphasized
            let mark: NotchBarStatus.Mark = conflict ? .symbol("exclamationmark.circle") : status.mark
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    TugGlyphFace(face: status.face, awake: !model.isPresenting)
                        .frame(width: ui.glyph, height: ui.glyph)
                    // "Your turn" is the same bare word, heavier, with Tug's string held up.
                    Text(status.word).font(BarType.word(heavy: status.emphasized)).lineLimit(1).fixedSize()
                    // No room past the notch: the record light and the camera dot come over beside the word.
                    if ui.rightWing == 0, !ui.expanded, case .recordLight = mark { RecordLight(); CameraDot() }
                }
                .padding(.leading, NotchBarUI.inset)
                .frame(width: ui.expanded && ui.housingWidth != nil ? ui.openHousingX : ui.leftWing, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { ui.onBarClick() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(MascotName), \(status.word)")
                .accessibilityValue(conflict ? model.hotkeyNotice!.replacingOccurrences(of: "⌃⌥", with: "Control Option ") : accessibilityDetail(status))
                .accessibilityHint(ui.expanded ? "Closes the panel." : "Opens the panel.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { ui.onBarClick() }
                if let housing = ui.housingWidth { Color.clear.frame(width: housing) }
                // No right wing: nothing at all, so the row is exactly the wing and Tug stays at its inset.
                if ui.rightWing > 0 || ui.expanded { HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    if mark != .none, ui.rightWing > 0 || ui.expanded {
                        // Collapsed: centred in the wing's one width, the same padding on both sides, so no dead
                        // sunflower sits between the notch and the mark.
                        BarMark(mark: mark).frame(width: ui.expanded ? nil : BarType.markSlot).padding(.trailing, ui.expanded ? 6 : 0)
                            .accessibilityHidden(true)
                    }
                    // Open: the settings and hide controls live in the bar itself, as bare glyphs.
                    if ui.expanded {
                        BandGlyph(symbol: "gearshape", label: ui.settingsOpen ? "Close settings" : "Settings", on: ui.settingsOpen) {
                            ui.settingsOpen.toggle()
                        }
                        BandGlyph(symbol: "eye.slash", label: "Hide Tug (⌃⌥H)") { ui.onHide() }
                    }
                }
                .padding(.leading, ui.expanded ? 0 : NotchBarPlacement.notchGap)
                .padding(.trailing, ui.expanded ? NotchBarUI.glyphInset : NotchBarPlacement.notchGap)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { ui.onBarClick() } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color(Tok.inkFixed))
            // Everything on the band is drawn for its own ground, not the system look.
            .environment(\.colorScheme, .light)
        }
    }

    private func accessibilityDetail(_ status: NotchBarStatus) -> String {
        if status.emphasized { return "Hold Control Option T to answer." }
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

/// A bare ink glyph button in the sunflower band: no box, a 28 pt target, a tooltip, and a VoiceOver label.
struct BandGlyph: View {
    let symbol: String
    let label: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? symbol + ".fill" : symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(Tok.inkFixed))
                .frame(width: NotchBarUI.glyphButton, height: NotchBarUI.glyphButton).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
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
                Text(time).font(TypeFace.mono(12, weight: 600)).monospacedDigit().lineLimit(1).fixedSize()
                // Facing the camera or not, while a hold has the camera on.
                CameraDot().padding(.leading, 2)
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

/// The open panel's body: the card that hangs from Tug's string, in one container, with one row of actions; or the
/// settings view behind the gear in the bar.
struct NotchBarBody: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var ui: NotchBarUI
    @Environment(\.colorScheme) private var scheme

    /// The gap above the title row, and the left margin the string hangs in.
    static let top: CGFloat = 8
    static let leading: CGFloat = 28
    static let trailing: CGFloat = 16

    private var status: NotchBarStatus { NotchBarStatus.make(model.phase.barInput(talking: model.talking)) }
    /// A card that opened the panel by itself shows one or two lines until the pointer rests on it.
    private var compact: Bool { status.showsCard && status.compact && ui.openedByCard && !ui.dwelled }

    var body: some View {
        // Two blocks, evidence then action, with more space between them than inside them.
        VStack(alignment: .leading, spacing: 16) {
            if ui.settingsOpen {
                NotchBarSettings(model: model, onHome: ui.onHome, onDone: { ui.settingsOpen = false })
            } else {
                card
                if !compact { actions }
            }
        }
        .padding(.top, Self.top).padding(.leading, Self.leading).padding(.trailing, Self.trailing).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The card

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            CardTitle(eyebrow: card.replayed ? "Already saved from \(card.appName)" : "Card saved from \(card.appName)", sample: card.isPreview, onClose: close)
            MainLine(text: card.observation, compact: compact)
            if !compact {
                LabelledLine(label: "Next step", text: card.nextStep)
                if model.pointing {
                    Label { Text("Circled on your \(card.appName) window").font(TypeFace.body(13, weight: 550)) } icon: { Image(systemName: "circle.circle") }
                        .foregroundStyle(Color(Tok.muted))
                }
            }
        case .notice(let text):
            CardTitle(eyebrow: text == model.hotkeyNotice ? "Shortcut" : "Note", onClose: close)
            NoticeText(text: text)
        case .nudging(let nudge, _):
            CardTitle(eyebrow: "Updated: \(nudge.goalTitle)", onClose: close)
            MainLine(text: nudge.detail, compact: compact)
        case .offline(let reason, _):
            CardTitle(eyebrow: model.phase.heading, onClose: close)
            MainLine(text: reason, compact: false)
        case .voiceError(let message, let retryable):
            CardTitle(eyebrow: model.phase.heading, onClose: close)
            MainLine(text: message, compact: false)
            Text(retryable ? "Your recording waits on this Mac." : "Your recording was deleted.")
                .font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted))
        case .permission:
            CardTitle(eyebrow: model.phase.heading, onClose: close)
            MainLine(text: "\(MascotName) reads only the front window, and only when you ask. The picture never leaves this Mac.", compact: false)
            ShortcutLine(text: "Read a window: ⌃⌥Space", font: TypeFace.body(13, weight: 550), ink: Tok.muted)
        case .micPermission(let denied):
            CardTitle(eyebrow: model.phase.heading, onClose: close)
            MainLine(text: denied ? "Turn it on in Privacy & Security › Microphone, then try again."
                                  : "\(MascotName) listens only while you hold the talk keys, and deletes each recording once it's sent.", compact: false)
        default:
            CardTitle(eyebrow: model.phase.heading, onClose: close)
        }
    }

    private func close() { model.dismiss(); ui.onClose() }

    @ViewBuilder private var latestCard: some View {
        if let notice = model.hotkeyNotice {
            CardTitle(eyebrow: "Shortcut")
            NoticeText(text: notice)
        } else if ui.latest == .round, let round = model.latestVoiceCard {
            CardTitle(eyebrow: "Latest round", trailing: round.round.map { "Round \($0)" }, sample: round.isPreview)
            if let number = LatestRoundNumber.make(summary: round.summary, latest: round.metrics) {
                // A plain line: the count chip and its caption on one baseline.
                HabitCount(count: number.value, habit: number.habit, caption: number.caption)
            }
            SaidDisclosure(quote: round.quote, transcript: round.transcriptSnippet, onLayout: { model.layoutNeeded() })
            RecordingNote(note: round.recordingNote)
        } else if ui.latest == .card, let card = model.lastCard {
            CardTitle(eyebrow: "Latest card from \(card.appName)", sample: card.isPreview)
            MainLine(text: card.observation, compact: false)
            LabelledLine(label: "Next step", text: card.nextStep)
        } else {
            CardTitle(eyebrow: "Ready")
            Text("No round yet").font(TypeFace.display(17, weight: 800)).foregroundStyle(Color(Tok.ink))
        }
    }

    // The one row of actions

    /// The card's own next step, which becomes the row's one primary action.
    private var cardAction: (title: String, run: () -> Void, secondary: (title: String, run: () -> Void)?)? {
        switch model.phase {
        case .offline(_, let retryable) where retryable: return ("Retry", { model.onRetry() }, nil)
        case .voiceError(_, let retryable) where retryable: return ("Retry", { model.onVoiceRetry() }, nil)
        case .permission: return ("Continue", { model.onPermissionContinue() }, ("Open System Settings", { model.onOpenSettings() }))
        case .micPermission(let denied):
            return denied ? ("Open System Settings", { model.onOpenMicSettings() }, nil)
                          : ("Continue", { model.onMicContinue() }, ("Open System Settings", { model.onOpenMicSettings() }))
        default: return nil
        }
    }

    private var isPermission: Bool {
        switch model.phase {
        case .permission, .micPermission: true
        default: false
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let action = cardAction {
                Button(action.title, action: action.run).buttonStyle(ChipButtonStyle(primary: true))
                if let secondary = action.secondary { Button(secondary.title, action: secondary.run).buttonStyle(ChipButtonStyle()) }
            }
            // A permission step comes first; everything else offers talking and reading.
            if !isPermission {
                NotchTalkButton(ui: ui, primary: cardAction == nil)
                Button("Read this window") { ui.onReadWindow() }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityHint("Reads the window in front, like Control-Option-Space.")
                if model.lastCard != nil {
                    Button("Ask Muse") { model.onAskMuse() }
                        .buttonStyle(ChipButtonStyle())
                        .help("Open this in Muse, Meta's assistant")
                        .accessibilityHint("Opens this in Muse, Meta's assistant.")
                }
                if case .speaking(let card) = model.phase, !card.isPreview {
                    Button("Undo") { model.onUndo() }.buttonStyle(ChipButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The card's title row: a small eyebrow label, the Debug "Sample" tag inline, and ✕, on one baseline, with ✕ at the
/// same right inset as the glyphs in the bar.
struct CardTitle: View {
    let eyebrow: String
    var trailing: String? = nil
    var sample = false
    var onClose: (() -> Void)? = nil

    /// "Round 1, Sample", with one divider. "Sample" is Debug previews only; `-noSampleTag YES` hides it for the video.
    private var meta: String? {
        var parts = [trailing].compactMap { $0 }
        #if DEBUG
        if sample, !UserDefaults.standard.bool(forKey: "noSampleTag") { parts.append("Sample") }
        #endif
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(eyebrow).font(TypeFace.body(12, weight: 650)).foregroundStyle(Color(Tok.muted)).lineLimit(1)
            Spacer(minLength: 4)
            if let meta { Text(meta).font(TypeFace.body(12, weight: 650)).foregroundStyle(Color(Tok.muted)).lineLimit(1) }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(Tok.ink))
                        .frame(width: NotchBarUI.glyphButton, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close card")
            }
        }
        .frame(minHeight: 20)
        // ✕'s target ends at the bar glyphs' inset, not the text's.
        .padding(.trailing, onClose == nil ? 0 : NotchBarUI.glyphInset - NotchBarBody.trailing)
    }
}

/// The card's main line: what Tug asks or found, in Hanken Grotesk, larger than everything else on the card.
struct MainLine: View {
    let text: String
    var compact = false
    var body: some View {
        Text(noWidow(text)).font(TypeFace.body(17, weight: 700)).lineSpacing(3).foregroundStyle(Color(Tok.ink))
            .lineLimit(compact ? 2 : nil).fixedSize(horizontal: false, vertical: true)
    }
}

/// "Next step  Say the ask in one sentence": a muted label and the text on one plain line, no rule.
struct LabelledLine: View {
    let label: String
    let text: String
    var body: some View {
        (Text(label + "  ").font(TypeFace.body(13, weight: 600)).foregroundColor(Color(Tok.muted))
         + Text(noWidow(text)).font(TypeFace.body(15, weight: 600)).foregroundColor(Color(Tok.ink)))
            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(label): \(text)")
    }
}

/// The panel's buttons: compact chips, at least 32 pt tall, body-size labels, light outlines. The primary is ink with
/// white text in light, and sunflower only in dark (sunflower otherwise belongs to the bar).
struct ChipButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        ChipBackground(primary: primary, scheme: scheme) {
            configuration.label.font(TypeFace.body(13, weight: 650)).lineLimit(1).fixedSize()
        }
        .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The chip's look, shared with the hold-to-talk button.
struct ChipBackground<Label: View>: View {
    let primary: Bool
    let scheme: ColorScheme
    @ViewBuilder var label: Label
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        label
            .foregroundStyle(Color(primary ? Self.onPrimary(scheme) : Tok.ink))
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(shape.fill(primary ? Color(Self.primaryFill(scheme)) : Color.clear))
            .overlay(shape.strokeBorder(primary ? Color.clear : Color(Tok.edge).opacity(0.7), lineWidth: 1))
            .contentShape(shape)
    }

    static func primaryFill(_ scheme: ColorScheme) -> NSColor { scheme == .dark ? Tok.barField(.dark) : Tok.inkFixed }
    static func onPrimary(_ scheme: ColorScheme) -> NSColor { scheme == .dark ? Tok.inkFixed : Tok.labelWhite }
}

/// A notice: its first sentence with the keys as keycaps (wrapping text when it is long), the rest muted underneath.
struct NoticeText: View {
    let text: String
    var body: some View {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
        // The first line ends on the keycaps, without a stray full stop after them.
        let first = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? text
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        VStack(alignment: .leading, spacing: 4) {
            if first.count <= 34 {
                ShortcutLine(text: first, font: TypeFace.body(16, weight: 700))
            } else {
                MainLine(text: first + (rest.isEmpty ? "" : "."))
            }
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

/// A spoken reply: a small eyebrow, the question as the main line, then one quiet evidence row (your words and the
/// count), then the one talk prompt. Compact: the eyebrow and the question in two lines.
struct ReplyCard: View {
    let card: VoiceCard
    let compact: Bool
    var onClose: () -> Void
    var onLayout: () -> Void

    var body: some View {
        CardTitle(eyebrow: card.endsRound ? "Round done" : card.moveTitle, trailing: card.round.map { "Round \($0)" }, sample: card.isPreview, onClose: onClose)
        if card.endsRound, let summary = card.summary, let number = LatestRoundNumber.make(summary: summary, latest: nil) {
            // The one big number, on Round done only.
            RoundNumber(number: number)
        }
        MainLine(text: card.question, compact: compact).accessibilityLabel("Question: \(card.question)")
        if !compact {
            if card.summary == nil { EvidenceRow(card: card, onLayout: onLayout) }
            ReplayRow(card: card) // the camera chip, or the hands check on Round done (ReplayStrip.swift)
            if card.needLine != nil || card.codeOnly { NeedLine(card: card) }
            RecordingNote(note: card.recordingNote)
        }
    }
}

/// Your words and the measured count, on one quieter row.
struct EvidenceRow: View {
    let card: VoiceCard
    var onLayout: () -> Void
    var body: some View {
        let stat = LatestRoundNumber.make(summary: nil, latest: card.metrics)
        SaidDisclosure(quote: card.quote, transcript: card.transcriptSnippet, onLayout: onLayout) {
            if let stat { HabitCount(count: stat.value, habit: stat.habit) }
        }
    }
}

/// "You said “I think” ⌄", which opens to the transcript with those words marked; anything after it shares the row.
struct SaidDisclosure<Extra: View>: View {
    let quote: String?
    let transcript: String
    var onLayout: () -> Void
    @ViewBuilder var extra: Extra
    @State private var open = false

    init(quote: String?, transcript: String, onLayout: @escaping () -> Void, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.quote = quote; self.transcript = transcript; self.onLayout = onLayout; self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                if quote != nil || !transcript.isEmpty {
                    Button {
                        open.toggle()
                        onLayout()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(quote == nil ? "What you said" : "You said").font(TypeFace.body(13, weight: 550)).foregroundStyle(Color(Tok.muted))
                            if let quote { Text("\u{201C}\(quote)\u{201D}").font(TypeFace.body(13, weight: 700)).foregroundStyle(Color(Tok.ink)) }
                            if !transcript.isEmpty {
                                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(Tok.muted))
                            }
                        }
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(transcript.isEmpty)
                    .accessibilityLabel(quote.map { "You said \($0)" } ?? "What you said")
                    .accessibilityHint(open ? "Hides what you said." : "Shows what you said.")
                }
                extra
            }
            if open, !transcript.isEmpty { Transcript(text: transcript, mark: quote) }
        }
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

/// The evidence chips' one text grammar: Hanken Grotesk, the number in bold, the unit at line weight.
struct EvidenceChipText: View {
    let number: String
    let unit: String
    var body: some View {
        (Text(number).font(TypeFace.body(13, weight: 800)) + Text(" " + unit).font(TypeFace.body(13, weight: 600))).monospacedDigit()
    }
}

/// The one count component: the numeral and its unit in one chip at line weight, with an optional caption on the
/// same baseline. Only the colour changes with the habit.
struct HabitCount: View {
    let count: Int
    let habit: RoundSummary.Habit
    var caption: String? = nil

    var body: some View {
        // The habit's own token (fillers: Tok.filler with Tok.fillerEdge), full strength in both looks, ink text.
        let (fill, edge) = HabitChip.colours(habit)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            EvidenceChipText(number: "\(count)", unit: HabitWord.word(habit, count))
                .foregroundStyle(Color(Tok.inkFixed))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(fill)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(edge), lineWidth: 1))
            if let caption { Text(caption).font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Measured by code: \(count) \(HabitWord.word(habit, count))\(caption.map { " \($0)" } ?? "")")
    }
}

/// Round done's one big number, as a single lockup on the card surface: an ink numeral in Anybody, and "fillers, down
/// from 2 in your first answer" on the same baseline. No tile.
struct RoundNumber: View {
    let number: LatestRoundNumber

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number.value)").font(TypeFace.display(40, weight: 850)).monospacedDigit().foregroundStyle(Color(Tok.ink))
            (Text(HabitWord.word(number.habit, number.value) + ", ").font(TypeFace.body(15, weight: 750)).foregroundColor(Color(Tok.ink))
             + Text(number.caption).font(TypeFace.body(15, weight: 550)).foregroundColor(Color(Tok.muted)))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number.value) \(HabitWord.word(number.habit, number.value)) \(number.caption)")
    }
}

/// Hold to talk, like holding ⌃⌥T: pressing opens the microphone, letting go sends the answer. A chip like the rest.
struct NotchTalkButton: View {
    @ObservedObject var ui: NotchBarUI
    var primary = true
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ChipBackground(primary: primary, scheme: scheme) {
            // "Talk ⌃⌥T": the keys inline, in the chip's own ink, so no separate hint line is needed.
            HStack(spacing: 7) {
                if ui.holdingTalk { RecordDot() }
                Text(ui.holdingTalk ? "Listening" : "Talk").font(TypeFace.body(13, weight: 650))
                if !ui.holdingTalk { KeyCaps("⌃⌥T", size: 11, ink: primary ? ChipBackground<EmptyView>.onPrimary(scheme) : Tok.ink) }
            }
            .fixedSize()
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !ui.holdingTalk { ui.holdingTalk = true; ui.onTalkDown() } }
            .onEnded { _ in ui.onTalkUp() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talk, Control Option T")
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
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(eyebrow: "Settings", onClose: onDone)
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
                row("In meetings") {
                    CartSegmented(label: "In meetings", options: [(true, "Hide Tug"), (false, "Show Tug")], selection: $hideInMeetings)
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

/// A row of equal-width choices on a neutral track, about a third shorter than the row; the chosen one is white (the
/// card surface) with a 1 pt ink border. Each choice is a button at least 28 pt tall inside a 32 pt control, and
/// VoiceOver reads which one is selected.
struct CartSegmented<Value: Hashable>: View {
    let label: String
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(TypeFace.body(13, weight: chosen ? 700 : 600))
                        .foregroundStyle(Color(chosen ? Tok.ink : Tok.muted))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chosen ? Color(Tok.surface) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(Tok.ink).opacity(chosen ? 1 : 0), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.1)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .frame(width: 196)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(Tok.rule)))
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
    let awake: Bool
    func makeNSView(context: Context) -> TugGlyphFaceView { TugGlyphFaceView() }
    func updateNSView(_ view: TugGlyphFaceView, context: Context) {
        view.configure(.init(face: face, awake: awake && !Motion.forced))
    }
}

final class TugGlyphFaceView: NSView {
    struct Look: Equatable { var face: NotchBarStatus.Face; var awake: Bool }
    enum Art: Hashable { case open, half, shut, brows, mouthOpen, mouthSmall }

    private let can = CALayer()
    private var look: Look?
    private var images: [Art: CGImage] = [:]
    private var built: (CGSize, CGFloat)?
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
        guard look != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        if built.map({ $0.0 != bounds.size || $0.1 != scale }) ?? true {
            built = (bounds.size, scale)
            images = [Art.open, .half, .shut, .brows, .mouthOpen, .mouthSmall].reduce(into: [:]) { all, art in
                all[art] = Self.image(bounds.size, scale, art, Tok.inkFixed)
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
