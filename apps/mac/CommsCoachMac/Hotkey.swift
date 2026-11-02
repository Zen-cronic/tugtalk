import AppKit
import Carbon.HIToolbox
import OSLog

/// Every hotkey event as it arrives from the system, before any app state decides what it does.
let hotkeyLog = Logger(subsystem: "com.kaungzinhein.commscoach.mac", category: "hotkey")

/// Global hotkeys through Carbon's RegisterEventHotKey. Unlike a CGEvent tap, this needs no
/// Accessibility or Input Monitoring permission, and it only sees the registered combinations.
@MainActor
final class Hotkeys {
    struct Combo { let keyCode: UInt32; let label: String }
    static let modifiers = UInt32(controlKey | optionKey)
    static let capture = Combo(keyCode: UInt32(kVK_Space), label: "⌃⌥Space")
    static let hide = Combo(keyCode: UInt32(kVK_ANSI_H), label: "⌃⌥H")
    static let ghost = Combo(keyCode: UInt32(kVK_ANSI_G), label: "⌃⌥G")
    static let undo = Combo(keyCode: UInt32(kVK_ANSI_Z), label: "⌃⌥Z")
    /// Hold to talk: press opens the microphone, release sends the clip.
    static let talk = Combo(keyCode: UInt32(kVK_ANSI_T), label: "⌃⌥T")

    nonisolated(unsafe) private static var actions: [UInt32: @MainActor () -> Void] = [:]
    nonisolated(unsafe) private static var releaseActions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    /// Called when a combination is already taken (another app, or another copy of this one), so it is shown, not silent.
    var onRegistrationFailed: (Combo) -> Void = { _ in }
    private var handler: EventHandlerRef?

    init() {
        // Pressed for every hotkey; released too, for the ones registered with a release action.
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            hotkeyLog.notice("hotkey \(number, privacy: .public) \(released ? "released" : "pressed", privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { (released ? Hotkeys.releaseActions[number] : Hotkeys.actions[number])?() }
            }
            return noErr
        }, specs.count, &specs, nil, &handler)
    }

    /// Returns false when another app already owns the combination.
    @discardableResult
    func register(_ combo: Combo, onRelease: (@MainActor () -> Void)? = nil, action: @escaping @MainActor () -> Void) -> Bool {
        // `-disableHotkeys YES`: a test copy registers none, so it never takes the keys from a copy that is already running.
        if UserDefaults.standard.bool(forKey: "disableHotkeys") { return false }
        let number = UInt32(Self.actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, Self.modifiers, EventHotKeyID(signature: OSType(0x4343_4D43), id: number), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            hotkeyLog.error("\(combo.label, privacy: .public) could not be registered (status \(status, privacy: .public)); another app may own it")
            onRegistrationFailed(combo)
            return false
        }
        hotkeyLog.notice("\(combo.label, privacy: .public) registered as hotkey \(number, privacy: .public)")
        Self.actions[number] = action
        if let onRelease { Self.releaseActions[number] = onRelease }
        refs.append(ref)
        return true
    }
}
