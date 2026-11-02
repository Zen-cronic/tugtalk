import AppKit
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
    /// The status row's height: the notch's, or the whole bar's without one.
    @Published var band: CGFloat = 30
    /// The sunflower strip under the housing.
    @Published var below: CGFloat = 0
    @Published var barSize = CGSize(width: 232, height: 30)
    /// The open body's measured height.
    @Published var bodyHeight: CGFloat = 0
    /// Which of the two latest cards came last.
    @Published var latest: Latest = .none
    @Published var holdingTalk = false

    enum Latest { case none, round, card }

    static let openWidth: CGFloat = 456
    /// Room under the open panel for the spring's overshoot.
    static let slack: CGFloat = 24

    var openHeight: CGFloat { band + below + bodyHeight }

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

/// Tug's string from the glyph in the bar. Collapsed it is the glyph's own short curl; open, it drops into the
/// panel and the latest card hangs from it. One animatable amount, so the spring swings it.
struct DropString: Shape {
    var drop: CGFloat
    let root: CGPoint
    let unit: CGFloat
    let hook: CGPoint

    var animatableData: CGFloat {
        get { drop }
        set { drop = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * drop, y: a.y + (b.y - a.y) * drop) }
        func curl(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: root.x + dx * unit, y: root.y + dy * unit) }
        // The glyph's curl, from the can's base out to its right (TugGlyph's string, in its 18-unit box).
        let c1 = mix(curl(1.4, 4.4), CGPoint(x: root.x + 12, y: root.y + 18))
        let c2 = mix(curl(6.2, 4.0), CGPoint(x: hook.x - 7, y: hook.y - 18))
        let end = mix(curl(9.2, -1.2), hook)
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

    static let glyph: CGFloat = 20
    static let inset: CGFloat = 12

    private var size: CGSize {
        ui.expanded ? CGSize(width: NotchBarUI.openWidth, height: ui.openHeight) : ui.barSize
    }

    private var spring: Animation? { reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2) }
    private var swing: Animation? { reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.34) }

    var body: some View {
        label
            .animation(spring, value: ui.expanded)
            .animation(spring, value: ui.openHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.tugAwake, !model.isPresenting)
    }

    private var label: some View {
        let strip = ui.band + ui.below
        let shape = HangingLabel(radius: 14)
        return ZStack(alignment: .top) {
            // The card body, then the sunflower band across the top (the whole label while collapsed).
            Rectangle().fill(Color(Tok.surface))
            Rectangle().fill(Color(Tok.field)).frame(height: strip)
            Rectangle().fill(Color(Tok.cardEdge).opacity(0.5)).frame(height: 1).offset(y: strip)
                .opacity(ui.expanded ? 1 : 0)
            string
            VStack(spacing: 0) {
                row.frame(width: size.width, height: ui.band)
                Color.clear.frame(width: size.width, height: ui.below)
                if ui.mounted {
                    NotchBarBody(model: model, ui: ui)
                        .frame(width: NotchBarUI.openWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geo in Color.clear.preference(key: BodyHeight.self, value: geo.size.height) })
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay(HangingLabel(radius: 14, open: true).stroke(Color(Tok.cardEdge), lineWidth: 1))
        // The ink lip under the label: the cartridge shell.
        .background(shape.fill(Color(Tok.inkFixed)).offset(y: 3))
        .contentShape(Rectangle())
        .onHover { ui.onPointer($0) }
        .onPreferenceChange(BodyHeight.self) { height in
            if abs(ui.bodyHeight - height) > 0.5 { ui.bodyHeight = height }
        }
    }

    /// Where the string leaves the glyph, in the label's coordinates: under the can, so a breath never shows a gap.
    private var root: CGPoint {
        let unit = Self.glyph / 18
        return CGPoint(x: Self.inset + 8 * unit, y: (ui.band - Self.glyph) / 2 + 13.6 * unit)
    }

    /// The hook on the latest card's top edge.
    private var hook: CGPoint {
        CGPoint(x: root.x + 4, y: ui.band + ui.below + NotchBarBody.top)
    }

    private var string: some View {
        let unit = Self.glyph / 18
        let shape = DropString(drop: ui.expanded ? 1 : 0, root: root, unit: unit, hook: hook)
        let strip = ui.band + ui.below
        return ZStack(alignment: .topLeading) {
            // Ink on sunflower; on the card body, the string token for this look.
            shape.stroke(Color(Tok.inkFixed), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .mask(alignment: .top) { Rectangle().frame(height: strip) }
            shape.stroke(Tok.tugString(scheme), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .mask(alignment: .top) { Rectangle().padding(.top, strip) }
            Circle().strokeBorder(Tok.tugString(scheme), lineWidth: 1.6)
                .background(Circle().fill(Color(Tok.surface)))
                .frame(width: 8, height: 8)
                .position(hook)
                .opacity(ui.expanded ? 1 : 0)
        }
        .animation(swing, value: ui.expanded)
        .allowsHitTesting(false)
    }

    private var row: some View {
        // The clock ticks once a second only while the microphone is open, for the timer.
        TimelineView(.animation(minimumInterval: 1, paused: !isListening)) { context in
            let status = NotchBarStatus.make(model.phase.barInput(talking: model.talking, now: context.date))
            // With the talk keys held by another copy, the bar never offers them.
            let conflict: Bool = { if model.hotkeyNotice != nil, case .keycaps = status.mark { return true } else { return false } }()
            let mark: NotchBarStatus.Mark = conflict ? .symbol("exclamationmark.circle") : status.mark
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    TugGlyphBreathing(awake: !model.isPresenting && TugPose.breathes(model.phase, talking: model.talking))
                        .frame(width: Self.glyph, height: Self.glyph)
                    // Kept clear of the housing: the core keeps words to nine characters; this is the safety net.
                    Text(status.word).font(TypeFace.display(14, weight: 800)).lineLimit(1).minimumScaleFactor(0.85)
                        .frame(maxWidth: ui.housingWidth == nil ? nil : NotchBarController.wing - Self.inset - Self.glyph - 13, alignment: .leading)
                }
                .padding(.leading, Self.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let housing = ui.housingWidth { Color.clear.frame(width: housing) }
                BarMark(mark: mark)
                    .padding(.trailing, Self.inset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .foregroundStyle(Color(Tok.inkFixed))
            // Sunflower is the same in both looks, so everything on it is drawn for light.
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

    private var isListening: Bool { if case .voiceListening = model.phase { return true } else { return false } }

    private func accessibilityDetail(_ status: NotchBarStatus) -> String {
        switch status.mark {
        case .keycaps(_, let cue): cue ? "Hold Control Option T to answer." : "Hold Control Option T and talk."
        case .recordLight(let time): "Recording, \(time)"
        default: ""
        }
    }
}

private struct BodyHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The mark on the far side of the notch: the keycaps, the record light, three dots, a wave, or an icon.
struct BarMark: View {
    let mark: NotchBarStatus.Mark

    var body: some View {
        switch mark {
        case .keycaps(let keys, let cue):
            if cue { TurnCue(keys: keys) } else { KeyCaps(keys, size: 11, ink: Tok.inkFixed) }
        case .recordLight(let time):
            HStack(spacing: 6) {
                RecordLight()
                Text(time).font(TypeFace.mono(12, weight: 600)).monospacedDigit()
            }
        case .dots: ThinkingDots()
        case .wave: SpeakingWave(color: Tok.inkFixed)
        case .symbol(let name): Image(systemName: name).font(.system(size: 13, weight: .bold))
        }
    }
}

/// "Your turn": the keycaps in an ink edge that pulses gently. Still with Reduce Motion.
struct TurnCue: View {
    let keys: String
    @Environment(\.reduceMotionOn) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let pulse = reduceMotion ? 1 : 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.6)
            KeyCaps(keys, size: 11, ink: Tok.inkFixed)
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color(Tok.inkFixed).opacity(0.3 + 0.6 * pulse), lineWidth: 1.5))
        }
    }
}

/// The record light on sunflower: a white disc with an ink edge, so the red reads against yellow, and the red
/// dot inside it that dims and brightens while the microphone is open. Still with Reduce Motion.
struct RecordLight: View {
    @Environment(\.reduceMotionOn) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let pulse = reduceMotion ? 1 : 0.65 + 0.35 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2)
            ZStack {
                Circle().fill(Color(Tok.labelWhite))
                Circle().strokeBorder(Color(Tok.inkFixed), lineWidth: 1)
                Circle().fill(Color(Tok.record)).frame(width: 8, height: 8).opacity(pulse)
            }
            .frame(width: 15, height: 15)
        }
        .accessibilityLabel("Recording")
    }
}

