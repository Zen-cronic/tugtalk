import CoreGraphics
import Foundation
import Vision

/// One line of text Vision read, with where it sits in the image.
/// `box` is Vision's normalized rectangle: 0 to 1 on each axis, origin at the image's bottom left.
/// Lines stay on the Mac; only the joined, redacted text is ever sent.
public struct TextLine: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public init(text: String, box: CGRect) { self.text = text; self.box = box }
}

public protocol TextReading: Sendable {
    func read(_ image: CGImage) throws -> String
    /// The same reading, one line at a time with its box, in reading order.
    func readLines(_ image: CGImage) throws -> [TextLine]
}

extension TextReading {
    /// Readers without boxes (test doubles) report each line with an empty box, which is never pointed at.
    public func readLines(_ image: CGImage) throws -> [TextLine] {
        try read(image).split(separator: "\n").map { TextLine(text: String($0), box: .zero) }
    }
}

/// On-device OCR with Apple Vision. The image stays in memory; nothing is written to disk.
public struct VisionTextReader: TextReading {
    public var languages: [String]

    public init(languages: [String] = ["en-US", "fr-FR"]) { self.languages = languages }

    public func read(_ image: CGImage) throws -> String {
        try readLines(image).map(\.text).joined(separator: "\n")
    }

    public func readLines(_ image: CGImage) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> TextLine? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return TextLine(text: text, box: observation.boundingBox)
        }
        return Self.readingOrder(lines)
    }

    /// Top to bottom, then left to right. Vision's origin is bottom-left.
    static func readingOrder(_ lines: [TextLine]) -> [TextLine] {
        lines.sorted { a, b in
            let dy = a.box.midY - b.box.midY
            return abs(dy) > 0.01 ? dy > 0 : a.box.minX < b.box.minX
        }
    }
}

public enum ImageLoading {
    /// Loads a PNG or JPEG file into memory, for the CLI and tests.
    public static func cgImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.unreadableImage
        }
        return image
    }
}
