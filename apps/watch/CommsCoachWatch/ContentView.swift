import SwiftUI

struct ContentView: View {
    @StateObject private var model = CaptureModel()
    @State private var scrolled = false
    /// `-openSetup YES` (Debug builds): opens the setup list on launch, for a screenshot of its rows.
    @State private var showSetup = ContentView.openSetupOnLaunch
    /// "Practise this answer": a spoken round with the same goal and language.
    @State private var practise = false
    /// The result whose AI note and exercise are shown in full, after More, so every new result opens short.
    /// `-expandNote YES` (Debug builds) opens the sample result's, for a screenshot.
    @State private var expandedReceipt: String? = ContentView.flag("expandNote") ? "preview" : nil

    static var openSetupOnLaunch: Bool { flag("openSetup") }

    static func flag(_ key: String) -> Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: key)
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) { content }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6) // keeps cards clear of the screen's rounded corners
                }
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 4 } action: { _, now in
                    scrolled = now
                }
                .overlay(alignment: .top) { HeaderFade(active: scrolled) }
                .task {
                    // Once per launch: this runs again on Back from Practise, and loading again threw away the result.
                    guard case .loading = model.phase else { return }
                    await model.load()
                    #if DEBUG
                    // `-scrollToDrill YES`: shows the drill line below Record, or the drill result, for a screenshot.
                    if UserDefaults.standard.bool(forKey: "scrollToDrill") { try? await Task.sleep(for: .milliseconds(600)); proxy.scrollTo("drill", anchor: .bottom) }
                    // `-openSparring YES`: opens the practice round once the goals are loaded, for simulator runs.
                    if case .ready = model.phase, UserDefaults.standard.bool(forKey: "openSparring") { practise = true }
                    #endif
                    if model.scrollToTry {
                        try? await Task.sleep(for: .milliseconds(400)) // let the result lay out first
                        proxy.scrollTo("try", anchor: .center)
                    } else if model.scrollToObservation || model.scrollToActions {
                        try? await Task.sleep(for: .milliseconds(400))
                        proxy.scrollTo(model.scrollToActions ? "actions" : "observation", anchor: .bottom)
                    }
                }
            }
            .navigationTitle(showingResult ? "Result" : "TugTalk")
            #if DEBUG
            // Launch flags only (`-openSetup`, `-openSparring`). Taps use NavigationLink, as the goal card does:
            // on the watch, a tap that set `practise` never opened the round (TestFlight build 8).
            .navigationDestination(isPresented: $showSetup) { SetupList(model: model) }
            .navigationDestination(isPresented: $practise) { practiseRound }
            #endif
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var showingResult: Bool {
        if case .done = model.phase { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView { Text("Loading goals").face(.text, 15) }
                .tint(Palette.inkDark)
                .foregroundStyle(Palette.inkDark)
        case .ready:
            setup
            Button { Task { await model.startRecording() } } label: {
                Label { Text("Record") } icon: { RecordLamp(lit: false) }
            }
            .buttonStyle(CoachButtonStyle(height: 52))
            practiseButton
                .padding(.bottom, 8)
            if let drill = model.drill { DrillLine(drill: drill).id("drill") } // Drill.swift; below Record, so Record stays on the first screen
        case .recording:
            recording
            Button { Task { await model.stopAndUpload() } } label: {
                Label { Text("Stop") } icon: { RoundedRectangle(cornerRadius: 2).frame(width: 12, height: 12) }
            }
            .buttonStyle(CoachButtonStyle())
            Text(model.selectedGoal?.title ?? "No goal")
                .face(.text, 14, relativeTo: .footnote)
                .foregroundStyle(Palette.mutedDark)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        case .uploading:
            VStack(spacing: 6) {
                TugWorking(size: 50)
                    .padding(.bottom, 6)
                Text("Analyzing").face(.display, 20, relativeTo: .title3)
                    .foregroundStyle(Palette.inkDark)
                Text("Counting fillers, unsure words, restarts")
                    .face(.text, 14, weight: 500, relativeTo: .footnote)
                    .foregroundStyle(Palette.mutedDark)
                    .multilineTextAlignment(.center)
                ProgressDots()
                    .padding(.top, 2)
            }
            .padding(.top, 8)
        case .done(let receipt):
            result(receipt)
            Button { Task { await model.startRecording() } } label: {
                Label { Text("Record again") } icon: { RecordLamp(lit: false) }
            }
            .buttonStyle(CoachButtonStyle())
            practiseButton
            Button("Change goal") { model.phase = .ready }
                .buttonStyle(CoachButtonStyle(.secondary))
                .id("actions")
            savedLine(receipt)
        case .failed(let message):
            failure(message)
            if model.canRetryUpload {
                Button("Try again") { Task { await model.upload() } }
                    .buttonStyle(CoachButtonStyle())
            }
            Button(model.canRetryUpload ? "Back to start" : "Try again") { Task { await model.load() } }
                .buttonStyle(CoachButtonStyle(model.canRetryUpload ? .secondary : .primary))
        }
    }

    /// Opens a spoken round: answer out loud and Tug asks the follow-up, up to three answers.
    private var practiseButton: some View {
        NavigationLink { practiseRound } label: {
            Text("Practise this answer").lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 12) // clear of the capsule's curve
        }
        .buttonStyle(CoachButtonStyle(.practise))
        .accessibilityHint("Answer out loud, and Tug asks a follow-up question")
    }

    private var practiseRound: some View {
        SparringView(goal: model.selectedGoal, latestCard: model.latestCard, language: model.language)
    }

    /// Goal and language in one card; it opens one list with both choices.
    private var setup: some View {
        NavigationLink {
            SetupList(model: model)
        } label: {
            // A graphite card with sunflower details, so the solid sunflower Record button below stays the strongest thing on screen.
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selectedGoal?.title ?? "No goal").face(.text, 16, weight: 700, relativeTo: .headline)
                        .foregroundStyle(Palette.inkDark)
                    Text([model.language == "fr" ? "Français" : "English", model.settings?.keep_recordings == true ? "recordings kept" : nil]
                        .compactMap { $0 }.joined(separator: ", "))
                        .face(.text, 14, weight: 600, relativeTo: .footnote)
                        .foregroundStyle(Palette.field)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.field)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.rack, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Goal, language and recordings")
        .accessibilityValue("\(model.selectedGoal?.title ?? "No goal"), \(model.language == "fr" ? "Français" : "English")\(model.settings?.keep_recordings == true ? ", keeping recordings" : "")")
    }

    /// The recording card: the light is on, the clock runs, and the cap is stated up front.
    private var recording: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RecordLamp(lit: true)
                Text("Recording").face(.text, 15, weight: 700, relativeTo: .headline)
            }
            .foregroundStyle(Palette.inkDark)
            ElapsedLabel(recorder: model.recorder)
            Text("Stops at \(Self.clock(Recorder.maxSeconds))")
                .face(.text, 14, weight: 600, relativeTo: .footnote)
                .foregroundStyle(Palette.inkDark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.rack, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// The three counts first, then words and pace, then one short line of the AI note. More shows the rest.
    /// The counts come from code; the note is the model's own words, only shortened, never reworded.
    private func result(_ receipt: CaptureReceipt) -> some View {
        let m = receipt.record.metrics
        let analysis = receipt.record.analysis
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                SmallMetric(value: m.filler_count, singular: "filler", plural: "fillers", fill: Palette.filler, edge: Palette.fillerEdge)
                SmallMetric(value: m.hedge_count, singular: "unsure\nword", plural: "unsure\nwords", fill: Palette.hedge, edge: Palette.hedgeEdge)
                SmallMetric(value: m.restart_count, singular: "restart", plural: "restarts", fill: Palette.restart, edge: Palette.restartEdge)
            }
            .slotIn()

            Text("\(m.word_count) words" + (m.words_per_minute.map { ", \($0) wpm" } ?? ""))
                .face(.text, 14, weight: 600, relativeTo: .footnote)
                .foregroundStyle(Palette.pace)
                .padding(.horizontal, 4)

            if let drill = receipt.record.drill, drill.line != nil { DrillResultLine(outcome: drill).id("drill") } // Drill.swift

            note(analysis, expanded: expandedReceipt == receipt.receipt_id) { expandedReceipt = $0 ? receipt.receipt_id : nil }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .id("observation")
        }
    }

    /// "AI note": the observation's first sentence, or its first words, with More for the full note and exercise.
    @ViewBuilder private func note(_ analysis: Analysis, expanded noteExpanded: Bool, expand: @escaping (Bool) -> Void) -> some View {
        let short = analysis.observation.map { CoachText.short($0, maxCharacters: 64) }
        let hasMore = (short?.cut ?? false) || analysis.suggested_exercise != nil
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AI note").face(.text, 12, weight: 700, relativeTo: .caption2)
                    .foregroundStyle(Palette.mutedDark)
                Text((noteExpanded ? analysis.observation : short?.text) ?? "None this time. Counts saved.")
                    .face(.text, 14, weight: 500, relativeTo: .footnote)
                    .foregroundStyle(analysis.observation == nil ? Palette.mutedDark : Palette.inkDark)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let exercise = analysis.suggested_exercise {
                // An instruction is a quote with a rule on the left, never a filled block that looks like a button.
                HStack(alignment: .top, spacing: 8) {
                    Capsule().fill(Palette.inkDark).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Try").face(.text, 12, weight: 700, relativeTo: .caption2)
                            .foregroundStyle(Palette.mutedDark)
                        Text(noteExpanded ? exercise : CoachText.headline(of: exercise, maxWords: 6))
                            .face(.text, 14, weight: 600, relativeTo: .footnote)
                            .foregroundStyle(Palette.inkDark)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .id("try")
            }
            if hasMore {
                Button(noteExpanded ? "Less" : "More") { withAnimation(.easeOut(duration: 0.18)) { expand(!noteExpanded) } }
                    .buttonStyle(CoachButtonStyle(.secondary, height: 32))
                    .frame(width: 84)
            }
        }
    }

    /// Under the buttons: where this result also shows up, and whether its audio was kept.
    private func savedLine(_ receipt: CaptureReceipt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                TugGlyph(size: 28, reach: 8, endY: 0.6, pull: 1)
                Text("Also in Muse on your phone and Mac.")
                    .face(.text, 13, weight: 600, relativeTo: .caption)
                    .foregroundStyle(Palette.inkDark)
            }
            if let note = receipt.record.media?.note {
                // Keep my recordings is on: the server kept this answer's audio (or says why it could not).
                Text(note)
                    .face(.text, 13, weight: 600, relativeTo: .caption)
                    .foregroundStyle(Palette.mutedDark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    /// A worried Tug with a cut string, the error in plain words, and what is still safe, above the action.
    private func failure(_ message: String) -> some View {
        VStack(spacing: 4) {
            TugGlyph(size: 32, reach: 14, cut: true, worried: true)
            Text(message)
                .face(.text, 15, relativeTo: .body)
                .foregroundStyle(Palette.inkDark)
                .multilineTextAlignment(.center)
            if model.canRetryUpload {
                Text("Answer saved on the watch.")
                    .face(.text, 13, weight: 600, relativeTo: .caption)
                    .foregroundStyle(Palette.mutedDark)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, 2)
    }
}

private struct SmallMetric: View {
    let value: Int
    let singular: String
    let plural: String
    let fill: Color
    let edge: Color

    var body: some View {
        CartChip(fill: fill, edge: edge) {
            VStack(spacing: 0) {
                Text("\(value)").face(.display, 26, relativeTo: .title3).monospacedDigit()
                // Two lines reserved, so "unsure⏎words" sits one word per line and both chips keep one height;
                // a word shrinks slightly rather than breaking in the middle.
                Text(value == 1 ? singular : plural).face(.text, 12, weight: 700, relativeTo: .caption2)
                    .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The recording light. Unlit it is a ring. Lit it is solid, and a ring pulses out from it while the mic is live.
/// With Reduce Motion the pulse is replaced by a steady outer ring.
struct RecordLamp: View {
    let lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if lit {
                Circle().stroke(Palette.recordDot, lineWidth: 1.5)
                    .scaleEffect(reduceMotion ? 1.6 : (pulse ? 2.1 : 1))
                    .opacity(reduceMotion ? 0.7 : (pulse ? 0 : 0.9))
                Circle().fill(Palette.recordDot)
            } else {
                Circle().strokeBorder(Palette.ink, lineWidth: 2) // unlit, it sits on an ink-dark button
            }
        }
        .frame(width: 13, height: 13)
        .padding(lit ? 4 : 0) // room for the outer ring
        .onAppear {
            guard lit, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

/// Three dots that light in turn while the answer is analysed. They change brightness only, never position,
/// so they stay the same with Reduce Motion.
struct ProgressDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 3
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Palette.inkDark).frame(width: 6, height: 6).opacity(i == step ? 1 : 0.42) // the dim dots stay above 3:1 on the face
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Scrolled content fades out before it reaches the clock and title band, so text never shows behind the title.
/// Static, so it is the same with Reduce Motion.
/// It is an overlay in the face's own black that never takes a touch, not a mask on the scroll view: with the
/// mask on (once the content had scrolled), the real watch scrolled but dropped every tap on the buttons (build 10).
struct HeaderFade: View {
    /// Off at rest, so nothing below the large title is touched; on once the content scrolls under the title.
    let active: Bool

    var body: some View {
        VStack(spacing: 0) {
            Palette.face.frame(height: active ? 44 : 0)
            LinearGradient(colors: [Palette.face, Palette.face.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: active ? 10 : 0)
            Color.clear
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Both setup choices on one list. Picking an option marks it; Back returns to Record.
private struct SetupList: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section("Goal") {
                    option("No goal", selected: model.selectedGoal == nil) { model.selectedGoal = nil }
                    ForEach(model.goals) { goal in
                        option(goal.title, selected: model.selectedGoal == goal) { model.selectedGoal = goal }
                    }
                }
                Section("Language") {
                    option("English", selected: model.language == "en") { model.language = "en" }
                    option("Français", selected: model.language == "fr") { model.language = "fr" }
                }
                Section {
                    if let settings = model.settings {
                        Toggle(isOn: Binding(get: { settings.keep_recordings }, set: { on in
                            // Turning it off with recordings kept asks whether to delete them too.
                            if !on, (settings.kept?.recordings ?? 0) > 0 { confirmOff = true } else { Task { await model.setKeepRecordings(on) } }
                        })) {
                            Text("Keep my recordings").face(.text, 16, relativeTo: .body)
                        }
                        .tint(Palette.field)
                    } else {
                        Text(model.settingsNote == nil ? "Keep my recordings: checking" : "Keep my recordings: unavailable").face(.text, 15, relativeTo: .body).foregroundStyle(Palette.muted)
                    }
                } header: {
                    Text("Recordings")
                } footer: {
                    Text(recordingsFooter).face(.text, 13, relativeTo: .caption)
                }
                .id("recordings")
            }
            .task {
                #if DEBUG
                // `-setupScrollToRecordings YES`: shows the Keep my recordings row, for a screenshot.
                if UserDefaults.standard.bool(forKey: "setupScrollToRecordings") { try? await Task.sleep(for: .milliseconds(600)); proxy.scrollTo("recordings", anchor: .top) }
                #endif
            }
        }
        .navigationTitle("Setup")
        .confirmationDialog("Turn off Keep my recordings?", isPresented: $confirmOff, titleVisibility: .visible) {
            // No destructive role: its red would read as fillers. The label says what it deletes.
            Button("Turn off and delete kept recordings") { Task { await model.setKeepRecordings(false, deleteKept: true) } }
            Button("Turn off") { Task { await model.setKeepRecordings(false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New recordings will be deleted after transcription.")
        }
    }

    @State private var confirmOff = false

    /// What the setting does, how much is kept, and the last error, in plain words.
    private var recordingsFooter: String {
        var lines = [model.settings?.keep_recordings == true ? "On: recordings stay in your account until you delete them." : "Off: audio is deleted after transcription."]
        if let kept = model.settings?.kept, kept.recordings > 0 {
            lines.append("\(kept.recordings) kept, \(String(format: "%.1f", Double(kept.bytes) / 1_000_000)) MB.")
        }
        if let note = model.settingsNote { lines.append(note) }
        return lines.joined(separator: " ")
    }

    private func option(_ title: String, selected: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack {
                Text(title).face(.text, 16, relativeTo: .body)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.field) }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Observes the recorder itself: a nested ObservableObject's changes do not
/// propagate through CaptureModel, so reading it from ContentView never redraws.
struct ElapsedLabel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        Text(ContentView.clock(recorder.elapsed))
            .face(.display, 34, relativeTo: .title)
            .monospacedDigit()
            .foregroundStyle(Palette.inkDark)
            .contentTransition(.numericText())
    }
}
