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
let appDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Comms Coach"

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

/// The plain-word status attached to Tug: an icon and one word, never colour alone.
struct StatusPill: View {
    let phase: MascotPhase
    var talking = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let pill = talking ? ("Speaking", nil) : phase.pill(now: context.date)
            HStack(spacing: 7) {
                if case .voiceListening = phase { RecordDot() } else {
                    Image(systemName: talking ? "speaker.wave.2.fill" : phase.symbol).font(.system(size: 12, weight: .bold))
                }
                Text(pill.0).font(TypeFace.body(14, weight: 650)).lineLimit(1)
                if let detail = pill.1 { Text(detail).font(TypeFace.mono(12)).foregroundStyle(Color(Tok.muted)) }
            }
            .foregroundStyle(Color(Tok.ink))
            .padding(.horizontal, 12).frame(height: 32)
            .cartLabel(radius: 10, lip: 2.5)
            .fixedSize()
        }
        .accessibilityHidden(true)
    }
}

/// The record dot: ink, lit while the microphone is open. A slow pulse; still with Reduce Motion.
struct RecordDot: View {
    var color: NSColor = Tok.ink
    @Environment(\.reduceMotionOn) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2 * .pi / 1.2)
            ZStack {
                Circle().stroke(Color(color).opacity(0.25 + 0.35 * pulse), lineWidth: 2).frame(width: 14, height: 14)
                Circle().fill(Color(color)).frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
    }
}

extension View {
    /// A white label on a cart shell: a hairline edge and a darker lip along the bottom.
    func cartLabel(radius: CGFloat = MascotLayout.radius, lip: CGFloat = 3, fill: NSColor = Tok.surface, edge: NSColor = Tok.cardEdge, lipColor: NSColor = Tok.inkFixed) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(Color(fill)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(edge), lineWidth: 1.5))
            .background(shape.fill(Color(lipColor)).offset(y: lip))
    }
}

/// Buttons are at least 32 pt tall. The primary one is ink with white text; the rest are outlined.
struct CartButtonStyle: ButtonStyle {
    var primary = true
    /// Stretch to the row's width, for a grid of equal buttons.
    var fill = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(TypeFace.body(14, weight: 650))
            .foregroundStyle(Color(primary ? Tok.onAction : Tok.ink))
            .padding(.horizontal, 14).frame(maxWidth: fill ? .infinity : nil, minHeight: 34)
            .background(shape.fill(Color(primary ? Tok.action : Tok.surface)))
            .overlay(shape.strokeBorder(Color(Tok.action), lineWidth: primary ? 0 : 1.5))
            .offset(y: configuration.isPressed ? 1 : 0)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

/// A card: Tug in a coloured header (sunflower, or graphite when something stopped), then the body.
struct CardView: View {
    @ObservedObject var model: CompanionModel
    var onDrag: (DragGesture.Value?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            CardBody(model: model).padding(16)
        }
        .cartLabel()
    }

    private var problem: Bool { model.phase.isProblem }

    private var header: some View {
        let onBand = problem ? Tok.onGraphite : Tok.inkFixed
        return HStack(alignment: .center, spacing: 10) {
            TugView(phase: model.phase, talking: model.talking, facesRight: true)
                .frame(width: MascotLayout.headerTug, height: MascotLayout.headerTug)
                .contentShape(Rectangle())
                .onTapGesture { model.clicked() }
                .tugAccessibility(model)
                // On the graphite band the string turns cream, like the dark HUD.
                .environment(\.colorScheme, problem ? .dark : .light)
            VStack(alignment: .leading, spacing: 2) {
                Text(noWidow(model.phase.heading)).font(TypeFace.display(17, weight: 800)).lineLimit(2)
                if let status = statusLine { Text(status).font(TypeFace.body(13, weight: 550)).opacity(0.85) }
            }
            .foregroundStyle(Color(onBand))
            Spacer(minLength: 4)
            if let round = roundLabel {
                Text(round).font(TypeFace.mono(12, weight: 600)).foregroundStyle(Color(onBand))
                    .padding(.horizontal, 8).frame(height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(onBand), lineWidth: 1.5))
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
        .background(Color(problem ? Tok.problemBand : Tok.field))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(Tok.cardEdge)).frame(height: 1.5) }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global).onChanged { onDrag($0) }.onEnded { _ in onDrag(nil) })
    }

    /// The live turn word under the heading, for voice replies.
    private var statusLine: String? {
        switch model.phase {
        case .voiceSpeaking(let card): card.endsRound && card.finished ? nil : model.phase.pill().word
        case .speaking: model.talking ? "Speaking" : nil
        default: nil
        }
    }

    private var roundLabel: String? {
        if case .voiceSpeaking(let card) = model.phase, let round = card.round { return "Round \(round)" }
        return nil
    }
}

