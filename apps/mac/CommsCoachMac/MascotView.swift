import ScreenContextCore
import SwiftUI

/// Layout constants shared with the panel controller.
enum MascotLayout {
    static let character: CGFloat = 76
    static let headerTug: CGFloat = 50
    static let pad: CGFloat = 10
    static let bubbleWidth: CGFloat = 340
    static let gap: CGFloat = 0
    static let radius: CGFloat = 18
}

/// The name System Settings shows for this app.
let appDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "TugTalk"

/// Keeps the last two words of a line together, so no heading or question ends on a lone word.
func noWidow(_ text: String) -> String {
    guard let last = text.lastIndex(of: " "), text.distance(from: last, to: text.endIndex) < 18 else { return text }
    var out = text
    out.replaceSubrange(last...last, with: "\u{00A0}")
    return out
}

/// The whole panel: Tug with its status pill, or a card with Tug in its header.
struct MascotRoot: View {
    @ObservedObject var model: CompanionModel
    var onDrag: (DragGesture.Value?) -> Void
    @State private var hovering = false
    /// A finished voice reply folds away about 1 s after it is spoken, unless the pointer is over Tug.
    @State private var folded: String?
    @Environment(\.reduceMotionOn) private var reduceMotion

    var body: some View {
        ZStack(alignment: model.bubbleLeading ? .bottomTrailing : .bottomLeading) {
            if showsCard {
                CardView(model: model, onDrag: onDrag)
                    .frame(width: MascotLayout.bubbleWidth)
                    .transition(Motion.cardTransition(reduceMotion: reduceMotion))
            } else {
                HStack(alignment: .bottom, spacing: MascotLayout.gap) {
                    if model.bubbleLeading { pill; character } else { character; pill }
                }
                .transition(.opacity.animation(Motion.fade))
            }
        }
        .padding(MascotLayout.pad)
        .padding(.bottom, 3) // room for the cards' shell lip
        .fixedSize()
        .animation(reduceMotion ? Motion.crossfade : Motion.slot, value: showsCard)
        .onHover { inside in
            hovering = inside
            if inside { folded = nil } else { scheduleFold() }
            model.layoutNeeded()
        }
        .onChange(of: foldKey) { _, _ in scheduleFold() }
        .environment(\.tugAwake, !model.isPresenting)
    }

    private var showsCard: Bool {
        guard model.phase.showsBubble else { return false }
        if case .voiceSpeaking(let card) = model.phase, folded == card.roundID, !hovering { return false }
        return true
    }

    /// Changes when a voice reply finishes playing.
    private var foldKey: String {
        if case .voiceSpeaking(let card) = model.phase { return "\(card.roundID)-\(card.finished)" }
        return model.phase.name
    }

    private func scheduleFold() {
        guard case .voiceSpeaking(let card) = model.phase, card.finished, !card.endsRound, !card.isPreview else { return }
        let id = card.roundID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !hovering, case .voiceSpeaking(let now) = model.phase, now.roundID == id, now.finished else { return }
            folded = id
            model.layoutNeeded()
        }
    }

    private var character: some View {
        TugView(phase: model.phase, talking: model.talking, facesRight: !model.bubbleLeading)
            .frame(width: MascotLayout.character, height: MascotLayout.character)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { onDrag($0) }
                .onEnded { _ in onDrag(nil) })
            .onTapGesture { model.clicked() }
            .tugAccessibility(model)
    }

    @ViewBuilder private var pill: some View {
        if model.phase != .hidden {
            StatusPill(phase: model.phase, talking: model.talking).padding(.bottom, 2)
        }
    }
}

extension View {
    func tugAccessibility(_ model: CompanionModel) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel("\(MascotName) companion")
            .accessibilityValue(model.phase.pill().word)
            .accessibilityHint("Reads the front window when you ask, also on Control-Option-Space. Hold Control-Option-T to talk.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.clicked() }
    }
}


