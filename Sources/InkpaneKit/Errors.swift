import Foundation

public enum InkpaneError: Error, LocalizedError, Sendable, Equatable {
    /// Screen Recording permission is missing. `hostApp` is the app macOS
    /// attributes this process to — the one the user has to grant.
    case screenRecordingPermissionDenied(hostApp: HostApp?, alternatives: [HostApp] = [])
    case displayNotFound(index: Int, available: Int)
    case windowNotFound(id: UInt32)
    case appWindowNotFound(app: String, title: String?)
    case regionOffScreen(Rect)
    case invalidRegion(Rect)
    case imageLoadFailed(path: String)
    case imageEncodingFailed
    case unsupportedLanguages([String], supported: [String])
    case captureFailed(String)
    case ocrFailed(String)
    /// The window belongs to an app on the exclusion list.
    case excludedApp(name: String)
    /// Accessibility permission is missing (needed to read UI trees). `hostApp` is the app
    /// macOS attributes this process to.
    case accessibilityPermissionDenied(hostApp: HostApp?)

    public var errorDescription: String? {
        switch self {
        case .excludedApp(let name):
            return "\(name) is on the user's privacy exclusion list, so its windows can't be captured or read. Ask the user to share what you need some other way (they can change the list in Inkpane Settings → Privacy)."
        case .accessibilityPermissionDenied(let hostApp):
            let pane = "System Settings → Privacy & Security → Accessibility"
            if let hostApp {
                return "Accessibility permission is required to read the UI tree. macOS attributes this server to \"\(hostApp.name)\" (\(hostApp.bundlePath)), the terminal or AI client that launched it. Enable \"\(hostApp.name)\" in \(pane), then quit and reopen \"\(hostApp.name)\". Until then, read_screen_ocr can read the text on screen."
            }
            return "Accessibility permission is required to read the UI tree. Enable the app that launched this server (your terminal or AI client) in \(pane), then quit and reopen that app. Until then, read_screen_ocr can read the text on screen."
        case .screenRecordingPermissionDenied(let hostApp, let alternatives):
            return Self.permissionMessage(hostApp: hostApp, alternatives: alternatives)
        case .displayNotFound(let index, let available):
            return "Display \(index) not found. \(available) display(s) available (indices 0...\(max(available - 1, 0))); 0 is the main display."
        case .windowNotFound(let id):
            return "No window with id \(id). Call list_windows to get current window ids."
        case .appWindowNotFound(let app, let title):
            let titlePart = title.map { " with a title containing \"\($0)\"" } ?? ""
            return "No on-screen window found for app \"\(app)\"\(titlePart). Match is by app name or bundle id; call list_windows to see what is available."
        case .regionOffScreen(let rect):
            return "Region \(rect) does not intersect any display."
        case .invalidRegion(let rect):
            return "Invalid region \(rect): width and height must be positive."
        case .imageLoadFailed(let path):
            return "Could not load an image from \(path)."
        case .imageEncodingFailed:
            return "Failed to encode the image as PNG."
        case .unsupportedLanguages(let langs, let supported):
            return "Unsupported OCR language(s): \(langs.joined(separator: ", ")). Supported: \(supported.joined(separator: ", "))."
        case .captureFailed(let message):
            return "Screen capture failed: \(message)"
        case .ocrFailed(let message):
            return "Text recognition failed: \(message)"
        }
    }

    /// The permission error for this process, naming the app(s) that launched it.
    public static func permissionDenied() -> InkpaneError {
        let chain = HostApp.detectChain()
        return .screenRecordingPermissionDenied(hostApp: chain.first, alternatives: Array(chain.dropFirst()))
    }

    static func permissionMessage(hostApp: HostApp?, alternatives: [HostApp]) -> String {
        let pane = "System Settings → Privacy & Security → Screen & System Audio Recording"
        if let hostApp {
            var message = """
                Screen Recording permission is required. macOS attributes this server to "\(hostApp.name)" \
                (\(hostApp.bundlePath)) — the terminal or AI client that launched it. \
                Enable "\(hostApp.name)" in \(pane), then quit and reopen "\(hostApp.name)".
                """
            if !alternatives.isEmpty {
                let names = alternatives.map { "\"\($0.name)\" (\($0.bundlePath))" }.joined(separator: ", ")
                message += " If it is not listed there or that does not help, grant it to the app that launched it instead: \(names)."
            }
            return message
        }
        return """
            Screen Recording permission is required. Enable the app that launched this server \
            (your terminal, e.g. Terminal/iTerm/Ghostty, or your AI client, e.g. Claude/Cursor/VS Code) \
            in \(pane), then quit and reopen that app.
            """
    }
}
