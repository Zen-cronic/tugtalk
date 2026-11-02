import AppKit
import Foundation
import ScreenContextCore

/// The companion's display name. The character is unnamed for now; renaming it is this one line.
let MascotName = "Coach"

/// Fixed palette, shared with the launch film and the site. Each hue keeps one meaning.
enum Palette {
    static let measured = NSColor(srgbRed: 0xC8 / 255, green: 0xF5 / 255, blue: 0x60 / 255, alpha: 1)  // lime: measured by code
    static let model = NSColor(srgbRed: 0xB9 / 255, green: 0xA6 / 255, blue: 0xFF / 255, alpha: 1)     // lavender: Muse Spark Open
    static let record = NSColor(srgbRed: 0x7C / 255, green: 0xC4 / 255, blue: 0xFF / 255, alpha: 1)    // sky: the shared record
    static let capture = NSColor(srgbRed: 0xE5 / 255, green: 0x38 / 255, blue: 0x3B / 255, alpha: 1)   // red: reading a window
    static let warn = NSColor(srgbRed: 0xFF / 255, green: 0xB8 / 255, blue: 0x6B / 255, alpha: 1)
    static let cream = NSColor(srgbRed: 0xF2 / 255, green: 0xED / 255, blue: 0xE4 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0x16 / 255, green: 0x18 / 255, blue: 0x1C / 255, alpha: 1)
    static let offline = NSColor(srgbRed: 0xA3 / 255, green: 0xA9 / 255, blue: 0xB3 / 255, alpha: 1)
}

/// User-adjustable settings, stored in UserDefaults. The connector key is never stored here (see Keychain).
enum Settings {
    static let keychainService = "com.zencronic.commscoach.mac"
    static let keychainAccount = "connector"

    /// Bundle ids of meeting apps; while one is frontmost the companion hides itself.
    static let meetingApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
                                           "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"]

    private static var defaults: UserDefaults { .standard }

    static var baseURL: URL {
        get { defaults.string(forKey: "baseURL").flatMap(URL.init(string:)) ?? CoachAPI.defaultBaseURL }
        set { defaults.set(newValue.absoluteString, forKey: "baseURL") }
    }

    static var goalID: String? {
        get { defaults.string(forKey: "goalID") }
        set { defaults.set(newValue, forKey: "goalID") }
    }

    static var purpose: ScreenContextPayload.Purpose {
        get { defaults.string(forKey: "purpose").flatMap(ScreenContextPayload.Purpose.init(rawValue:)) ?? .meeting_prep }
        set { defaults.set(newValue.rawValue, forKey: "purpose") }
    }

    /// The language the coach hears and replies in, sent as `X-Language`. `-voiceLanguage fr` also works.
    static var voiceLanguage: VoiceLanguage {
        get { defaults.string(forKey: "voiceLanguage").flatMap(VoiceLanguage.init(rawValue:)) ?? .en }
        set { defaults.set(newValue.rawValue, forKey: "voiceLanguage") }
    }

    static var denyList: Set<String> {
        get { (defaults.stringArray(forKey: "denyList")).map(Set.init) ?? CaptureGate.defaultDenyList }
        set { defaults.set(Array(newValue).sorted(), forKey: "denyList") }
    }

    static var autoHideInMeetings: Bool {
        get { defaults.object(forKey: "autoHideInMeetings") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoHideInMeetings") }
    }

    /// The mascot's centre on a display, keyed by that display's id.
    static func position(for screen: NSScreen) -> CGPoint? {
        guard let raw = defaults.dictionary(forKey: "positions")?[screen.idKey] as? [Double], raw.count == 2 else { return nil }
        return CGPoint(x: raw[0], y: raw[1])
    }

    static func setPosition(_ point: CGPoint, for screen: NSScreen) {
        var all = defaults.dictionary(forKey: "positions") ?? [:]
        all[screen.idKey] = [Double(point.x), Double(point.y)]
        defaults.set(all, forKey: "positions")
    }
}

extension NSScreen {
    var idKey: String {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? localizedName
    }
}
