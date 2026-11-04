import CoreText
import SwiftUI

/// Colour tokens for the dark watch face, shared with the landing page and the Mac companion.
/// Each metric has one token, used the same way on every screen: the chip fill, with ink text on it,
/// and a darker bottom edge. Red marks fillers only.
enum Palette {
    // Ground and text
    static let face = Color(hex: 0x000000)         // watch face
    static let rack = Color(hex: 0x23201C)         // graphite card
    static let ink = Color(hex: 0x171411)          // text on light fills
    static let muted = Color(hex: 0x4A4238)        // secondary text on light fills
    static let inkDark = Color(hex: 0xFFF7E8)      // text on the dark face; actions are filled with it
    static let mutedDark = Color(hex: 0xBDB2A2)    // secondary text on the dark face
    static let field = Color(hex: 0xF6B730)        // sunflower: choices on the setup screen

    static let worry = field                       // Tug's sweat drop on error screens, the one warm accent there

    // Metrics: fill (dark value) and shell edge
    static let filler = Color(hex: 0xFF7A66)
    static let fillerEdge = Color(hex: 0xE5412F)
    static let hedge = Color(hex: 0x7FB0FF)
    static let hedgeEdge = Color(hex: 0x2F6FE0)
    static let restart = Color(hex: 0x4FD6D1)
    static let restartEdge = Color(hex: 0x13918C)
    static let pace = inkDark                      // wpm is neutral ink, never a category colour

    // Tug
    static let tugBody = Color(hex: 0xA7AEB4)
    static let tugRim = Color(hex: 0xE9ECEE)
    static let tugInner = Color(hex: 0x5E656B)
    static let tugOutline = Color(hex: 0x171411)
    static let tugString = inkDark                 // one token: the string's colour changes here only

    // The recording light. Red is the universal recording signal: the one exception to "red means fillers".
    static let recordDot = Color(hex: 0xE5412F)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Anybody (display, width 104) for numbers and short headings; Hanken Grotesk for everything people read.
/// Both are bundled variable fonts (SIL OFL), set through their weight and width axes.
enum Typeface {
    private static let weightAxis = 0x77676874 // 'wght'
    private static let widthAxis = 0x77647468  // 'wdth'

    static func display(_ size: CGFloat, weight: CGFloat = 800) -> Font {
        make("Anybody-Thin", size: size, axes: [widthAxis: 104, weightAxis: weight])
    }

    static func text(_ size: CGFloat, weight: CGFloat = 600) -> Font {
        make("HankenGrotesk-Regular", size: size, axes: [weightAxis: weight])
    }

    /// Azeret Mono, for your own words quoted back (the transcript face, as on the Mac and the landing page).
    static func mono(_ size: CGFloat, weight: CGFloat = 500) -> Font {
        make("AzeretMonoRoman-Regular", size: size, axes: [weightAxis: weight])
    }

    private static func make(_ name: String, size: CGFloat, axes: [Int: CGFloat]) -> Font {
        let attributes: [CFString: Any] = [kCTFontNameAttribute: name, kCTFontVariationAttribute: axes]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
}

enum Face { case display, text, mono }

/// A bundled face that still follows the wearer's text size.
private struct ScaledFace: ViewModifier {
    let face: Face
    let weight: CGFloat
    @ScaledMetric private var size: CGFloat

    init(_ face: Face, size: CGFloat, weight: CGFloat, relativeTo style: Font.TextStyle) {
        self.face = face
        self.weight = weight
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
    }

    func body(content: Content) -> some View {
        switch face {
        case .display: content.font(Typeface.display(size, weight: weight))
        case .text: content.font(Typeface.text(size, weight: weight))
        case .mono: content.font(Typeface.mono(size, weight: weight))
        }
    }
}

extension View {
    func face(_ face: Face, _ size: CGFloat, weight: CGFloat? = nil, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledFace(face, size: size, weight: weight ?? (face == .display ? 800 : face == .mono ? 500 : 600), relativeTo: style))
    }

    /// Cards slot in like a cart into a deck: an 8 pt rise with a short settle. The overshoot is on position only.
    func slotIn() -> some View { modifier(SlotIn()) }
}

private struct SlotIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .offset(y: settled || reduceMotion ? 0 : 8)
            .opacity(settled || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(duration: 0.18, bounce: 0.4)) { settled = true }
            }
    }
}

/// Buttons, one system on every screen. The main action is solid sunflower with ink text, the only solid
/// button on a screen. Other actions are tinted: teal for a spoken practice round, blue for everything else
/// (back, change, more). Red is never a button colour: it marks fillers, and the live recording light.
struct CoachButtonStyle: ButtonStyle {
    enum Kind { case primary, practise, secondary }

    var kind: Kind = .primary
    var height: CGFloat = 44

    init(_ kind: Kind = .primary, height: CGFloat? = nil) {
        self.kind = kind
        self.height = height ?? (kind == .primary ? 44 : 40)
    }

    private var tint: Color {
        switch kind {
        case .primary: Palette.field
        case .practise: Palette.restart
        case .secondary: Palette.hedge
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        // The main action is solid with ink text; the others are a 30% fill of their colour, with text in that colour.
        let solid = kind == .primary
        return configuration.label
            .face(.text, solid ? 17 : 16, weight: 700, relativeTo: .headline)
            .foregroundStyle(solid ? Palette.ink : tint)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Capsule().fill(solid ? tint : tint.opacity(0.3)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A metric chip, drawn like a tape cartridge: a coloured shell with a darker bottom edge, ink text on it.
struct CartChip<Content: View>: View {
    let fill: Color
    let edge: Color
    var radius: CGFloat = 12
    var edgeHeight: CGFloat = 4
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(Palette.ink)
            .padding(.bottom, edgeHeight)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(edge)
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill).padding(.bottom, edgeHeight)
            }
    }
}
