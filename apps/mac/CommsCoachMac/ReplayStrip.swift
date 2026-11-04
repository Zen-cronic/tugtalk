import SwiftUI
import ScreenContextCore

/// The hands check on a reply card. On a round's wrap-up it shows that round's strip (instead of the camera chip,
/// so "faced the camera" and SAM never share a card). On the other replies it offers the per-round toggle.
struct ReplayRow: View {
    let card: VoiceCard
    /// The floating card shows the camera chip here; the top bar's card has none.
    var showsCamera = true
    @ObservedObject private var check = ReplayCheck.shared

    var body: some View {
        if card.endsRound, let result = check.results[card.roundID] {
            ReplayStrip(result: result)
        } else {
            if showsCamera, let camera = card.camera { CameraChip(metrics: camera) }
            if !card.endsRound, !card.isPreview, check.available { ReplayToggle(check: check) }
        }
    }
}

/// "Check what's in my hands this round", with what it sends in one line under it.
struct ReplayToggle: View {
    @ObservedObject var check: ReplayCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { check.armed }, set: { check.setArmed($0) })) {
                Text("Check what's in my hands this round").font(TypeFace.body(13, weight: 650)).foregroundStyle(Color(Tok.ink))
            }
            .toggleStyle(.switch).controlSize(.mini)
            Text(check.armed ? "Starts with your next answer. A short silent clip goes to Meta's SAM 3.1 at the end of the round. Only the seconds are kept."
                             : "Sends a short silent clip to Meta's SAM 3.1. Only the seconds are kept.")
                .font(TypeFace.body(12, weight: 500)).foregroundStyle(Color(Tok.muted))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One cell per second of the round's answers, filled by the share of that second with a phone or paper in hand,
/// then the label: "phone in hand 3 s, found by SAM 3.1, counted by code". Counted objects only.
struct ReplayStrip: View {
    let result: ReplayCheck.Result

    var body: some View {
        switch result {
        case .sending:
            HStack(spacing: 8) {
                ThinkingDots()
                Text("Checking what's in your hands with SAM 3.1").font(TypeFace.body(13, weight: 600)).foregroundStyle(Color(Tok.muted))
            }
            .accessibilityElement(children: .combine)
        case .counted(let counts):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(Array(counts.cells.enumerated()), id: \.offset) { _, fill in ReplayCell(fill: fill) }
                }
                Text("\(counts.label), found by SAM 3.1, counted by code")
                    .font(TypeFace.body(13, weight: 650)).foregroundStyle(Color(Tok.ink))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .help("Meta's SAM 3.1 found hands, phones and paper in a silent clip of this round (\(counts.frames) frames, \(counts.fps) a second). "
                  + "Code counted the frames where a phone or paper box overlapped a hand box. The clip was not kept.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hands check, \(counts.per_second.count) seconds of answers: \(counts.label). Found by SAM 3.1, counted by code.")
        case .unavailable(let why):
            Text("Hands check unavailable").font(TypeFace.body(13, weight: 600)).foregroundStyle(Color(Tok.muted))
                .help(why)
                .accessibilityLabel("Hands check unavailable. \(why)")
        }
    }
}

/// One second: an outlined cell, filled from the bottom by the share of frames with something in hand.
struct ReplayCell: View {
    let fill: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        shape.fill(Color(Tok.surface))
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Color(Tok.ink)).frame(height: geometry.size.height * fill)
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(Tok.edge), lineWidth: 1))
            .frame(width: 14, height: 20)
    }
}
