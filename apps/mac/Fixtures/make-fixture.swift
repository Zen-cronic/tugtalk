// Renders Fixtures/meeting-prep.txt into Fixtures/meeting-prep.png, a synthetic window-like
// image with planted personal data for the OCR and redaction tests. Everything in it is made up.
// Run from apps/mac: swift Fixtures/make-fixture.swift
import AppKit

let text = try String(contentsOfFile: "Fixtures/meeting-prep.txt", encoding: .utf8)
let size = NSSize(width: 1200, height: 860)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
// A plain title bar, so the image reads as one app window.
NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
NSRect(x: 0, y: size.height - 44, width: size.width, height: 44).fill()
for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 18 + i * 22, y: Int(size.height) - 30, width: 14, height: 14)).fill()
}
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: size.width, height: size.height - 44).fill()
let style = NSMutableParagraphStyle(); style.lineSpacing = 6
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black, .paragraphStyle: style]
NSAttributedString(string: text, attributes: attributes).draw(in: NSRect(x: 48, y: 24, width: size.width - 96, height: size.height - 92))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Fixtures/meeting-prep.png"))
print("Wrote Fixtures/meeting-prep.png")