/// The open panel's body: the card that hangs from Tug's string, the quick actions, and a few settings.
struct NotchBarBody: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var ui: NotchBarUI
    /// The gap above the card, where the string's hook sits.
    static let top: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card
            actions
            // Settings only when the panel is open on purpose: a card that needs a step or a reply comes first.
            if !status.showsCard {
                Rectangle().fill(Color(Tok.rule)).frame(height: 1)
                NotchBarSettings(model: model, onHome: ui.onHome)
            }
        }
        .padding(.top, Self.top).padding(.horizontal, 14).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: NotchBarStatus { NotchBarStatus.make(model.phase.barInput(talking: model.talking)) }

    /// A card for the current state when it has one, otherwise the latest round or card.
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if status.showsCard {
                liveCard
            } else {
                latestCard
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .thinEdge(radius: 12, fill: Tok.surface, edge: Tok.edge)
    }

    @ViewBuilder private var liveCard: some View {
        if case .notice(let text) = model.phase {
            // A notice is one line; no heading that repeats it.
            HStack(alignment: .center, spacing: 8) {
                ShortcutLine(text: text, font: TypeFace.body(15, weight: 650))
                Spacer(minLength: 4)
                closeButton
            }
            if text == model.hotkeyNotice {
                Text("Quit the other copy, then open this one again.").font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted))
            }
        } else {
            cardHeader
            CardBody(model: model)
        }
    }

    private var closeButton: some View {
        Button { model.dismiss(); ui.onClose() } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(Tok.ink))
        .accessibilityLabel("Close card")
    }

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            if CardTone(model.phase) == .problem { Image(systemName: model.phase.symbol).font(.system(size: 14, weight: .bold)) }
            Text(noWidow(model.phase.heading)).font(TypeFace.display(17, weight: 800)).lineLimit(2)
            Spacer(minLength: 4)
            if case .voiceSpeaking(let card) = model.phase, let round = card.round {
                Text("Round \(round)").font(TypeFace.body(12, weight: 650)).foregroundStyle(Color(Tok.muted))
            }
            closeButton
        }
        .foregroundStyle(Color(Tok.ink))
    }

    @ViewBuilder private var latestCard: some View {
        if let notice = model.hotkeyNotice {
            Text("Shortcut").font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted))
            ShortcutLine(text: notice, font: TypeFace.body(15, weight: 600))
            Text("Quit the other copy, then open this one again.").font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted))
        } else if ui.latest == .round, let round = model.latestVoiceCard {
            HStack {
                Text("Latest round").font(TypeFace.body(12, weight: 600))
                Spacer()
                if let n = round.round { Text("Round \(n)").font(TypeFace.body(12, weight: 600)) }
            }
            .foregroundStyle(Color(Tok.muted))
            if let quote = round.quote { QuoteTag(quote: quote) }
            if let number = LatestRoundNumber.make(summary: round.summary, latest: round.metrics) { RoundNumber(number: number) }
            SampleTag(isPreview: round.isPreview, text: round.summary == nil ? "Sample answer" : "Sample numbers")
        } else if ui.latest == .card, let card = model.lastCard {
            Text("Latest card · \(card.appName)").font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted))
            CoachText(card.observation)
            Instruction(label: "Next step", text: card.nextStep)
            SampleTag(isPreview: card.isPreview, text: "Sample card")
        } else {
            Text("No round yet").font(TypeFace.display(17, weight: 800)).foregroundStyle(Color(Tok.ink))
            ShortcutLine(text: "Hold ⌃⌥T and answer out loud.", font: TypeFace.body(14, weight: 600), ink: Tok.muted)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            NotchTalkButton(ui: ui)
            Button("Read this window") { ui.onReadWindow() }
                .buttonStyle(CartButtonStyle(primary: false))
                .accessibilityHint("Reads the window in front, like Control-Option-Space.")
            // Only when there is a card for Muse to open, and the card on show doesn't already offer it.
            if model.lastCard != nil, !isContextCard {
                Button("Ask Muse") { model.onAskMuse() }.buttonStyle(CartButtonStyle(primary: false))
            }
            Spacer(minLength: 0)
            Button("Hide") { ui.onHide() }
                .buttonStyle(CartButtonStyle(primary: false))
                .accessibilityHint("Hides Tug until you press Control-Option-H.")
        }
    }

    private var isContextCard: Bool { if case .speaking = model.phase { return true } else { return false } }
}

