import AppKit
import CoreText
import SwiftUI

/// The Cart wall palette: a sunflower field, white label cards, ink actions, a graphite rack band, and
/// one tint per measured habit. Every colour on the companion comes from here, each with one meaning.
enum Tok {
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    private static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
        let l = hex(light), d = hex(dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l }
    }

    // Grounds and text
    /// Sunflower: the header band of every card and the ring's fill.
    static let field = hex(0xF6B730)
    /// The label card: white in light, the HUD graphite in dark.
    static let surface = pair(0xFFFFFF, 0x23201C)
    /// The white label in both looks: the pointing label drawn over someone's window.
    static let labelWhite = hex(0xFFFFFF)
    static let ink = pair(0x171411, 0xFFF7E8)
    static let muted = pair(0x4A4238, 0xBDB2A2)
    static let rule = pair(0xE8DDC6, 0x4A4238)
    /// The edge of a card or label: ink on light, a warm hairline on the dark HUD.
    static let cardEdge = pair(0x171411, 0x4A4238)
    /// Ink that stays dark in both looks: text on sunflower, and the shell lip under cards.
    static let inkFixed = hex(0x171411)
    /// The graphite rack band: the header of a card that reports a problem.
    static let graphite = hex(0x23201C)
    /// The problem header: graphite on light; one step darker on the dark HUD, so it still reads as a band.
    static let problemBand = pair(0x23201C, 0x171411)
    static let onGraphite = hex(0xFFF7E8)
    static let mutedOnGraphite = hex(0xBDB2A2)
    static let action = pair(0x171411, 0xFFF7E8)
    static let onAction = pair(0xFFFFFF, 0x171411)
    /// Focus rings only.
    static let focus = hex(0x1E5FD8)

    // One token per metric. Fillers are the only red on the companion.
    static let filler = pair(0xFF9F8F, 0xFF7A66)
    static let hedge = pair(0x9FC3FF, 0x7FB0FF)
    static let restart = pair(0x8FDCD9, 0x4FD6D1)
    static let fillerEdge = hex(0xE5412F)
    static let hedgeEdge = hex(0x2F6FE0)
    static let restartEdge = hex(0x13918C)
    /// Pace is deliberate neutral ink, not a disabled grey.
    static let wpm = ink

    // Tug
    static let metal = hex(0xA7AEB4)
    static let metalLight = hex(0xE9ECEE)
    static let metalDark = hex(0x5E656B)
    static let metalOutline = hex(0x171411)
    /// Tug's string, in one place: ink on light, cream on the dark HUD.
    static let tugString = pair(0x171411, 0xFFF7E8)
    static func tugString(_ scheme: ColorScheme) -> Color { Color(nsColor: scheme == .dark ? hex(0xFFF7E8) : hex(0x171411)) }
}

extension Color {
    init(_ token: NSColor) { self.init(nsColor: token) }
}

/// The brief's three faces, bundled (SIL Open Font License; see THIRD_PARTY_NOTICES.md):
/// Anybody at width 104 for short headings, Hanken Grotesk for coach and body text, Azeret Mono for
/// transcripts and timers, with ligatures off.
enum TypeFace {
    private static let files = ["Anybody-Variable", "HankenGrotesk-Variable", "AzeretMono-Variable"]
    nonisolated(unsafe) private static var registered = false
    private static let wdth = 0x77647468, wght = 0x77676874

    /// Registers the bundled faces for this process. Falls back to the system face if a file is missing.
    static func register() {
        guard !registered else { return }
        registered = true
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func font(_ postScript: String, family: String, size: CGFloat, axes: [Int: CGFloat], features: [[CFString: Any]] = []) -> Font {
        register()
        var attributes: [CFString: Any] = [kCTFontNameAttribute: postScript, kCTFontVariationAttribute: axes as CFDictionary]
        if !features.isEmpty { attributes[kCTFontFeatureSettingsAttribute] = features }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let ctFont = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        // A missing face resolves to a substitute; use the system face then, so the fallback is explicit.
        guard (CTFontCopyFamilyName(ctFont) as String) == family else { return .system(size: size) }
        return Font(ctFont)
    }

    /// Short headings only (six words or fewer).
    static func display(_ size: CGFloat, weight: CGFloat = 800) -> Font {
        font("Anybody-Thin", family: "Anybody", size: size, axes: [wdth: 104, wght: weight])
    }

    /// Coach and body text: about 15/22 semibold for what Tug says, regular for supporting lines.
    static func body(_ size: CGFloat = 15, weight: CGFloat = 600) -> Font {
        font("HankenGrotesk-Regular", family: "Hanken Grotesk", size: size, axes: [wght: weight])
    }

    /// Transcripts, timers and receipts. Ligatures off, tabular figures.
    static func mono(_ size: CGFloat = 12, weight: CGFloat = 500) -> Font {
        font("AzeretMonoRoman-Regular", family: "Azeret Mono", size: size, axes: [wght: weight], features: [
            [kCTFontOpenTypeFeatureTag: "liga", kCTFontOpenTypeFeatureValue: 0],
            [kCTFontOpenTypeFeatureTag: "calt", kCTFontOpenTypeFeatureValue: 0],
            [kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1],
        ])
    }
}

/// Motion from the brief. Cards slot in like a cart into a deck: an 8 pt rise with a short settle,
/// 180 ms, overshoot on position only and never on scale. Reduce Motion swaps each for a crossfade.
enum Motion {
    static let slotRise: CGFloat = 8
    static let slot = Animation.spring(duration: 0.18, bounce: 0.35)
    static let fade = Animation.easeOut(duration: 0.15)
    static let crossfade = Animation.easeInOut(duration: 0.2)

    static func cardTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(crossfade) }
        return .asymmetric(insertion: .modifier(active: SlotIn(rise: slotRise, shown: false), identity: SlotIn(rise: slotRise, shown: true)).animation(slot),
                           removal: .opacity.animation(fade))
    }
}

/// Position and opacity only. No scale.
private struct SlotIn: ViewModifier {
    let rise: CGFloat
    let shown: Bool
    func body(content: Content) -> some View {
        content.offset(y: shown ? 0 : rise).opacity(shown ? 1 : 0)
    }
}
