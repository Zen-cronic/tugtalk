#if DEBUG
import AppKit
import SwiftUI

/// DEBUG: the small Tug at 16, 24 and 48 pt on sunflower, on the dark HUD and on white, next to the
/// full drawing, for checking the small sizes by eye.
@MainActor
enum GlyphSheet {
    private static var window: NSWindow?

    static func show() {
        let view = NSHostingView(rootView: GlyphSheetView())
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(x: 120, y: 200, width: size.width, height: size.height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tug small sizes"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
    }
}

private struct GlyphSheetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(Tok.field, ink: Tok.inkFixed, name: "Sunflower")
            row(Tok.graphite, ink: Tok.onGraphite, name: "Dark HUD")
            row(NSColor.white, ink: Tok.inkFixed, name: "White")
            menuBar(dark: true)
            menuBar(dark: false)
        }
        .fixedSize()
    }

    /// The 18 pt template image as the menu bar tints it: white on a dark bar, black on a light one.
    private func menuBar(dark: Bool) -> some View {
        HStack(spacing: 22) {
            Text(dark ? "Menu bar, dark" : "Menu bar, light").font(TypeFace.body(13, weight: 600)).frame(width: 110, alignment: .leading)
            Image(nsImage: TugGlyph.image(size: 18, color: dark ? .white : .black)).frame(width: 18, height: 18)
            Spacer()
        }
        .foregroundStyle(dark ? Color.white : Color.black)
        .padding(.horizontal, 16).frame(height: 30)
        .background(dark ? Color.black : Color.white)
    }

    private func row(_ ground: NSColor, ink: NSColor, name: String) -> some View {
        HStack(alignment: .center, spacing: 22) {
            Text(name).font(TypeFace.body(13, weight: 600)).frame(width: 80, alignment: .leading)
            ForEach([16.0, 24.0, 48.0], id: \.self) { size in
                Image(nsImage: TugGlyph.image(size: size, color: ink)).frame(width: size, height: size)
            }
            TugCanvas(pose: TugPose(phase: .idle, t: 0, talking: false, animated: false)).frame(width: 64, height: 64)
                .environment(\.colorScheme, ground == Tok.graphite ? .dark : .light)
        }
        .foregroundStyle(Color(ink))
        .padding(16)
        .background(Color(ground))
    }
}
#endif
