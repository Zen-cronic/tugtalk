import AVFoundation
import Foundation

/// Tap-to-capture recorder. Writes mono 16-bit PCM WAV at 16 kHz, the format the
/// backend accepts as-is. Recording continues wrist-down only because the user
/// started it in the foreground; there is no background or always-on capture.
@MainActor
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    /// The recording stops itself here; the backend limit is 180 s.
    static let maxSeconds: TimeInterval = {
        #if DEBUG
        // Debug builds only: `-captureCapSeconds 5` reaches the cap in seconds, to exercise the auto-stop path.
        let override = UserDefaults.standard.double(forKey: "captureCapSeconds")
        if override >= 1 { return min(override, 170) }
        #endif
        return 170
    }()

    /// Called when the recording stops by itself, with the finished file: at `maxSeconds` (`capped` true), or cut
    /// short by an interruption such as a call or Siri (`capped` false, so it is treated as a Stop tap).
    /// A Stop tap never calls it: `stop()` hands its file back directly.
    var onAutoStop: (@MainActor (URL, _ capped: Bool) -> Void)?

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var startedAt = Date()

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws -> URL {
        // Already recording: the running recording is stopped and deleted first, so no file or timer is orphaned.
        if isRecording { discardRunning() }
        let session = AVAudioSession.sharedInstance()
        // .spokenAudio is a playback mode; paired with .record a real watch rejects it with OSStatus -50.
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString).wav")
        // The backend accepts 16 kHz or 24 kHz mono 16-bit PCM. Try 16 kHz first, then 24 kHz if the hardware refuses it.
        var recorder: AVAudioRecorder?
        var lastError: Error?
        for rate in [16_000, 24_000] {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            do {
                let candidate = try AVAudioRecorder(url: url, settings: settings)
                candidate.delegate = self
                if candidate.record(forDuration: Self.maxSeconds) { recorder = candidate; break }
                candidate.deleteRecording()
            } catch { lastError = error }
        }
        guard let recorder else {
            try? session.setActive(false)
            throw lastError ?? CoachError.server(0, "Recording could not start")
        }
        self.recorder = recorder
        startedAt = Date()
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return url
    }

    private func tick() {
        #if DEBUG
        if fixtureCopy != nil { elapsed = Date().timeIntervalSince(startedAt); return }
        #endif
        guard let recorder else { return }
        elapsed = recorder.currentTime
    }

    /// Stops and returns the finished file, or nil if nothing was recording.
    func stop() -> URL? {
        #if DEBUG
        if let url = fixtureCopy { fixtureCopy = nil; timer?.invalidate(); timer = nil; isRecording = false; return url }
        #endif
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        finish()
        return url
    }

    #if DEBUG
    /// Debug builds only: a copy of a WAV file stands in for the microphone (no permission is asked), so a whole
    /// practice round runs in the simulator with known audio. The clock runs as if recording; Stop returns the copy.
    private var fixtureCopy: URL?

    func startFixture(_ source: URL) throws -> URL {
        if isRecording { discardRunning() }
        let url = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: source, to: url)
        fixtureCopy = url
        startedAt = Date()
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return url
    }
    #endif

    private func discardRunning() {
        #if DEBUG
        if let url = fixtureCopy { fixtureCopy = nil; try? FileManager.default.removeItem(at: url) }
        #endif
        if let running = recorder { recorder = nil; running.stop(); running.deleteRecording() }
        finish()
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            // After a Stop tap `self.recorder` is already nil, so only a stop the recorder made itself gets here.
            guard self.recorder === recorder else { return }
            let url = recorder.url
            // The cap is reached only after `maxSeconds`; anything sooner was an interruption.
            let capped = Date().timeIntervalSince(self.startedAt) >= Self.maxSeconds - 1
            self.finish()
            self.onAutoStop?(url, capped)
        }
    }
}