/// The plain-word status attached to Tug: an icon and one word, never colour alone. Each turn state has
/// its own mark: a red record light while listening, soft dots while thinking, a small wave while speaking.
struct StatusPill: View {
    let phase: MascotPhase
    var talking = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let pill = talking ? ("Speaking", nil) : phase.pill(now: context.date)
            let listening: Bool = { if case .voiceListening = phase { return true } else { return false } }()
            HStack(spacing: 7) {
                mark
                ShortcutLine(text: pill.0, font: TypeFace.body(14, weight: 650))
                if let detail = pill.1 { Text(detail).font(TypeFace.mono(12)).foregroundStyle(Color(Tok.muted)) }
            }
            .foregroundStyle(Color(Tok.ink))
            .padding(.horizontal, 12).frame(height: 32)
            .thinEdge(radius: 10, fill: Tok.surface, edge: listening ? Tok.record : Tok.edge)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Tok.record).opacity(listening ? 0.10 : 0)).allowsHitTesting(false))
            .fixedSize()
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        switch phase {
        case .voiceListening: RecordDot()
        case .thinking, .voiceThinking: ThinkingDots()
        case .voiceSpeaking(let card) where !card.finished: SpeakingWave()
        default:
            if talking { SpeakingWave() } else { Image(systemName: phase.symbol).font(.system(size: 12, weight: .bold)) }
        }
    }
}

/// The record light: red, the one red outside fillers, lit while the microphone is open. A slow pulse of
/// its ring; still with Reduce Motion.
struct RecordDot: View {
    var color: NSColor = Tok.record
    @Environment(\.reduceMotionOn) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2 * .pi / 1.2)
            ZStack {
                Circle().stroke(Color(color).opacity(0.25 + 0.45 * pulse), lineWidth: 2).frame(width: 15, height: 15)
                Circle().fill(Color(color)).frame(width: 9, height: 9)
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityLabel("Recording")
    }
}

/// Three soft dots that brighten in turn: Tug is thinking. Still dots with Reduce Motion.
struct ThinkingDots: View {
    @Environment(\.reduceMotionOn) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = reduceMotion ? 0.6 : 0.5 + 0.5 * sin(t * 2 * .pi / 1.4 - Double(i) * 0.9)
                    Circle().fill(Color(Tok.ink)).frame(width: 5, height: 5).opacity(0.25 + 0.6 * wave)
                }
            }
        }
        .frame(width: 21, height: 12)
    }
}

/// A small wave of three bars while Tug speaks. Still bars with Reduce Motion.
struct SpeakingWave: View {
    var color: NSColor = Tok.ink
    @Environment(\.reduceMotionOn) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<3, id: \.self) { i in
                    let h = reduceMotion ? [7.0, 11.0, 7.0][i] : 5 + 7 * abs(sin(t * 7 + Double(i) * 1.3))
                    Capsule().fill(Color(color)).frame(width: 3, height: h)
                }
            }
        }
        .frame(width: 15, height: 13)
    }
}

extension View {
    /// The cartridge shell, for cards only: a thin edge and a darker lip along the bottom.
    func cartLabel(radius: CGFloat = MascotLayout.radius, lip: CGFloat = 3, fill: NSColor = Tok.surface, edge: NSColor = Tok.cardEdge, lipColor: NSColor = Tok.inkFixed) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(Color(fill)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(edge), lineWidth: 1))
            .background(shape.fill(Color(lipColor)).offset(y: lip))
    }
}

/// Buttons are at least 32 pt tall. The primary one is ink with white text; the rest have a thin edge.
struct CartButtonStyle: ButtonStyle {
    var primary = true
    /// Stretch to the row's width, for a grid of equal buttons.
    var fill = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        configuration.label
            .font(TypeFace.body(14, weight: 650))
            .foregroundStyle(Color(primary ? Tok.onAction : Tok.ink))
            .padding(.horizontal, 14).frame(maxWidth: fill ? .infinity : nil, minHeight: 32)
            .background(shape.fill(Color(primary ? Tok.action : Tok.surface)))
            .overlay(shape.strokeBorder(Color(Tok.edge), lineWidth: primary ? 0 : 1))
            .opacity(configuration.isPressed ? 0.8 : (enabled ? 1 : 0.45))
            .contentShape(shape)
    }
}

