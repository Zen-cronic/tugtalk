import AppKit
import ScreenContextCore

/// The menu-bar item. Every action the character offers is here too, so nothing is mouse-only on the panel.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: CompanionModel
    private let menu = NSMenu()

    var onCapture: () -> Void = {}
    var onUndo: () -> Void = {}
    var onAskMuse: () -> Void = {}
    var onPreview: (MascotPhase?) -> Void = { _ in }
    var onDemoMode: (Bool) -> Void = { _ in }
    var onSelectGoal: (String?) -> Void = { _ in }
    var goals: () -> [(id: String, title: String)] = { [] }
    var connectionStatus: () -> String = { "" }

    init(model: CompanionModel) {
        self.model = model
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "\(MascotName) companion")
            button.image?.isTemplate = true
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: "\(MascotName): \(model.phase.name)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let connection = connectionStatus()
        if !connection.isEmpty {
            let line = NSMenuItem(title: connection, action: nil, keyEquivalent: ""); line.isEnabled = false; menu.addItem(line)
        }
        menu.addItem(.separator())
        menu.addItem(action("Read This Window", key: " ", run: onCapture))
        menu.addItem(action("Undo Last Card", key: "z", enabled: model.lastCard != nil, run: onUndo))
        menu.addItem(action("Ask Muse About Last Card", enabled: model.lastCard != nil, run: onAskMuse))
        let talk = NSMenuItem(title: "Voice: Hold ⌃⌥T and Talk, Let Go to Send", action: nil, keyEquivalent: ""); talk.isEnabled = false
        menu.addItem(talk)
        menu.addItem(.separator())
        menu.addItem(toggle("Presenting (Hide Companion)", key: "h", on: model.presenting) { [model] in model.presenting.toggle() })
        menu.addItem(toggle("Ghost Mode (Clicks Pass Through)", key: "g", on: model.ghost) { [model] in model.ghost.toggle() })
        menu.addItem(toggle("Hide While a Meeting App Is in Front", on: Settings.autoHideInMeetings) { [model] in
            Settings.autoHideInMeetings.toggle()
            if !Settings.autoHideInMeetings { model.inMeetingApp = false }
        })
        menu.addItem(toggle("Demo Mode (Check Every 15 s)", on: model.demoMode) { [weak self, model] in
            model.demoMode.toggle(); self?.onDemoMode(model.demoMode)
        })
        menu.addItem(.separator())
        menu.addItem(submenu("Goal", goalItems()))
        menu.addItem(submenu("Purpose", ScreenContextPayload.Purpose.allCases.map { purpose in
            toggle(purpose.title, on: Settings.purpose == purpose) { Settings.purpose = purpose }
        }))
        menu.addItem(submenu("Voice Reply Language", VoiceLanguage.allCases.map { language in
            toggle(language.title, on: Settings.voiceLanguage == language) { Settings.voiceLanguage = language }
        }))
        var previews = PreviewSamples.all.map { phase in action(phase.name.capitalized) { [weak self] in self?.onPreview(phase) } }
        previews.append(.separator())
        previews.append(action("Cycle All States") { [weak self] in self?.onPreview(nil) })
        menu.addItem(submenu("Preview States", previews))
        menu.addItem(.separator())
        menu.addItem(action("Screen Recording Settings…") { PermissionGate.openSettings() })
        menu.addItem(action("Microphone Settings…") { MicPermission.openSettings() })
        menu.addItem(action("Quit \(MascotName)", key: "q", modifiers: .command) { NSApp.terminate(nil) })
    }

    private func goalItems() -> [NSMenuItem] {
        let list = goals()
        var items = [toggle("No Goal", on: Settings.goalID == nil) { [weak self] in self?.onSelectGoal(nil) }]
        items += list.map { goal in toggle(goal.title, on: Settings.goalID == goal.id) { [weak self] in self?.onSelectGoal(goal.id) } }
        if list.isEmpty {
            let empty = NSMenuItem(title: "Goals load after the first check", action: nil, keyEquivalent: ""); empty.isEnabled = false
            items.append(empty)
        }
        return items
    }

    // Menu item helpers. Hotkey combinations are shown as key equivalents; they work globally.

    private func action(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.control, .option], enabled: Bool = true, run: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureItem(title: title, keyEquivalent: key, run: run)
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = enabled
        return item
    }

    private func toggle(_ title: String, key: String = "", on: Bool, run: @escaping () -> Void) -> NSMenuItem {
        let item = action(title, key: key, run: run)
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        items.forEach(sub.addItem)
        parent.submenu = sub
        return parent
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, keyEquivalent: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

extension ScreenContextPayload.Purpose {
    var title: String {
        switch self {
        case .meeting_prep: "Meeting Prep"
        case .draft_check: "Draft Check"
        case .reading: "Reading"
        }
    }
}
