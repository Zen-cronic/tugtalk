import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The frontmost app at the moment the person asked for a capture.
public struct FrontApp: Sendable, Equatable {
    public let name: String
    public let bundleID: String
    public let processID: pid_t
    public init(name: String, bundleID: String, processID: pid_t) {
        self.name = name; self.bundleID = bundleID; self.processID = processID
    }
}

/// One window's pixels, held in memory only.
public struct CapturedWindow: @unchecked Sendable {
    public let image: CGImage
    public let app: FrontApp
    /// Where the image sits on screen, in global display points with the origin at the top left of the
    /// main display (the Core Graphics convention). Nil when the image did not come from a window.
    public let frame: CGRect?
    /// The window's number, to notice when it moves or closes. Nil when unknown.
    public let windowID: CGWindowID?
    public init(image: CGImage, app: FrontApp, frame: CGRect? = nil, windowID: CGWindowID? = nil) {
        self.image = image; self.app = app; self.frame = frame; self.windowID = windowID
    }
}

public enum CaptureError: LocalizedError, Equatable {
    case blocked(String)
    case permissionNeeded
    case noWindow
    case unreadableImage
    case nothingRead

    public var errorDescription: String? {
        switch self {
        case .blocked(let app): return "I don't read \(app)."
        case .permissionNeeded: return "Screen Recording permission is needed to read a window."
        case .noWindow: return "There is no window to read in the front app."
        case .unreadableImage: return "The image could not be read."
        case .nothingRead: return "No text was found in that window."
        }
    }
}

public protocol WindowCapturing: Sendable {
    func capture(_ app: FrontApp) async throws -> CapturedWindow
}

/// Apps the companion refuses to read, plus itself. Editable through the app's settings.
public struct CaptureGate: Sendable {
    public static let defaultDenyList: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.systempreferences", "com.apple.Settings", "com.apple.MobileSMS",
        "com.kaungzinhein.commscoach.mac",
    ]

    public var denyList: Set<String>
    public init(denyList: Set<String> = CaptureGate.defaultDenyList) { self.denyList = denyList }

    public enum Decision: Equatable, Sendable { case allowed, blocked(String) }

    /// `secureInput` is true while a password field anywhere has secure keyboard entry on.
    public func check(_ app: FrontApp, secureInput: Bool) -> Decision {
        if denyList.contains(app.bundleID) { return .blocked(app.name) }
        if secureInput { return .blocked("a password field") }
        return .allowed
    }
}

/// Captures exactly one window, the front app's frontmost normal window, with ScreenCaptureKit.
///
/// `SCContentFilter(desktopIndependentWindow:)` renders that window alone, so other windows,
/// the desktop and the companion itself never appear in the pixels.
public struct ScreenCaptureKitWindowCapture: WindowCapturing {
    /// Longest side of the captured image. Enough for Vision to read body text.
    public var maxPixels: Int

    public init(maxPixels: Int = 2560) { self.maxPixels = maxPixels }

    /// No prompt: only reports whether this app already holds Screen Recording access.
    public static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    public func capture(_ app: FrontApp) async throws -> CapturedWindow {
        // Calling ScreenCaptureKit without access would raise the system prompt; refuse instead.
        guard Self.hasPermission() else { throw CaptureError.permissionNeeded }
        guard let windowID = Self.frontmostWindowID(of: app.processID) else { throw CaptureError.noWindow }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let width = window.frame.width * scale, height = window.frame.height * scale
        let shrink = min(1, CGFloat(maxPixels) / max(width, height, 1))
        configuration.width = max(1, Int(width * shrink))
        configuration.height = max(1, Int(height * shrink))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedWindow(image: image, app: app, frame: window.frame, windowID: windowID)
    }

    /// The front-to-back window list needs no permission for ids and owners (titles are not read).
    static func frontmostWindowID(of pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 80, (bounds["Height"] ?? 0) > 60,
                  let number = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return number
        }
        return nil
    }
}