/// A small text button for a quiet action ("Hide").
struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(TypeFace.body(13, weight: 600)).foregroundStyle(Color(Tok.muted))
            .padding(.horizontal, 6).frame(minHeight: 32).contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Where a card came from, behind a small info button (shown on hover), not printed on the card.
struct InfoButton: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 13, weight: .regular)).foregroundStyle(Color(Tok.muted))
            .frame(width: 32, height: 32).contentShape(Rectangle())
            .help(text)
            .accessibilityLabel("About this card")
            .accessibilityValue(text)
    }
}

/// The card's header band: sunflower for news, graphite when something stopped, neutral for setup.
enum CardTone {
    case news, problem, setup

    init(_ phase: MascotPhase) {
        switch phase {
        case .offline, .voiceError, .blocked: self = .problem
        case .permission, .micPermission: self = .setup
        default: self = .news
        }
    }

    var band: NSColor { switch self { case .news: Tok.field; case .problem: Tok.problemBand; case .setup: Tok.setupBand } }
    var text: NSColor { switch self { case .news: Tok.inkFixed; case .problem: Tok.onGraphite; case .setup: Tok.ink } }
}

/// A card: Tug in a coloured header, then the body.
struct CardView: View {
    @ObservedObject var model: CompanionModel
    var onDrag: (DragGesture.Value?) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            CardBody(model: model).padding(16)
        }
        .cartLabel()
    }

    private var tone: CardTone { CardTone(model.phase) }

    private var header: some View {
        let onBand = tone.text
        return HStack(alignment: .center, spacing: 10) {
            TugView(phase: model.phase, talking: model.talking, facesRight: true)
                .frame(width: MascotLayout.headerTug, height: MascotLayout.headerTug)
                .contentShape(Rectangle())
                .onTapGesture { model.clicked() }
                .tugAccessibility(model)
                // On sunflower the string is ink; on graphite it is cream, like the dark HUD.
                .environment(\.colorScheme, tone == .news ? .light : (tone == .problem ? .dark : scheme))
            VStack(alignment: .leading, spacing: 3) {
                Text(noWidow(model.phase.heading)).font(TypeFace.display(17, weight: 800)).lineLimit(2)
                if speaking {
                    HStack(spacing: 6) { SpeakingWave(color: onBand); Text("Speaking").font(TypeFace.body(13, weight: 600)) }
                }
            }
            .foregroundStyle(Color(onBand))
            Spacer(minLength: 4)
            if let round = roundLabel {
                Text(round).font(TypeFace.body(12, weight: 650)).foregroundStyle(Color(onBand))
                    .padding(.horizontal, 8).frame(height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(onBand).opacity(0.45), lineWidth: 1))
                    .accessibilityLabel(round)
            }
            Button { model.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Color(onBand))
            .accessibilityLabel("Close").keyboardShortcut(.cancelAction)
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(tone.band))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(Tok.cardEdge).opacity(0.5)).frame(height: 1) }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global).onChanged { onDrag($0) }.onEnded { _ in onDrag(nil) })
    }

    /// Tug's voice is playing (a spoken question, or the sentence about a circled line).
    private var speaking: Bool {
        switch model.phase {
        case .voiceSpeaking(let card): !card.finished
        case .speaking: model.talking
        default: false
        }
    }

    private var roundLabel: String? {
        if case .voiceSpeaking(let card) = model.phase, let round = card.round { return "Round \(round)" }
        return nil
    }
}

