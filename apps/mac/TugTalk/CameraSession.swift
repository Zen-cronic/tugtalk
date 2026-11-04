@preconcurrency import AVFoundation
import AppKit
import Combine
import OSLog
import QuartzCore
import ScreenContextCore

/// Records when the camera opened and closed, frame counts and timings. Never a frame, an angle per frame or a key.
let cameraLog = Logger(subsystem: "com.kaungzinhein.commscoach.mac", category: "camera")

/// "Use the Camera During Practice". Off until the person turns it on and macOS grants the camera.
@MainActor
enum CameraSettings {
    private static let key = "useCamera"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The menu toggle. Turning it on shows the explainer first; the macOS prompt appears only after Continue.
    static func menuToggled() {
        if enabled {
            enabled = false
            cameraLog.notice("camera for practice turned off")
            return
        }
        CameraExplainer.show(denied: CameraPermission.status == .denied)
    }
}

/// Camera permission. Never asked for on its own: only after Continue on the explainer, and macOS itself asks once.
@MainActor
enum CameraPermission {
    enum Status { case granted, undetermined, denied }

    static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    static func request(_ done: @escaping @MainActor (Bool) -> Void) {
        guard status == .undetermined else { done(status == .granted); return }
        // @Sendable keeps this closure off the main actor: macOS calls it on a background queue.
        AVCaptureDevice.requestAccess(for: .video) { @Sendable granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(granted) } }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The camera during one hold of ⌃⌥T: opened at key-down, closed at release (the camera light goes off), and
/// in between about 10 frames a second go through Apple Vision for head angles. The frames are dropped as soon as
/// they are read. What is left is the list of angles in memory, turned into four numbers at release.
@MainActor
final class CameraSession: ObservableObject {
    static let shared = CameraSession()

    /// Whether the head faces the camera right now, for Tug's eyes and the dot under the camera. Nil while closed.
    struct Look: Equatable {
        var facing: Bool
        var since: Date
    }

    @Published private(set) var look: Look?

    private var reader: FrameReader?
    private var key: String?
    private var startedAt: CFTimeInterval = 0
    /// The numbers of the last few holds, by idempotency key, so a Retry sends the same ones.
    private var results: [(key: String, metrics: CameraMetrics)] = []
    private var safety: Task<Void, Never>?
    private var generation = 0
    #if DEBUG
    /// `-cameraFixture <poses.json>`: these head angles stand in for the camera, so no permission is needed.
    private let fixture: [HeadPoseSample]? = UserDefaults.standard.string(forKey: "cameraFixture").flatMap {
        try? JSONDecoder().decode([HeadPoseSample].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
    }
    private var fixtureTask: Task<Void, Never>?
    #endif

    private init() {
        #if DEBUG
        CameraPreview.runLaunchPreview(self)
        #endif
    }

    /// Key-down. Opens the camera only when the person turned it on, macOS granted it, and nothing is being presented.
    func start(key: String, allowed: Bool) {
        if reader != nil { close() }
        guard allowed else { return }
        #if DEBUG
        if let fixture {
            begin(key, reader: FrameReader(onLive: liveHandler()))
            playFixture(fixture)
            cameraLog.notice("hold started with the pose fixture (\(fixture.count, privacy: .public) frames); camera not used")
            return
        }
        #endif
        guard CameraSettings.enabled else { return }
        guard CameraPermission.status == .granted else {
            cameraLog.notice("camera for practice is on but not granted; this hold has no camera numbers")
            return
        }
        guard let device = AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video) else {
            cameraLog.error("no camera found; this hold has no camera numbers")
            return
        }
        let reader = FrameReader(onLive: liveHandler())
        reader.clipSink = ReplayCheck.shared.sink(forHold: key) // the hands check, only when it is on for this round
        begin(key, reader: reader)
        reader.open(device)
        cameraLog.notice("camera opened (\(device.deviceType == .continuityCamera ? "Continuity Camera" : "built-in or external", privacy: .public))")
    }

    /// Release: the camera closes at once, and the hold's numbers are ready before the clip is sent.
    func stop() {
        guard let reader, let key else { return }
        let end = CACurrentMediaTime() - startedAt
        let read = reader.finish()
        close()
        guard let metrics = CameraMeter.measure(read.samples, end: end) else {
            cameraLog.notice("camera closed; \(read.samples.count, privacy: .public) frames is too few to measure")
            return
        }
        results.removeAll { $0.key == key }
        results.append((key, metrics))
        if results.count > 4 { results.removeFirst(results.count - 4) }
        cameraLog.notice("camera closed after \(String(format: "%.1f", end), privacy: .public) s: \(metrics.frames, privacy: .public) frames, Vision \(String(format: "%.1f", read.visionMs), privacy: .public) ms per frame")
    }

    /// A hold that will not be sent, or a round that is done: close the camera if it is this hold's, and forget its numbers.
    func cancel(key: String) {
        if self.key == key, let reader {
            _ = reader.finish()
            close()
            cameraLog.notice("camera closed; hold not sent")
        }
        results.removeAll { $0.key == key }
    }

    func metrics(for key: String) -> CameraMetrics? { results.last { $0.key == key }?.metrics }

