import AppKit
import Combine
import SwiftUI

/// A small borderless panel that floats above other windows without taking focus.
/// Recipe adapted from clicky's CompanionResponseOverlay (MIT); see THIRD_PARTY_NOTICES.md.
final class MascotPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 96, height: 96), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false // the character handles its own drag
        becomesKeyOnlyIfNeeded = true
        isExcludedFromWindowsMenu = true
        setAccessibilityLabel("\(MascotName) companion")
    }

    override var canBecomeKey: Bool { true }
}

/// Owns the panel: size, position (remembered per display), ghost mode and hiding.
@MainActor
final class PanelController {
    let panel = MascotPanel()
    private let model: CompanionModel
    private var hosting: NSHostingView<MascotRoot>!
    private var anchor: CGPoint = .zero      // the character's centre, in screen coordinates
    private var dragOffset: CGPoint?
    private var observers: Set<AnyCancellable> = []

    init(model: CompanionModel) {
        self.model = model
        hosting = NSHostingView(rootView: MascotRoot(model: model, onDrag: { [weak self] value in self?.drag(value) }))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        let screen = NSScreen.main ?? NSScreen.screens[0]
        anchor = Settings.position(for: screen) ?? CGPoint(x: screen.visibleFrame.maxX - 70, y: screen.visibleFrame.minY + 70)
        model.$phase.combineLatest(model.$ghost, model.$presenting, model.$inMeetingApp)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &observers)
        model.onLayoutNeeded = { [weak self] in self?.refresh() }
        model.$dockedPanelOpen.receive(on: RunLoop.main).sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
    }

    func show() { refresh() }

    /// Re-applies visibility, ghost mode, size and position after any state change.
    func refresh() {
        if model.isHidden {
            panel.orderOut(nil)
            return
        }
        panel.ignoresMouseEvents = model.ghost
        panel.alphaValue = model.ghost ? 0.35 : 1
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func layout() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let half = MascotLayout.character / 2, edge = MascotLayout.pad + half
        anchor.x = min(max(anchor.x, visible.minX + edge), visible.maxX - edge)
        anchor.y = min(max(anchor.y, visible.minY + edge), visible.maxY - edge)
        // The bubble opens toward the middle of the screen.
        let leading = anchor.x > visible.midX
        if model.bubbleLeading != leading { model.bubbleLeading = leading }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let x = leading ? anchor.x + edge - size.width : anchor.x - edge
        var origin = CGPoint(x: x, y: anchor.y - edge)
        origin.y = min(origin.y, visible.maxY - size.height)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func drag(_ value: DragGesture.Value?) {
        let mouse = NSEvent.mouseLocation
        guard value != nil else {
            dragOffset = nil
            if let screen = panel.screen { Settings.setPosition(anchor, for: screen) }
            return
        }
        if dragOffset == nil { dragOffset = CGPoint(x: mouse.x - anchor.x, y: mouse.y - anchor.y) }
        guard let offset = dragOffset else { return }
        anchor = CGPoint(x: mouse.x - offset.x, y: mouse.y - offset.y)
        layout()
    }

    /// Moves the floating panel off `rect` (AppKit coordinates) for now, above it or else below it, so our own
    /// card never covers the line Tug circles. Not remembered; the next drag or display change resets it.
    func moveAway(from rect: CGRect) {
        guard panel.isVisible, panel.frame.intersects(rect), let visible = panel.screen?.visibleFrame else { return }
        let up = rect.maxY - panel.frame.minY, down = panel.frame.maxY - rect.minY
        if panel.frame.maxY + up <= visible.maxY { anchor.y += up } else { anchor.y -= down }
        layout()
    }

    /// The floating Tug's centre on screen, where its trip to the docked panel starts and ends.
    var tugCenter: CGPoint { anchor }

    /// The panel's window number, for screenshots of the companion alone.
    var windowNumber: Int { panel.windowNumber }
}
