@preconcurrency import AVFoundation
import ScreenContextCore

/// The microphone, open only between `start()` and `stop()`, that is, while ⌃⌥T is held.
/// A fresh engine per hold, released at `stop()`, so the macOS microphone indicator goes off on release.
/// Audio stays in memory as 24 kHz mono Int16 until the hold ends; it is never logged.
final class MicRecorder: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available." }
    }

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var resampler: PCMResampler?
    private let limit = WAV.maxSeconds * WAV.sampleRate

    /// Opens the microphone. Call only once the microphone permission is granted: touching the
    /// input node before that would make macOS show its prompt.
    @MainActor
    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = PCMResampler(from: format) else { throw Failure.noInput }
        lock.withLock {
            samples = []
            samples.reserveCapacity(limit)
            self.resampler = resampler
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    /// Runs on the audio thread.
    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let resampler, samples.count < limit else { return }
            samples += resampler.convert(buffer).prefix(limit - samples.count)
        }
    }

    /// Closes the microphone and returns the hold's samples.
    @MainActor
    func stop() -> [Int16] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        return lock.withLock {
            if let resampler, samples.count < limit { samples += resampler.finish().prefix(limit - samples.count) }
            resampler = nil
            defer { samples = [] }
            return samples
        }
    }
}
