import CoreGraphics
import Foundation
import Vision

public protocol TextReading: Sendable {
    func read(_ image: CGImage) throws -> String
}

/// On-device OCR with Apple Vision. The image stays in memory; nothing is written to disk.
public struct VisionTextReader: TextReading {
    public var languages: [String]

    public init(languages: [String] = ["en-US", "fr-FR"]) { self.languages = languages }

    public func read(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        // Top to bottom, then left to right. Vision's origin is bottom-left.
        let lines = observations.sorted { a, b in
            let dy = a.boundingBox.midY - b.boundingBox.midY
            return abs(dy) > 0.01 ? dy > 0 : a.boundingBox.minX < b.boundingBox.minX
        }.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
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