/// What a card says: one main line in Hanken Grotesk 15/22 semibold, an instruction as a ruled quote,
/// and at most two actions. Where it came from sits behind the info button.
struct CardBody: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        switch model.phase {
        case .speaking(let card):
            VStack(alignment: .leading, spacing: 12) {
                CoachText(card.observation)
                Instruction(label: "Next step", text: card.nextStep)
                if model.pointing {
                    Label { Text("Circled on your \(card.appName) window").font(TypeFace.body(13, weight: 550)) }
                        icon: { Image(systemName: "circle.circle") }
                        .foregroundStyle(Color(Tok.ink))
                }
                HStack(spacing: 8) {
                    // Only actions that can work: a sample card has no record to open or undo.
                    if !card.isPreview {
                        Button("Ask Muse") { model.onAskMuse() }.buttonStyle(CartButtonStyle())
                        Button("Undo") { model.onUndo() }.buttonStyle(CartButtonStyle(primary: false))
                    }
                    SampleTag(isPreview: card.isPreview, text: "Sample card")
                    Spacer()
                    if !card.isPreview { InfoButton(text: "\(card.appName), \(card.modelLabel), receipt \(card.receiptID.prefix(8))") }
                }
            }
        case .nudging(let nudge, _):
            VStack(alignment: .leading, spacing: 8) {
                CoachText(nudge.detail)
                Text("Goal: \(nudge.goalTitle)").font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted))
            }
        case .offline(let reason, let retryable):
            VStack(alignment: .leading, spacing: 12) {
                CoachText(reason)
                if retryable { Button("Retry") { model.onRetry() }.buttonStyle(CartButtonStyle()) }
            }
        case .permission:
            VStack(alignment: .leading, spacing: 12) {
                CoachText("\(MascotName) reads only the front window, and only when you ask. The picture never leaves this Mac.")
                ShortcutLine(text: "Read a window: ⌃⌥Space", font: TypeFace.body(13, weight: 550), ink: Tok.muted)
                HStack(spacing: 8) {
                    Button("Continue") { model.onPermissionContinue() }.buttonStyle(CartButtonStyle())
                    Button("Open System Settings") { model.onOpenSettings() }.buttonStyle(CartButtonStyle(primary: false))
                    Spacer()
                }
            }
        case .voiceSpeaking(let card):
            VoiceCardView(card: card, onLayout: { model.layoutNeeded() })
        case .voiceError(let message, let retryable):
            VStack(alignment: .leading, spacing: 12) {
                CoachText(message)
                HStack(spacing: 8) {
                    if retryable { Button("Retry") { model.onVoiceRetry() }.buttonStyle(CartButtonStyle()) }
                    Text(retryable ? "Your recording waits on this Mac." : "Your recording was deleted.")
                        .font(TypeFace.body(13, weight: 450)).foregroundStyle(Color(Tok.muted))
                    Spacer()
                }
            }
        case .micPermission(let denied):
            VStack(alignment: .leading, spacing: 12) {
                CoachText(denied ? "Turn it on in Privacy & Security › Microphone, then try again."
                                 : "\(MascotName) listens only while you hold the talk keys, and deletes each recording once it's sent.")
                ShortcutLine(text: "Talk: hold ⌃⌥T", font: TypeFace.body(13, weight: 550), ink: Tok.muted)
                HStack(spacing: 8) {
                    if !denied { Button("Continue") { model.onMicContinue() }.buttonStyle(CartButtonStyle()) }
                    Button("Open System Settings") { model.onOpenMicSettings() }.buttonStyle(CartButtonStyle(primary: denied))
                    Spacer()
                }
            }
        default:
            EmptyView()
        }
    }
}

/// "Sample card" / "Sample numbers": in DEBUG previews only, never in a normal or filming build.
struct SampleTag: View {
    let isPreview: Bool
    let text: String
    var body: some View {
        #if DEBUG
        if isPreview { Text(text).font(TypeFace.body(12, weight: 550)).foregroundStyle(Color(Tok.muted)) }
        #endif
    }
}

/// What Tug says: Hanken Grotesk about 15/22 semibold.
struct CoachText: View {
    let text: String
    var size: CGFloat = 15
    init(_ text: String, size: CGFloat = 15) { self.text = text; self.size = size }
    var body: some View {
        Text(noWidow(text)).font(TypeFace.body(size, weight: 600)).lineSpacing(size * 0.17)
            .foregroundStyle(Color(Tok.ink)).fixedSize(horizontal: false, vertical: true)
    }
}

