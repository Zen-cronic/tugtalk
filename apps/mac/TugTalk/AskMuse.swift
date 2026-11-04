import AppKit

/// "Ask Muse": a hand-off, not an integration. It copies a ready question to the clipboard and
/// opens Muse with public macOS calls; the person pastes and sends it. The companion never types
/// into, clicks in or otherwise drives Muse or any other app.
@MainActor
enum AskMuse {
    static func prompt(for card: ContextCard) -> String {
        "Read my coaching overview and tell me about screen context \(card.recordID) from \(card.appName). What should I practise next?"
    }

    static func open(for card: ContextCard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt(for: card), forType: .string)
        let installed = ["/Applications/Muse.app", NSString(string: "~/Applications/Muse.app").expandingTildeInPath]
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
        if let installed {
            NSWorkspace.shared.openApplication(at: installed, configuration: NSWorkspace.OpenConfiguration())
        } else if let web = URL(string: "https://muse.ai") {
            NSWorkspace.shared.open(web)
        }
    }
}
