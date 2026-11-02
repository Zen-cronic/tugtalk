import AudioToolbox
import Foundation

/// Splits an MP3 or WAV byte stream into audio packets as the bytes arrive, at any chunk boundary
/// (Core Audio's AudioFileStream). Reports the format once, then each run of packets.
public final class AudioStreamParser: @unchecked Sendable {
    public struct Packets {
        public let data: Data
        /// Empty for constant-size packets (PCM).
        public let descriptions: [AudioStreamPacketDescription]
    }

    public private(set) var format: AudioStreamBasicDescription?
    public private(set) var magicCookie: Data?
    public var onFormat: (AudioStreamBasicDescription, Data?) -> Void = { _, _ in }
    public var onPackets: (Packets) -> Void = { _ in }
    private var stream: AudioFileStreamID?

    /// `contentType` is the HTTP type ("audio/mpeg", "audio/wav"); it is only a hint.
    public init?(contentType: String) {
        let hint: AudioFileTypeID = contentType.contains("wav") ? kAudioFileWAVEType : kAudioFileMP3Type
        let status = AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), { client, stream, property, _ in
            Unmanaged<AudioStreamParser>.fromOpaque(client).takeUnretainedValue().property(stream, property)
        }, { client, bytes, count, data, descriptions in
            Unmanaged<AudioStreamParser>.fromOpaque(client).takeUnretainedValue().packets(bytes: bytes, count: count, data: data, descriptions: descriptions)
        }, hint, &stream)
        guard status == noErr else { return nil }
    }

    deinit { if let stream { AudioFileStreamClose(stream) } }

    /// False when the bytes are not audio Core Audio can read.
    @discardableResult
    public func parse(_ data: Data) -> Bool {
        guard let stream, !data.isEmpty else { return true }
        let status = data.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(stream, UInt32(raw.count), raw.baseAddress, [])
        }
        return status == noErr
    }

    private func property(_ stream: AudioFileStreamID, _ property: AudioFileStreamPropertyID) {
        guard property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &description) == noErr else { return }
        var cookieSize: UInt32 = 0
        var cookie: Data?
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0 {
            var bytes = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &bytes) == noErr { cookie = Data(bytes) }
        }
        format = description
        magicCookie = cookie
        onFormat(description, cookie)
    }

    private func packets(bytes: UInt32, count: UInt32, data: UnsafeRawPointer, descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        let copy = Data(bytes: data, count: Int(bytes))
        let list = descriptions.map { Array(UnsafeBufferPointer(start: $0, count: Int(count))) } ?? []
        onPackets(Packets(data: copy, descriptions: list))
    }
}

/// Plays an MP3 or WAV stream while it downloads: each run of packets is queued on an AudioQueue as it is parsed,
/// and playback starts once `prebuffer` seconds are queued (or the stream ends). Events, on the main queue:
/// `started` once sound begins, then exactly one of `finished` (the last packet played) or `failed`. Nothing after `stop()`.
public final class StreamingAudioPlayer: @unchecked Sendable {
    public enum Event: Equatable, Sendable { case started, finished, failed(String) }

    private let lock = NSLock()
    private let parser: AudioStreamParser
    private let onEvent: @Sendable (Event) -> Void
    private let prebuffer: Double
    private let volume: Float
    private var queue: AudioQueueRef?
    private var queuedSeconds = 0.0
    private var running = false
    private var ended = false
    private var stopped = false
    private var reported = false
    private var packetCount = 0
    private let work = DispatchQueue(label: "streaming-audio")

    public init?(contentType: String, volume: Float = 1, prebuffer: Double = 0.2, onEvent: @escaping @Sendable (Event) -> Void) {
        guard let parser = AudioStreamParser(contentType: contentType) else { return nil }
        self.parser = parser; self.volume = volume; self.prebuffer = prebuffer; self.onEvent = onEvent
        parser.onFormat = { [unowned self] format, cookie in self.makeQueue(format, cookie: cookie) }
        parser.onPackets = { [unowned self] packets in self.enqueue(packets) }
    }

    /// Bytes as they arrive, in order.
    public func append(_ data: Data) {
        work.async { [self] in
            guard !isStopped else { return }
            if !parser.parse(data) { fail("the audio could not be read") }
        }
    }