/// What a card says. One main line in Hanken Grotesk 15/22 semibold, an instruction as a ruled quote,
/// a small source line, and at most two buttons.
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
                SourceLine(card.isPreview ? "Sample card" : "\(card.appName) · \(card.modelLabel) · receipt \(card.receiptID.prefix(8))")
                HStack(spacing: 8) {
                    Button("Ask Muse") { model.onAskMuse() }.buttonStyle(CartButtonStyle())
                    Button("Undo") { model.onUndo() }.buttonStyle(CartButtonStyle(primary: false))
                    Spacer()
                }
            }
        case .nudging(let nudge, _):
            VStack(alignment: .leading, spacing: 10) {
                CoachText(nudge.detail)
                SourceLine("Goal: \(nudge.goalTitle) · from the shared record")
            }
        case .offline(let reason, let retryable):
            VStack(alignment: .leading, spacing: 12) {
                CoachText(reason)
                if retryable {
                    Button("Retry") { model.onRetry() }.buttonStyle(CartButtonStyle())
                }
            }
        case .permission:
            VStack(alignment: .leading, spacing: 12) {
                CoachText("\(MascotName) reads only the front window, only when you press ⌃⌥Space. The picture never leaves this Mac.")
                HStack(spacing: 8) {
                    Button("Continue") { model.onPermissionContinue() }.buttonStyle(CartButtonStyle())
                    Button("Open System Settings") { model.onOpenSettings() }.buttonStyle(CartButtonStyle(primary: false))
                    Spacer()
                }
            }
        case .voiceSpeaking(let card):
            VoiceCardView(card: card)
        case .voiceError(let message, let retryable):
            VStack(alignment: .leading, spacing: 12) {
                CoachText(message)
                HStack(spacing: 8) {
                    if retryable { Button("Retry") { model.onVoiceRetry() }.buttonStyle(CartButtonStyle()) }
                    Text(retryable ? "The recording waits on this Mac." : "The recording was deleted.")
                        .font(TypeFace.body(13, weight: 450)).foregroundStyle(Color(Tok.muted))
                    Spacer()
                }
            }
        case .micPermission(let denied):
            VStack(alignment: .leading, spacing: 12) {
                CoachText(denied ? "Turn it on in Privacy & Security › Microphone, then hold ⌃⌥T again."
                                 : "\(MascotName) listens only while you hold ⌃⌥T. Each recording is deleted once it's sent.")
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

struct SourceLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(TypeFace.mono(11, weight: 450)).foregroundStyle(Color(Tok.muted)).fixedSize(horizontal: false, vertical: true)
    }
}

/// A spoken-round card: the words of yours it pressed on, the question, what it heard, and the measured habits.
/// On a wrap-up, the round's one big number instead.
struct VoiceCardView: View {
    let card: VoiceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = card.summary { BigNumber(summary: summary) }
            if let quote = card.quote { QuoteTag(quote: quote) }
            CoachText(card.question, size: card.summary == nil ? 16 : 15)
                .accessibilityLabel("Question: \(card.question)")
            if !card.transcriptSnippet.isEmpty, card.summary == nil {
                Transcript(text: card.transcriptSnippet, mark: card.quote)
            }
            if card.summary == nil, let m = card.metrics { MetricRow(metrics: m) }
            VStack(alignment: .leading, spacing: 3) {
                if let line = [card.voiceNote, card.shortLatency].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                    Text(noWidow(line)).font(TypeFace.body(12, weight: 500)).foregroundStyle(Color(Tok.muted)).fixedSize(horizontal: false, vertical: true)
                }
                SourceLine(card.sampleSource ?? "\(card.modelLabel) · receipt \(card.receiptID.prefix(8))\(card.replayed ? " · already saved" : "")")
            }
        }
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
        .cartLabel(radius: 9, lip: 2.5)
        .accessibilityElement(children: .combine)
    }
}

/// What it heard, in mono, with the pressed words marked in sunflower.
struct Transcript: View {
    let text: String
    let mark: String?
    var body: some View {
        Text(attributed).font(TypeFace.mono(12, weight: 450)).lineSpacing(3).foregroundStyle(Color(Tok.muted))
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
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

/// One chip per measured habit, each in its own token, with plain singular and plural labels.
struct MetricRow: View {
    let metrics: VoiceMetrics
    var body: some View {
        HStack(spacing: 6) {
            if let n = metrics.filler_count { chip(n, n == 1 ? "filler" : "fillers", fill: Tok.filler, lip: Tok.fillerEdge) }
            if let n = metrics.hedge_count { chip(n, n == 1 ? "hedge" : "hedges", fill: Tok.hedge, lip: Tok.hedgeEdge) }
            if let n = metrics.restart_count { chip(n, n == 1 ? "restart" : "restarts", fill: Tok.restart, lip: Tok.restartEdge) }
            if let wpm = metrics.words_per_minute { chip(Int(wpm.rounded()), "wpm", fill: Tok.surface, lip: Tok.inkFixed, neutral: true) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Measured by code")
    }

    private func chip(_ n: Int, _ label: String, fill: NSColor, lip: NSColor, neutral: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(n)").font(TypeFace.display(17, weight: 800))
            Text(label).font(TypeFace.body(12, weight: 600))
        }
        .foregroundStyle(Color(neutral ? Tok.ink : Tok.inkFixed))
        .padding(.horizontal, 9).frame(height: 30)
        .cartLabel(radius: 8, lip: 3, fill: fill, edge: neutral ? Tok.cardEdge : lip, lipColor: lip)
    }
}

/// The round summary: one big number, from code.
struct BigNumber: View {
    let summary: RoundSummary
    var body: some View {
        let (fill, lip): (NSColor, NSColor) = switch summary.habit {
        case .filler: (Tok.filler, Tok.fillerEdge)
        case .hedge: (Tok.hedge, Tok.hedgeEdge)
        case .restart: (Tok.restart, Tok.restartEdge)
        }
        HStack(alignment: .center, spacing: 14) {
            Text("\(summary.last)").font(TypeFace.display(58, weight: 850)).monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.last == 1 ? summary.habit.rawValue : summary.habit.rawValue + "s").font(TypeFace.display(19, weight: 800))
                Text(summary.dropped ? "down from \(summary.first) in your first answer" : "in your last answer (\(summary.first) in the first)")
                    .font(TypeFace.body(13, weight: 550)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(Tok.inkFixed))
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cartLabel(radius: 12, lip: 4, fill: fill, edge: lip, lipColor: lip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(RoundSummary.count(summary.last, summary.habit)) in your last answer, \(summary.first) in your first, over \(summary.answers) answers.")
    }
}
