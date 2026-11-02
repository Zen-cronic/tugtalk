import AppKit
import Foundation
import ScreenContextCore

/// The companion's name, in one place.
let MascotName = "Tug"

/// User-adjustable settings, stored in UserDefaults. The connector key is never stored here (see Keychain).
enum Settings {
    static let keychainService = "com.kaungzinhein.commscoach.mac"
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
