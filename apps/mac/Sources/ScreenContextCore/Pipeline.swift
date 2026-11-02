import CoreGraphics
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
        /// The unredacted lines with their boxes, for pointing at one of them on this Mac. Never sent.
        public let lines: [TextLine]
        /// The captured window's frame and number, when known (see `CapturedWindow`).
        public let frame: CGRect?
        public let windowID: CGWindowID?
    }

    /// Refuses the companion itself, deny-listed apps and secure input before any pixels are captured.
    public func run(app: FrontApp, secureInput: Bool) async throws -> Result {
        switch gate.check(app, secureInput: secureInput) {
        case .ownWindow: throw CaptureError.ownWindow
        case .blocked(let name): throw CaptureError.blocked(name)
        case .allowed: break
        }
        let window = try await capturer.capture(app)
        let lines = try reader.readLines(window.image)
        let text = lines.map(\.text).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.nothingRead }
        return Result(app: app, redacted: redactor.redact(text), lines: lines, frame: window.frame, windowID: window.windowID)
    }
}