/// The one number of the latest round, with the habit's word in its own colour and a plain caption.
struct RoundNumber: View {
    let number: LatestRoundNumber
    @Environment(\.colorScheme) private var scheme

    static func word(_ habit: RoundSummary.Habit, _ count: Int) -> String {
        switch habit {
        case .filler: count == 1 ? "filler" : "fillers"
        case .hedge: count == 1 ? "unsure word" : "unsure words"
        case .restart: count == 1 ? "restart" : "restarts"
        }
    }

    var body: some View {
        let (fill, edge) = HabitChip.colours(number.habit)
        let dark = scheme == .dark
        HStack(alignment: .center, spacing: 12) {
            Text("\(number.value)").font(TypeFace.display(44, weight: 850)).monospacedDigit().foregroundStyle(Color(Tok.ink))
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.word(number.habit, number.value)).font(TypeFace.display(15, weight: 800))
                    .foregroundStyle(Color(dark ? Tok.ink : Tok.inkFixed))
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(dark ? edge : fill).opacity(dark ? 0.3 : 1)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(edge).opacity(0.6), lineWidth: 1))
                Text(number.caption).font(TypeFace.body(13, weight: 550)).foregroundStyle(Color(Tok.muted))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number.value) \(Self.word(number.habit, number.value)) \(number.caption)")
    }
}

