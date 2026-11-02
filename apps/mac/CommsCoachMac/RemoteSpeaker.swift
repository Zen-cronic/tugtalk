@preconcurrency import AVFoundation
import ScreenContextCore

/// The default voice: the coach server voices the round with its speech provider and returns WAV
/// or MP3, which plays here. The provider's key never reaches this Mac; the request carries only the
/// connector key, to the same host as the round. Playback starts once the clip has arrived (a
/// question is a few seconds of audio), and the server must start sending within 2 s or the Apple
/// voice takes over.
@MainActor
final class RemoteSpeaker: NSObject, ReplySpeaker, AVAudioPlayerDelegate {
    private let api: @MainActor () -> CoachAPI?
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var events: SpeechEvents?

    init(api: @escaping @MainActor () -> CoachAPI?) {
        self.api = api
    }

    func speak(_ line: SpokenLine, events: SpeechEvents) {
        stop()
        guard let roundID = line.roundID, let api = api() else {
            events.failed(CoachError.notConfigured)
            return
        }
        self.events = events
        let asked = Date()
        task = Task { [weak self] in
            do {
                let audio = try await api.fetchSpeech(roundID: roundID)
                try Task.checkCancellation()
                guard let self else { return }
                let player = try AVAudioPlayer(data: audio.data, fileTypeHint: (audio.isWAV ? AVFileType.wav : AVFileType.mp3).rawValue)
                player.delegate = self
                #if DEBUG
                if UserDefaults.standard.object(forKey: "voiceVolume") != nil {
                    player.volume = max(0, min(1, UserDefaults.standard.float(forKey: "voiceVolume")))
                }
                #endif
                guard player.prepareToPlay(), player.play() else { throw SpeechFetchError.empty }
                self.player = player
                voiceLog.notice("coach voice (\(audio.provider ?? "unnamed", privacy: .public), \(audio.contentType, privacy: .public)): \(audio.data.count, privacy: .public) bytes, playing \(Int(Date().timeIntervalSince(asked) * 1000), privacy: .public) ms after the request")
                self.events?.started(audio.provider)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, let events = self.events else { return }
                self.events = nil
                voiceLog.notice("coach voice unavailable: \(SpeechRouter.reason(for: error), privacy: .public)")
                events.failed(error)
            }
        }
    }

    /// Stops playback at once, or abandons the download.
    func stop() {
        task?.cancel()
        task = nil
        events = nil
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player), ended = Date()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let current = self.player, ObjectIdentifier(current) == id, let events = self.events else { return }
                self.player = nil
                self.events = nil
                events.finished(ended)
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
