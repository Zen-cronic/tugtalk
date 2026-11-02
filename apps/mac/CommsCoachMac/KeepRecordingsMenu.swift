import AppKit
import ScreenContextCore

/// "Keep My Recordings" in the menu-bar menu. The setting lives on the coach server (GET and PATCH /v1/settings), so
/// the watch and the Mac show the same answer; the Mac stores none of it. Off by default: the server deletes audio
/// after transcription. On: it keeps each recording in the account, where this menu can save or delete it.
@MainActor
final class KeepRecordingsMenu {
    private(set) var settings: CoachSettings?
    /// A short line under the toggle after something happened ("Kept recordings deleted."), or an error.
    private var note: String?
    private var busy = false

    init() { refresh() }

    /// Reads the setting in the background; the menu shows the last known state meanwhile.
    func refresh() {
        guard !busy, let api = Connection.api()?.api else { return }
        Task { [weak self] in
            do {
                let wasUnread = self?.settings == nil
                self?.settings = try await api.settings()
                if wasUnread { self?.note = nil } // an earlier read error no longer applies
            }
            catch let error as CoachError { self?.note = error.plainMessage(for: .saveCard) }
            catch {}
        }
    }

    func items() -> [NSMenuItem] {
        guard let settings else {
            // Not read yet, or this coach has no such setting (an older server answers 404).
            return [disabled("\(KeepRecordingsCopy.menuLabel): \(note == nil ? "checking…" : "unavailable")")] + (note.map { [disabled($0)] } ?? [])
        }
        let toggle = ClosureItem(title: KeepRecordingsCopy.menuLabel, keyEquivalent: "") { [weak self] in self?.toggle() }
        toggle.state = settings.keep_recordings ? .on : .off
        toggle.isEnabled = !busy
        var list = [toggle, disabled(settings.keep_recordings ? KeepRecordingsCopy.explainerOn : KeepRecordingsCopy.explainerOff)]
        if let kept = settings.kept, kept.recordings > 0 {
            list.append(disabled(KeepRecordingsCopy.summary(kept)))
            list.append(ClosureItem(title: "Save Kept Recordings to Downloads", keyEquivalent: "") { [weak self] in self?.saveToDownloads() })
            list.append(ClosureItem(title: "Delete Kept Recordings…", keyEquivalent: "") { [weak self] in self?.confirmDeleteAll() })
        }
        if let note { list.append(disabled(note)) }
        return list
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; return item
    }

    // Actions

    private func toggle() {
        guard let settings else { return }
        guard settings.keep_recordings else { return save(keep: true, deleteKept: false, from: settings) }
        let kept = settings.kept?.recordings ?? 0
        guard kept > 0 else { return save(keep: false, deleteKept: false, from: settings) }
        // Turning it off: offer to delete what is already kept, or keep it.
        let alert = NSAlert()
        alert.messageText = "Turn off Keep my recordings?"
        alert.informativeText = "New recordings will be deleted after transcription. You have \(KeepRecordingsCopy.summary(settings.kept!))."
        alert.addButton(withTitle: KeepRecordingsCopy.turnOff)
        let delete = alert.addButton(withTitle: KeepRecordingsCopy.turnOffAndDelete)
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(keep: false, deleteKept: false, from: settings)
        case .alertSecondButtonReturn: save(keep: false, deleteKept: true, from: settings)
        default: break
        }
    }

    private func save(keep: Bool, deleteKept: Bool, from current: CoachSettings) {
        guard let api = Connection.api()?.api else { note = Connection.unavailableReason; return }
        busy = true
        let key = CoachAPI.newIdempotencyKey(prefix: "mac-settings")
        Task { [weak self] in
            defer { self?.busy = false }
            do {
                self?.settings = try await api.setKeepRecordings(keep, deleteKept: deleteKept, expectedVersion: current.version, idempotencyKey: key)
                self?.note = keep ? "Recordings are kept from now on." : (deleteKept ? "Kept recordings deleted." : nil)
            } catch let error as CoachError {
                // A 409 means another device changed it first: read it again rather than overwrite.
                if case .server(409, _, _) = error { self?.note = "Changed on another device. Open the menu again." } else { self?.note = error.plainMessage(for: .saveCard) }
                self?.busy = false
                self?.refresh()
            } catch {}
        }
    }

    private func confirmDeleteAll() {
        guard let kept = settings?.kept, let api = Connection.api()?.api else { return }
        let alert = NSAlert()
        alert.messageText = "Delete kept recordings?"
        alert.informativeText = "This deletes \(KeepRecordingsCopy.summary(kept)) from your account. The transcripts and counts stay."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        let key = CoachAPI.newIdempotencyKey(prefix: "mac-media")
        Task { [weak self] in
            do { try await api.deleteAllKeptRecordings(idempotencyKey: key); self?.note = "Kept recordings deleted." }
            catch let error as CoachError { self?.note = error.plainMessage(for: .saveCard) }
            catch {}
            self?.busy = false
            self?.refresh()
        }
    }

    /// Saves every kept recording to ~/Downloads/Comms Coach Recordings and shows the folder.
    private func saveToDownloads() {
        guard let api = Connection.api()?.api,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let folder = downloads.appending(path: "Comms Coach Recordings", directoryHint: .isDirectory)
        busy = true
        note = "Saving kept recordings…"
        Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let list = try await api.keptRecordings()
                for item in list {
                    let day = item.occurred_at.map { String($0.prefix(19)).replacingOccurrences(of: ":", with: "-") } ?? "recording"
                    try await api.downloadKeptRecording(id: item.id).write(to: folder.appending(path: "\(day) \(item.id.prefix(8)).wav"), options: .atomic)
                }
                self?.note = "Saved \(list.count) to Downloads."
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch let error as CoachError { self?.note = error.plainMessage(for: .saveCard) }
            catch { self?.note = "Could not save to Downloads." }
            self?.busy = false
        }
    }
}
