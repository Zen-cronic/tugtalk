@preconcurrency import AVFoundation
import ScreenContextCore

/// The fallback voice: Apple's on-device synthesizer, used when the coach's voice is unavailable.
/// Not a sponsor service, and no audio leaves the Mac for this step.
@MainActor
final class AppleSpeaker: NSObject, ReplySpeaker, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: ObjectIdentifier?
    private var events: SpeechEvents?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ line: SpokenLine, events: SpeechEvents) {
        stop()
        let utterance = AVSpeechUtterance(string: line.text)
        let voice = Self.bestVoice(for: line.language)
        utterance.voice = voice
        #if DEBUG
        // `-voiceVolume 0.2` keeps local test runs quiet.
        if UserDefaults.standard.object(forKey: "voiceVolume") != nil {
            utterance.volume = max(0, min(1, UserDefaults.standard.float(forKey: "voiceVolume")))
        }
        #endif
        current = ObjectIdentifier(utterance)
        self.events = events
        voiceLog.notice("fallback voice: \(voice?.name ?? "the default voice", privacy: .public) (\(Self.qualityName(voice), privacy: .public))")
        synthesizer.speak(utterance)
    }

    /// Stops at once, mid-word.
    func stop() {
        current = nil
        events = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// A downloaded Premium voice, else Enhanced, else the system default for the language.
    /// Novelty voices are skipped. Download better voices in System Settings › Accessibility › Spoken Content.
    static func bestVoice(for language: VoiceLanguage) -> AVSpeechSynthesisVoice? {
        let preferred = Locale.preferredLanguages.first { $0.hasPrefix(language.rawValue) } ?? (language == .en ? "en-US" : "fr-CA")
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(language.rawValue) && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        func score(_ voice: AVSpeechSynthesisVoice) -> Int {
            let quality = voice.quality == .premium ? 30 : voice.quality == .enhanced ? 20 : 10
            return quality + (voice.language == preferred ? 2 : 0) + (voice.language == (language == .en ? "en-US" : "fr-CA") ? 1 : 0)
        }
        return candidates.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: preferred)
    }

    static func qualityName(_ voice: AVSpeechSynthesisVoice?) -> String {
        switch voice?.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "default quality"
        }
    }

    // The synthesizer may call back off the main thread; each callback hops to it and is matched
    // to the utterance still current, so a stopped question never reports a finish.

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { if self.current == id { self.events?.started(nil) } } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance), ended = Date()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.current == id, let events = self.events else { return }
                self.current = nil
                self.events = nil
                events.finished(ended)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { if self.current == id { self.current = nil; self.events = nil } } }
    }
}