/// An instruction: a quote with an ink rule on the left, never a filled block that looks like a button.
struct Instruction: View {
    let label: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Color(Tok.ink)).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted))
                CoachText(text)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// A spoken-round card, cut to what matters: the words of yours it pressed on, the question, one measured
/// number, and what to do next. What you said is one click away; where it came from is behind the info button.
struct VoiceCardView: View {
    let card: VoiceCard
    var onLayout: () -> Void = {}
    @State private var showTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = card.summary {
                BigNumberTile(number: LatestRoundNumber.make(summary: summary, latest: nil)!)
            }
            if let quote = card.quote { QuoteTag(quote: quote) }
            CoachText(card.question, size: 16).accessibilityLabel("Question: \(card.question)")
            if card.summary == nil, let stat = LatestRoundNumber.make(summary: nil, latest: card.metrics) {
                HabitChip(count: stat.value, habit: stat.habit, caption: "in this answer")
            }
            ReplayRow(card: card) // the camera chip, or the hands check (ReplayStrip.swift)
            if card.needLine != nil || card.codeOnly { NeedLine(card: card) }
            if !card.transcript.isEmpty, card.summary == nil {
                DisclosureGroup(isExpanded: $showTranscript) {
                    Transcript(text: card.transcriptSnippet, mark: card.quote).padding(.top, 4)
                } label: {
                    Text("What you said").font(TypeFace.body(13, weight: 600)).foregroundStyle(Color(Tok.muted))
                }
                .onChange(of: showTranscript) { _, _ in onLayout() }
            }
            HStack(spacing: 8) {
                if card.finished && !card.endsRound { YourTurnBar() }
                else if card.finished { ShortcutLine(text: "Hold ⌃⌥T to start again", font: TypeFace.body(13, weight: 600), ink: Tok.muted) }
                SampleTag(isPreview: card.isPreview, text: card.summary == nil ? "Sample answer" : "Sample numbers")
                Spacer(minLength: 0)
                if let note = card.recordingNote { RecordingKeptTag(text: note) }
                if !card.isPreview { InfoButton(text: provenance) }
            }
        }
    }

    private var provenance: String {
        [card.voiceNote, card.shortLatency, "\(card.modelLabel), \(card.receiptID.isEmpty ? "saving" : "receipt \(card.receiptID.prefix(8))")\(card.replayed ? ", already saved" : "")"]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

/// "Recording kept": the server kept this answer's audio because Keep my recordings is on.
struct RecordingKeptTag: View {
    let text: String
    var body: some View {
        Text(text).font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted))
            .lineLimit(1)
            .accessibilityLabel(text)
    }
}

/// "Your turn": the cue that the question has been asked, with the keys to hold. Its edge pulses gently;
/// still with Reduce Motion.
struct YourTurnBar: View {
    @Environment(\.reduceMotionOn) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let pulse = reduceMotion ? 1 : 0.55 + 0.45 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.6)
            HStack(spacing: 8) {
                Text("Your turn").font(TypeFace.body(14, weight: 700)).foregroundStyle(Color(Tok.inkFixed)).lineLimit(1)
                ShortcutLine(text: "hold ⌃⌥T", font: TypeFace.body(13, weight: 600), ink: Tok.inkFixed)
            }
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(Tok.field)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(Tok.inkFixed).opacity(0.25 + 0.5 * pulse), lineWidth: 1.5))
        }
        // The bar keeps its own width: without this the row squeezed "Your turn" until it broke letter by letter.
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your turn. Hold Control Option T to answer.")
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// "You said “I think”": your own words, as the server checked them against the transcript.
struct QuoteTag: View {
    let quote: String
    var body: some View {
        HStack(spacing: 6) {
            Text("You said").font(TypeFace.body(12, weight: 550)).foregroundStyle(Color(Tok.muted))
            Text("\u{201C}\(quote)\u{201D}").font(TypeFace.body(15, weight: 700)).foregroundStyle(Color(Tok.ink))
        }
        .padding(.horizontal, 10).frame(height: 30)
        .thinEdge(radius: 9)
        .accessibilityElement(children: .combine)
    }
}

