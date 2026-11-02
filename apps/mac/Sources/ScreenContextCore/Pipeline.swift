import Foundation

/// The on-device half of one capture: gate, capture one window, read it, redact it.
/// Nothing here touches the network or the disk.
public struct ScreenContextPipeline: Sendable {
    public let gate: CaptureGate
    public let capturer: any WindowCapturing
    public let reader: any TextReading
    public let redactor: Redactor

    public init(gate: CaptureGate = CaptureGate(), capturer: any WindowCapturing = ScreenCaptureKitWindowCapture(),
                reader: any TextReading = VisionTextReader(), redactor: Redactor = Redactor()) {
        self.gate = gate; self.capturer = capturer; self.reader = reader; self.redactor = redactor
    }

    public struct Result: Sendable {
        public let app: FrontApp
        public let redacted: RedactionResult
    }

    /// Refuses deny-listed apps and secure input before any pixels are captured.
    public func run(app: FrontApp, secureInput: Bool) async throws -> Result {
        if case .blocked(let name) = gate.check(app, secureInput: secureInput) { throw CaptureError.blocked(name) }
        let window = try await capturer.capture(app)
        let text = try reader.read(window.image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.nothingRead }
        return Result(app: app, redacted: redactor.redact(text))
    }
}