    var isOpen: Bool { reader != nil }

    private func begin(_ key: String, reader: FrameReader) {
        generation += 1
        self.reader = reader
        self.key = key
        startedAt = CACurrentMediaTime()
        reader.startedAt = startedAt
        // A hold is at most 60 s; the camera never outlives one, even if a release went missing.
        safety?.cancel()
        let id = generation
        safety = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(WAV.maxSeconds) + 3))
            guard !Task.isCancelled, let self, self.generation == id, self.reader != nil else { return }
            cameraLog.error("camera still open after the longest hold; closing it")
            self.stop()
        }
    }

    private func close() {
        reader = nil
        key = nil
        look = nil
        safety?.cancel()
        generation += 1
        #if DEBUG
        fixtureTask?.cancel()
        #endif
    }

    /// Frames arrive on the camera's queue; the facing bit hops to the main actor, and only for the current hold.
    private func liveHandler() -> @Sendable (Bool) -> Void {
        let id = generation + 1
        return { facing in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let session = CameraSession.shared
                    guard session.generation == id, session.reader != nil else { return }
                    session.look = Look(facing: facing, since: Date())
                }
            }
        }
    }

    #if DEBUG
    private func playFixture(_ samples: [HeadPoseSample]) {
        guard let reader else { return }
        fixtureTask = Task { [reader] in
            let start = Date()
            for sample in samples.sorted(by: { $0.t < $1.t }) {
                let wait = sample.t - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { return }
                reader.feed(sample)
            }
        }
    }

    /// For DEBUG previews only: shows a facing state with no camera and no hold.
    func preview(facing: Bool?) {
        look = facing.map { Look(facing: $0, since: Date()) }
    }
    #endif
}

/// Reads frames on its own queue. Holds only head angles, never a frame. Thread-safe through its lock.
final class FrameReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kaungzinhein.commscoach.camera", qos: .userInitiated)
    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var samples: [HeadPoseSample] = []
    private var live = LiveFacing()
    private var nextFrameAt: CFTimeInterval = 0
    private var visionSeconds = 0.0
    private var accepting = true
    private let onLive: @Sendable (Bool) -> Void
    /// The hold's start, in `CACurrentMediaTime`.
    var startedAt: CFTimeInterval {
        get { lock.withLock { _startedAt } }
        set { lock.withLock { _startedAt = newValue } }
    }
    private var _startedAt: CFTimeInterval = 0

    /// The round's hands-check clip (ReplayCheck), set only when the person turned the check on for this round:
    /// each frame read is also scaled into that clip before it is dropped. Without it, only head angles are held.
    var clipSink: ReplayClipWriter? {
        get { lock.withLock { _clipSink } }
        set { lock.withLock { _clipSink = newValue } }
    }
    private var _clipSink: ReplayClipWriter?

    init(onLive: @escaping @Sendable (Bool) -> Void) { self.onLive = onLive }

    /// Starts the camera on the reader's queue (starting takes a moment, and must not hold up the key press).
    func open(_ device: AVCaptureDevice) {
        queue.async { [self] in
            guard lock.withLock({ accepting }) else { return }
            let session = AVCaptureSession()
            session.beginConfiguration()
            for preset in [AVCaptureSession.Preset.vga640x480, .medium, .low] where session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                break
            }
            guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                cameraLog.error("the camera could not be opened")
                return
            }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { cameraLog.error("the camera gave no video output"); return }
            session.addOutput(output)
            session.commitConfiguration()
            // A release that came while the camera was starting closes it straight away.
            guard lock.withLock({ accepting }) else { return }
            session.startRunning()
            lock.withLock { self.session = session }
            if !lock.withLock({ accepting }) { session.stopRunning() }
        }
    }

    /// Stops taking frames and returns what was read. The camera itself stops on the reader's queue, right after.
    func finish() -> (samples: [HeadPoseSample], visionMs: Double) {
        let result = lock.withLock { () -> ([HeadPoseSample], Double) in
            accepting = false
            let ms = samples.isEmpty ? 0 : 1000 * visionSeconds / Double(samples.count)
            defer { samples = [] }
            return (samples, ms)
        }
        queue.async { [self] in
            let session = lock.withLock { () -> AVCaptureSession? in defer { self.session = nil }; return self.session }
            session?.stopRunning()
        }
        return result
    }

    /// One analysed frame (from the camera, or from the DEBUG fixture).
    func feed(_ sample: HeadPoseSample) {
        let changed: Bool? = lock.withLock {
            guard accepting else { return nil }
            samples.append(sample)
            return live.push(sample) ? live.facing : nil
        }
        if let facing = changed { onLive(facing) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        let due = lock.withLock { () -> Bool in
            guard accepting, now >= nextFrameAt else { return false }
            nextFrameAt = now + CameraMeter.frameInterval
            return true
        }
        guard due, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let angles = HeadPoseReader.angles(in: pixels)
        let took = CACurrentMediaTime() - now
        lock.withLock { visionSeconds += took }
        clipSink?.append(pixels)
        feed(HeadPoseSample(t: now - startedAt, yaw: angles.yaw, pitch: angles.pitch))
    }
}