/// What it heard, in the body face, with the pressed words marked in sunflower.
struct Transcript: View {
    let text: String
    let mark: String?
    var body: some View {
        Text(attributed).font(TypeFace.body(13, weight: 450)).lineSpacing(3).foregroundStyle(Color(Tok.muted))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("You said: \(text)")
    }
    private var attributed: AttributedString {
        var s = AttributedString(text)
        if let mark, let range = s.range(of: mark, options: .caseInsensitive) {
            s[range].backgroundColor = Color(Tok.field)
            s[range].foregroundColor = Color(Tok.inkFixed)
        }
        return s
    }
}

/// A measured habit as a chip in its own colour, always with its word ("2 fillers"), so the colour has a
/// visible reason. Lighter fills on the dark HUD.
struct HabitChip: View {
    let count: Int
    let habit: RoundSummary.Habit
    var caption: String? = nil
    @Environment(\.colorScheme) private var scheme

    static func colours(_ habit: RoundSummary.Habit) -> (fill: NSColor, edge: NSColor) {
        switch habit {
        case .filler: (Tok.filler, Tok.fillerEdge)
        case .hedge: (Tok.hedge, Tok.hedgeEdge)
        case .restart: (Tok.restart, Tok.restartEdge)
        }
    }

    var body: some View {
        let (fill, edge) = Self.colours(habit)
        let dark = scheme == .dark
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(count)").font(TypeFace.display(17, weight: 800))
                Text(count == 1 ? habit.rawValue : habit.rawValue + "s").font(TypeFace.body(13, weight: 650))
            }
            .foregroundStyle(Color(dark ? Tok.ink : Tok.inkFixed))
            .padding(.horizontal, 9).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(dark ? edge : fill).opacity(dark ? 0.3 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(edge).opacity(dark ? 0.8 : 0.6), lineWidth: 1))
            if let caption { Text(caption).font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Measured by code: \(RoundSummary.count(count, habit))\(caption.map { " \($0)" } ?? "")")
    }
}

/// The round's one big number. An improvement sits on sunflower, with the change in words; no alarm colour.
/// Otherwise a neutral tile, with the habit's chip naming what it counts.
struct BigNumberTile: View {
    let number: LatestRoundNumber
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("\(number.value)").font(TypeFace.display(54, weight: 850)).monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                // Good news reads as words on sunflower; otherwise the habit's own coloured tag.
                if number.improved {
                    Text(number.value == 1 ? number.habit.rawValue : number.habit.rawValue + "s").font(TypeFace.display(18, weight: 800))
                } else {
                    HabitChipWord(habit: number.habit, count: number.value)
                }
                Text(number.caption).font(TypeFace.body(13, weight: 550)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(number.improved ? Tok.inkFixed : Tok.ink))
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .thinEdge(radius: 12, fill: number.improved ? Tok.field : Tok.surface, edge: number.improved ? Tok.inkFixed.withAlphaComponent(0.25) : Tok.edge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(RoundSummary.count(number.value, number.habit)) \(number.caption)")
    }
}

/// The habit's word in its colour, as a small tag.
struct HabitChipWord: View {
    let habit: RoundSummary.Habit
    let count: Int
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let (fill, edge) = HabitChip.colours(habit)
        let dark = scheme == .dark
        Text(count == 1 ? habit.rawValue : habit.rawValue + "s").font(TypeFace.display(16, weight: 800))
            .foregroundStyle(Color(dark ? Tok.ink : Tok.inkFixed))
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(dark ? edge : fill).opacity(dark ? 0.3 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(edge).opacity(0.6), lineWidth: 1))
    }
}
