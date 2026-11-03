// Renders the watch app icon (Assets.xcassets/AppIcon.appiconset/AppIcon.png): Tug on the sunflower
// field, ink outline and string, no text, as an opaque 1024 px PNG. Uses the can geometry from Tug.swift.
// Usage: swift apps/watch/Tools/render-icon.swift apps/watch/CommsCoachWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

let field = Color(hex: 0xF6B730)
let ink = Color(hex: 0x171411)
let tugBody = Color(hex: 0xA7AEB4)
let tugRim = Color(hex: 0xE9ECEE)
let tugInner = Color(hex: 0x5E656B)

struct Icon: View {
    var body: some View {
        Canvas { context, canvas in
            context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(field))
            // The can is drawn in its 64-unit space, scaled and placed slightly left of centre
            // so the string has room to run out to the right.
            let k: CGFloat = 11
            let ox: CGFloat = 512 - 32 * k - 40
            let oy: CGFloat = 512 - 37 * k + 10
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * k, y: oy + y * k) }
            func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: ox + (cx - rx) * k, y: oy + (cy - ry) * k, width: rx * 2 * k, height: ry * 2 * k))
            }

            // String: from the base of the can, one clean curve out to the right edge.
            var string = Path()
            string.move(to: p(40, 50))
            string.addCurve(to: CGPoint(x: 1060, y: 560), control1: p(56, 66), control2: CGPoint(x: 820, y: 520))
            context.stroke(string, with: .color(ink), style: StrokeStyle(lineWidth: 3.4 * k, lineCap: .round))

            let outline = StrokeStyle(lineWidth: 2.8 * k, lineJoin: .round)
            var body = Path()
            body.move(to: p(14, 18))
            body.addLine(to: p(14, 47))
            body.addQuadCurve(to: p(32, 56), control: p(14, 56))
            body.addQuadCurve(to: p(50, 47), control: p(50, 56))
            body.addLine(to: p(50, 18))
            body.closeSubpath()
            context.fill(body, with: .color(tugBody))
            context.stroke(body, with: .color(ink), style: outline)

            let rim = oval(32, 18, 18, 6.5)
            context.fill(rim, with: .color(tugRim))
            context.stroke(rim, with: .color(ink), style: outline)
            context.fill(oval(32, 18.5, 12, 3), with: .color(tugInner))

            context.fill(oval(25, 37, 3.6, 3.6), with: .color(ink))
            context.fill(oval(39, 37, 3.6, 3.6), with: .color(ink))
            var smile = Path()
            smile.move(to: p(27.5, 45)); smile.addQuadCurve(to: p(36.5, 45), control: p(32, 48.5))
            context.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 2.6 * k, lineCap: .round))
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render(to path: String) {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let src = renderer.cgImage else { fatalError("render failed") }
    // Flatten into an opaque RGB bitmap: App Store icons must not carry an alpha channel.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("context failed") }
    ctx.setFillColor(CGColor(red: 0xF6 / 255.0, green: 0xB7 / 255.0, blue: 0x30 / 255.0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let flat = ctx.makeImage()!
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, flat, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
}

MainActor.assumeIsolated { render(to: CommandLine.arguments[1]) }