    /// No more bytes: what is queued plays to the end, then `finished`.
    public func finish() {
        work.async { [self] in
            guard !isStopped else { return }
            lock.withLock { ended = true }
            guard let queue, packetCount > 0 else { fail("no audio arrived"); return }
            AudioQueueFlush(queue)
            if !lock.withLock({ running }) { start() }
            AudioQueueStop(queue, false)
        }
    }

    /// Silences at once (barge-in). No event follows.
    public func stop() {
        let q: AudioQueueRef? = lock.withLock {
            stopped = true
            defer { queue = nil }
            return queue
        }
        if let q {
            AudioQueueStop(q, true)
            AudioQueueDispose(q, true)
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func makeQueue(_ format: AudioStreamBasicDescription, cookie: Data?) {
        var description = format
        var created: AudioQueueRef?
        let client = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewOutput(&description, { _, queue, buffer in
            AudioQueueFreeBuffer(queue, buffer)
        }, client, nil, nil, 0, &created)
        guard status == noErr, let created else { fail("the audio format is not supported"); return }
        if let cookie {
            _ = cookie.withUnsafeBytes { AudioQueueSetProperty(created, kAudioQueueProperty_MagicCookie, $0.baseAddress!, UInt32($0.count)) }
        }
        AudioQueueSetParameter(created, kAudioQueueParam_Volume, volume)
        AudioQueueAddPropertyListener(created, kAudioQueueProperty_IsRunning, { client, queue, _ in
            Unmanaged<StreamingAudioPlayer>.fromOpaque(client!).takeUnretainedValue().runningChanged(queue)
        }, client)
        lock.withLock { queue = created }
    }

    private func enqueue(_ packets: AudioStreamParser.Packets) {
        guard let queue = lock.withLock({ queue }), let format = parser.format, !packets.data.isEmpty else { return }
        var buffer: AudioQueueBufferRef?
        let allocated = packets.descriptions.isEmpty
            ? AudioQueueAllocateBuffer(queue, UInt32(packets.data.count), &buffer)
            : AudioQueueAllocateBufferWithPacketDescriptions(queue, UInt32(packets.data.count), UInt32(packets.descriptions.count), &buffer)
        guard allocated == noErr, let buffer else {
            fail("the audio could not be queued"); return
        }
        packets.data.withUnsafeBytes { raw in buffer.pointee.mAudioData.copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
        buffer.pointee.mAudioDataByteSize = UInt32(packets.data.count)
        var count = packets.descriptions.count
        if count > 0 {
            for (i, d) in packets.descriptions.enumerated() { buffer.pointee.mPacketDescriptions![i] = d }
            buffer.pointee.mPacketDescriptionCount = UInt32(count)
        } else if format.mBytesPerPacket > 0 {
            count = packets.data.count / Int(format.mBytesPerPacket)
        }
        guard AudioQueueEnqueueBuffer(queue, buffer, 0, nil) == noErr else { fail("the audio could not be queued"); return }
        packetCount += count
        let frames = format.mFramesPerPacket > 0 ? Double(format.mFramesPerPacket) : 1
        queuedSeconds += Double(count) * frames / max(format.mSampleRate, 1)
        if !lock.withLock({ running }) && queuedSeconds >= prebuffer { start() }
    }

    private func start() {
        guard let queue = lock.withLock({ queue }) else { return }
        guard AudioQueueStart(queue, nil) == noErr else { fail("the audio output could not start"); return }
        lock.withLock { running = true }
        report(.started, final: false)
    }

    private func runningChanged(_ queue: AudioQueueRef) {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &value, &size)
        // Stopped after the last buffer played (finish() asked for a deferred stop).
        if value == 0, lock.withLock({ ended && !stopped }) {
            report(.finished, final: true)
            work.async { [self] in
                let q: AudioQueueRef? = lock.withLock { defer { self.queue = nil }; return self.queue }
                if let q { AudioQueueDispose(q, true) }
            }
        }
    }

    private func fail(_ reason: String) {
        stop()
        lock.withLock { stopped = false }  // let the failure itself be reported
        report(.failed(reason), final: true)
        lock.withLock { stopped = true }
    }

    private func report(_ event: Event, final: Bool) {
        let send: Bool = lock.withLock {
            if stopped || reported { return false }
            if final { reported = true }
            return true
        }
        guard send else { return }
        DispatchQueue.main.async { [onEvent] in onEvent(event) }
    }
}
