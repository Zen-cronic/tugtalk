import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Reads head angles from one camera frame with Apple Vision, on this Mac. The live camera and the offline
/// clip check (`camera-eval poses`) both call this, so they classify frames the same way. Nothing is kept.
public enum HeadPoseReader {
    /// The largest face's yaw and pitch, in degrees, or nils when Vision found no face.
    public static func angles(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> (yaw: Double?, pitch: Double?) {
        perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]))
    }

    public static func angles(in image: CGImage) -> (yaw: Double?, pitch: Double?) {
        perform(VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]))
    }

    private static func perform(_ handler: VNImageRequestHandler) -> (yaw: Double?, pitch: Double?) {
        let request = VNDetectFaceRectanglesRequest()
        // Revision 3 (macOS 12+) reports continuous yaw and pitch; earlier ones round yaw to 45° steps and have no pitch.
        request.revision = VNDetectFaceRectanglesRequestRevision3
        do { try handler.perform([request]) } catch { return (nil, nil) }
        let faces = request.results ?? []
        guard let face = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
            return (nil, nil)
        }
        let degrees = { (n: NSNumber?) in n.map { $0.doubleValue * 180 / .pi } }
        return (degrees(face.yaw), degrees(face.pitch))
    }
}