/// Hold to talk, like holding ⌃⌥T: pressing opens the microphone, letting go sends the answer.
struct NotchTalkButton: View {
    @ObservedObject var ui: NotchBarUI
    var body: some View {
        HStack(spacing: 7) {
            if ui.holdingTalk { RecordDot() } else { Image(systemName: "mic.fill").font(.system(size: 13, weight: .bold)) }
            Text(ui.holdingTalk ? "Listening" : "Talk").font(TypeFace.body(14, weight: 650))
        }
        .foregroundStyle(Color(Tok.onAction))
        .padding(.horizontal, 14).frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(Tok.action)))
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

/// Four settings: the reply voice, the language, where Tug lives, and hiding in meetings.
struct NotchBarSettings: View {
    @ObservedObject var model: CompanionModel
    var onHome: (TugHome) -> Void
    @State private var voice = Settings.replyVoice
    @State private var language = Settings.voiceLanguage
    @State private var home = Settings.tugHome
    @State private var hideInMeetings = Settings.autoHideInMeetings

    var body: some View {
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

/// A row of choices in a thin edge; the chosen one has a neutral tint and an ink edge. Each choice is a button at least 28 pt
/// tall inside a 32 pt control, and VoiceOver reads which one is selected.
struct CartSegmented<Value: Hashable>: View {
    let label: String
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Button { selection = option.0 } label: {
                    // The chosen one is a neutral tint with an ink edge: ink fill stays for the one primary action (Talk),
                    // sunflower for the band and good news.
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

/// The small Tug in the bar, breathing on Core Animation: a slight bob and a blink now and then, from the same
/// loops as the big Tug (`TugBreath`, `BlinkSchedule`). The loops stop while the window is hidden or covered, while
/// presenting, outside a resting state, and with Reduce Motion. Its string is drawn by the bar, so it can drop.
struct TugGlyphBreathing: NSViewRepresentable {
    let awake: Bool
    func makeNSView(context: Context) -> TugGlyphBreathView { TugGlyphBreathView() }
    func updateNSView(_ view: TugGlyphBreathView, context: Context) { view.awake = awake && !Motion.forced }
}

final class TugGlyphBreathView: NSView {
    var awake = false { didSet { if awake != oldValue { refresh() } } }
    private let can = CALayer()
    private var images: [TugEye: CGImage] = [:]
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

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        if built.map({ $0.0 != bounds.size || $0.1 != scale }) ?? true {
            built = (bounds.size, scale)
            images = [.open: Self.image(bounds.size, scale, .open), .half: Self.image(bounds.size, scale, .half), .shut: Self.image(bounds.size, scale, .shut)]
                .compactMapValues { $0 }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            can.frame = bounds
            can.contentsScale = scale
            can.contents = images[.open]
            CATransaction.commit()
            refresh(restart: true)
        }
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

    private var running: Bool { awake && visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func refresh(restart: Bool = false) {
        if !running || restart { can.removeAllAnimations(); can.contents = images[.open] }
        guard running, can.animation(forKey: "bob") == nil else { return }
        let unit = bounds.height / 18
        let moments = TugBreath.moments(count: 36)
        let begin = CACurrentMediaTime()
        let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bob.values = moments.map { TugBreath.bob(at: $0) * unit * 0.9 }
        bob.keyTimes = moments.map { NSNumber(value: $0 / TugBreath.period) }
        bob.duration = TugBreath.period
        bob.repeatCount = .infinity
        bob.beginTime = begin
        bob.isRemovedOnCompletion = false
        can.add(bob, forKey: "bob")
        var rng = SystemRandomNumberGenerator()
        let schedule = BlinkSchedule.random(using: &rng)
        let frames = schedule.keyframes
        let values = frames.eyes.compactMap { images[$0] }
        guard values.count == frames.eyes.count else { return }
        let blink = CAKeyframeAnimation(keyPath: "contents")
        blink.calculationMode = .discrete
        blink.values = values
        blink.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
        blink.duration = schedule.loop
        blink.repeatCount = .infinity
        blink.beginTime = begin
        blink.isRemovedOnCompletion = false
        can.add(blink, forKey: "blink")
    }

    /// The small one-colour Tug without its string (TugGlyph's can, rim and eyes), with open, half or shut eyes.
    static func image(_ size: CGSize, _ scale: CGFloat, _ eye: TugEye) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let pixels = NSSize(width: size.width * scale, height: size.height * scale)
        let image = NSImage(size: pixels, flipped: true) { rect in
            guard let g = NSGraphicsContext.current else { return false }
            let k = rect.width / 18
            g.cgContext.scaleBy(x: k, y: k)
            Tok.inkFixed.setFill()
            TugGlyph.paths().solid.fill()
            g.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 4.3, y: 3.2, width: 7.4, height: 2.3)).fill()
            for x in [4.9, 8.7] {
                switch eye {
                case .open: NSBezierPath(ovalIn: NSRect(x: x, y: 8.5, width: 2.4, height: 2.7)).fill()
                case .half: NSBezierPath(ovalIn: NSRect(x: x, y: 9.3, width: 2.4, height: 1.3)).fill()
                case .shut: NSBezierPath(roundedRect: NSRect(x: x, y: 9.6, width: 2.4, height: 0.7), xRadius: 0.35, yRadius: 0.35).fill()
                }
            }
            g.compositingOperation = .sourceOver
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
