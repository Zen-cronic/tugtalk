@preconcurrency import AVFoundation
import Foundation

/// Mono 16-bit PCM WAV: the body of `POST /v1/voice-rounds`.
public enum WAV {
    /// The rate the voice loop records at. The coach also accepts 16 kHz.
    public static let sampleRate = 24_000
    /// At most this much audio per hold.
    public static let maxSeconds = 60

    /// A canonical 44-byte RIFF header followed by little-endian samples.
    public static func encode(_ samples: [Int16], sampleRate: Int = WAV.sampleRate) -> Data {
        let dataBytes = samples.count * 2
        var data = Data(capacity: 44 + dataBytes)
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func le32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); le32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); le32(16)
        le16(1)                  // PCM
        le16(1)                  // mono
        le32(sampleRate)
        le32(sampleRate * 2)     // bytes per second
        le16(2)                  // bytes per frame
        le16(16)                 // bits per sample
        ascii("data"); le32(dataBytes)
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }

    public struct Header: Equatable, Sendable {
        public let format: Int
        public let channels: Int
        public let sampleRate: Int
        public let bitsPerSample: Int
        public let dataBytes: Int

        public var durationSeconds: Double {
            let frame = channels * bitsPerSample / 8
            return frame > 0 && sampleRate > 0 ? Double(dataBytes / frame) / Double(sampleRate) : 0
        }
    }

    /// Reads the `fmt ` and `data` chunks. Nil for anything that is not a RIFF/WAVE file.
    public static func header(of data: Data) -> Header? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF", String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var offset = 12
        var fmt: (Int, Int, Int, Int)?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt ", body + 16 <= bytes.count {
                fmt = (u16(body), u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data", let fmt {
                return Header(format: fmt.0, channels: fmt.1, sampleRate: fmt.2, bitsPerSample: fmt.3, dataBytes: min(size, bytes.count - body))
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}

/// Converts any PCM input (the microphone's hardware format, or a WAV file) to 24 kHz mono Int16.
/// Streaming: call `convert` per buffer, then `finish` once. Used from one thread at a time.
public final class PCMResampler: @unchecked Sendable {
    public static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(WAV.sampleRate), channels: 1, interleaved: true)!

    private let converter: AVAudioConverter
    private let ratio: Double

    public init?(from input: AVAudioFormat) {
        guard input.sampleRate > 0, input.channelCount > 0, let converter = AVAudioConverter(from: input, to: Self.outputFormat) else { return nil }
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
        ratio = Self.outputFormat.sampleRate / input.sampleRate
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] { run(buffer) }

    /// Flushes what the converter still holds. The resampler is spent afterwards.
    public func finish() -> [Int16] { run(nil) }

    private func run(_ input: AVAudioPCMBuffer?) -> [Int16] {
        let frames = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: frames) else { return [] }
        var collected: [Int16] = []
        let supplied = Flag()
        while true {
            var error: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input, !supplied.value { supplied.value = true; inputStatus.pointee = .haveData; return input }
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if let channel = output.int16ChannelData?[0], output.frameLength > 0 {
                collected.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            // A full output buffer may mean more is waiting; anything else means this input is used up.
            if status == .haveData && output.frameLength == output.frameCapacity { continue }
            return collected
        }
    }

    /// Reads a whole audio file and converts it, keeping at most `maxSeconds`.
    public static func convertFile(at url: URL, maxSeconds: Int = WAV.maxSeconds) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        guard let resampler = PCMResampler(from: file.processingFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let limit = maxSeconds * WAV.sampleRate
        var samples: [Int16] = []
        while file.framePosition < file.length && samples.count < limit {
            try file.read(into: buffer, frameCount: 8192)
            if buffer.frameLength == 0 { break }
            samples += resampler.convert(buffer)
        }
        samples += resampler.finish()
        return Array(samples.prefix(limit))
    }
}

/// The converter calls its input block synchronously, inside `convert`; this only satisfies the compiler.
private final class Flag: @unchecked Sendable { var value = false }

/// Where a hold's WAV waits until it is sent. One directory per hold, deleted once the round is
/// saved or abandoned, and swept at launch in case the app quit in between. Nothing else is kept.
public struct VoiceClipStore: Sendable {
    public static let prefix = "comms-coach-voice-"
    public let root: URL

    public init(root: URL = FileManager.default.temporaryDirectory) { self.root = root }

    public func url(for key: String) -> URL {
        root.appending(path: Self.prefix + Self.safe(key), directoryHint: .isDirectory).appending(path: "hold.wav")
    }

    public func exists(_ key: String) -> Bool { FileManager.default.fileExists(atPath: url(for: key).path) }

    @discardableResult
    public func write(_ wav: Data, for key: String) throws -> URL {
        let file = url(for: key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try wav.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    public func read(_ key: String) throws -> Data { try Data(contentsOf: url(for: key)) }

    public func remove(_ key: String) { try? FileManager.default.removeItem(at: url(for: key).deletingLastPathComponent()) }

    /// Deletes every hold directory left behind. Returns how many were removed.
    @discardableResult
    public func sweep() -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let stale = items.filter { $0.lastPathComponent.hasPrefix(Self.prefix) }
        stale.forEach { try? FileManager.default.removeItem(at: $0) }
        return stale.count
    }

    private static func safe(_ key: String) -> String {
        String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
    }
}
