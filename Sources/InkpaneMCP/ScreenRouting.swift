import CoreGraphics
import Foundation
import MCP
import InkpaneKit

// Where screen reads (capture_*, read_screen_ocr, list_windows, screen://windows/active) run.
//
// * The Inkpane app is running: they go through its bridge, so the app asks the user before
//   a new agent first looks, leaves out excluded apps, applies auto-redaction, shows its
//   "agent is viewing" indicator and logs the request. If the app can't capture (it lacks
//   Screen Recording permission) it says so and hands back its privacy policy; this process
//   then captures under that policy. When the app refuses (the user denied the agent, or the
//   target app is excluded), the refusal is final: there is no local retry.
// * Nothing is listening (or the app predates these methods): this process captures by itself,
//   exactly as without the app, unless `--require-app` / `INKPANE_MCP_REQUIRE_APP=1` is set,
//   in which case the tools fail with an explanation.

/// Whether screen reads may run without the Inkpane app.
public enum AppRequirement: String, Sendable, Equatable {
    /// Use the app when it is running, otherwise capture standalone.
    case optional
    /// Fail when the app isn't reachable.
    case required

    public static let environmentKey = "INKPANE_MCP_REQUIRE_APP"

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AppRequirement {
        switch environment[environmentKey]?.lowercased() {
        case "1", "true", "yes", "on": .required
        default: .optional
        }
    }
}

/// Bundle ids excluded in standalone mode (`INKPANE_MCP_EXCLUDE_APPS`, comma-separated).
/// With the app running, its own list applies instead.
public enum StandaloneExclusions {
    public static let environmentKey = "INKPANE_MCP_EXCLUDE_APPS"

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CaptureExclusions {
        let ids = (environment[environmentKey] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return CaptureExclusions(bundleIDs: ids)
    }
}

extension InkpaneTools {
    /// A capture plus what happened to it on the way.
    struct ObtainedCapture {
        var capture: Capture
        var ocr: OCRResult?
        var privacy: PrivacyReport?
        /// How it was taken, for the agent: `nil` for a plain capture by the app or standalone.
        var note: String?
    }

    static func requiredAppMessage(_ detail: String) -> String {
        """
        The Inkpane app is required for screen access (inkpane-mcp runs with --require-app or \
        \(AppRequirement.environmentKey)=1), but \(detail). Ask the user to start the Inkpane menu \
        bar app (for example `open -a Inkpane`), then try again.
        """
    }

    /// Whether a bridge error means "no app to talk to" (so standalone is allowed), as opposed
    /// to a refusal or a failure of a running app.
    static func meansNoApp(_ error: any Error) -> String? {
        switch error {
        case BridgeClientError.appNotRunning(let path):
            return "nothing is listening on \(path)"
        case BridgeClientError.remote(let payload) where payload.code == .unknownMethod:
            return "the running Inkpane app is too old to handle screen reads"
        default:
            return nil
        }
    }

    /// Captures `target`, through the app when it is running.
    func obtainCapture(_ target: CaptureTarget, ocr: TextRecognizer?, tool: String) async throws -> ObtainedCapture {
        let result: CaptureResult
        do {
            result = try await bridge.capture(CaptureParams(target: target, ocr: ocr, tool: tool))
        } catch {
            guard let reason = Self.meansNoApp(error) else { throw error }
            guard requirement == .optional else { throw ArgumentError(Self.requiredAppMessage(reason)) }
            return try await captureStandalone(target, ocr: ocr)
        }
        if let image = result.capture {
            return ObtainedCapture(
                capture: try image.capture(excludedApps: result.privacy?.excludedApps ?? []), ocr: result.ocr,
                privacy: result.privacy, note: nil)
        }
        guard let fallback = result.fallback else { throw BridgeClientError.invalidResponse("capture without an image or a fallback") }
        let filtered = try await captureUnderPolicy(target, policy: fallback.policy, ocr: ocr)
        return ObtainedCapture(
            capture: filtered.capture, ocr: filtered.ocr, privacy: filtered.report,
            note: "Captured by inkpane-mcp under Inkpane's privacy settings, because the app could not capture: \(fallback.reason)")
    }

    /// The Inkpane app couldn't capture, so this process does, under the app's policy.
    func captureUnderPolicy(_ target: CaptureTarget, policy: CapturePolicy, ocr: TextRecognizer?) async throws -> PrivacyFilter.Output {
        var capturer = self.capturer
        capturer.exclusions = policy.exclusions
        let capture = try await capturer.capture(target)
        return try PrivacyFilter.apply(to: capture, policy: policy, ocr: ocr, excludedApps: capture.excludedApps)
    }

    /// Without the app: the capturer's own exclusions (from `INKPANE_MCP_EXCLUDE_APPS`), no
    /// redaction.
    func captureStandalone(_ target: CaptureTarget, ocr: TextRecognizer?) async throws -> ObtainedCapture {
        let capture = try await capturer.capture(target)
        let text = try ocr?.recognize(capture.image, captureFrame: capture.frame)
        let privacy = capture.excludedApps.isEmpty ? nil : PrivacyReport(excludedApps: capture.excludedApps)
        return ObtainedCapture(capture: capture, ocr: text, privacy: privacy, note: nil)
    }

    /// Windows and displays, through the app when it is running.
    func obtainWindowListing(_ options: WindowListOptions, tool: String) async throws -> WindowListing {
        do {
            let result = try await bridge.listWindows(ListWindowsParams(options, tool: tool))
            var notes: [String] = []
            if !result.screenRecordingPermission {
                notes.append("Window titles are hidden because the Inkpane app does not have Screen Recording permission.")
            }
            if result.hiddenCount > 0 {
                notes.append("\(result.hiddenCount) window(s) of apps on the user's privacy exclusion list are not listed.")
            }
            return WindowListing(
                screenRecordingPermission: result.screenRecordingPermission,
                note: notes.isEmpty ? nil : notes.joined(separator: " "),
                displays: result.displays, frontmostWindowID: result.frontmostWindowId, windows: result.windows)
        } catch {
            guard let reason = Self.meansNoApp(error) else { throw error }
            guard requirement == .optional else { throw ArgumentError(Self.requiredAppMessage(reason)) }
            var listing = Self.windowListing(options)
            let all = listing.windows
            listing.windows = capturer.exclusions.filter(all)
            if listing.windows.count < all.count {
                let hidden = "\(all.count - listing.windows.count) window(s) of excluded apps (\(StandaloneExclusions.environmentKey)) are not listed."
                listing.note = [listing.note, hidden].compactMap { $0 }.joined(separator: " ")
                if let front = listing.frontmostWindowID, !listing.windows.contains(where: { $0.windowID == front }) {
                    listing.frontmostWindowID = WindowList.frontmostWindow(in: listing.windows)?.windowID
                }
            }
            return listing
        }
    }
}
