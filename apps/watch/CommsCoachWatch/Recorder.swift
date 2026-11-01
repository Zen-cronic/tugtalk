import AVFoundation
import Foundation

/// Tap-to-capture recorder. Writes mono 16-bit PCM WAV at 16 kHz, the format the
/// backend accepts as-is. Recording continues wrist-down only because the user
/// started it in the foreground; there is no background or always-on capture.
@MainActor
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let maxSeconds: TimeInterval = 170 // backend limit is 180 s

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var startedAt = Date()

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio)
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.record(forDuration: Self.maxSeconds) else { throw CoachError.server(0, "Recording could not start") }
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
        guard let recorder else { return }
        elapsed = recorder.currentTime
    }

    /// Stops and returns the finished file, or nil if nothing was recording.
    func stop() -> URL? {
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        finish()
        return url
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in if self.recorder === recorder { self.finish() } }
    }
}
