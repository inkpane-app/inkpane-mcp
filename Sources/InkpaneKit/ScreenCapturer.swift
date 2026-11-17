import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// What to capture.
public enum CaptureTarget: Sendable, Hashable {
    /// A whole display; index 0 is the main display (see `DisplayInfo.all()`).
    case display(index: Int)
    /// A single window by window-server id (see `WindowList`).
    case window(id: UInt32)
    /// The frontmost window of an app, matched by app name or bundle id,
    /// optionally narrowed by a case-insensitive title substring.
    case app(String, titleContains: String?)
    /// A rectangle in global points. Clipped to the display it overlaps most.
    case region(Rect)
}

public struct Capture: @unchecked Sendable {
    public enum Kind: String, Codable, Sendable {
        case display, window, region
    }

    public var image: CGImage
    public var kind: Kind
    /// The global frame, in points, that the image covers.
    public var frame: Rect
    /// Image pixels per point.
    public var scale: Double
    public var display: DisplayInfo?
    public var window: WindowInfo?
    /// Set when a region had to be clipped to the display bounds.
    public var requestedRegion: Rect?
    public var capturedAt: Date
    /// Excluded apps (names, or bundle ids) that had windows in the captured area and were
    /// left out of the image.
    public var excludedApps: [String]

    public init(
        image: CGImage, kind: Kind, frame: Rect, scale: Double, display: DisplayInfo? = nil, window: WindowInfo? = nil,
        requestedRegion: Rect? = nil, capturedAt: Date = Date(), excludedApps: [String] = []
    ) {
        self.image = image
        self.kind = kind
        self.frame = frame
        self.scale = scale
        self.display = display
        self.window = window
        self.requestedRegion = requestedRegion
        self.capturedAt = capturedAt
        self.excludedApps = excludedApps
    }
}

/// Captures screen content with ScreenCaptureKit (`SCScreenshotManager`).
public struct ScreenCapturer: Sendable {
    /// Apps and windows to leave out. Display and region captures filter them out; window
    /// captures of an excluded app throw `InkpaneError.excludedApp`.
    public var exclusions: CaptureExclusions

    public init(exclusions: CaptureExclusions = .none) {
        self.exclusions = exclusions
    }

    public func capture(_ target: CaptureTarget) async throws -> Capture {
        try ScreenRecordingPermission.require()
        return try await captureWithoutPrompting(target)
    }

    /// The same as `capture(_:)`, but never triggers the system permission prompt. Callers
    /// check `ScreenRecordingPermission.isGranted` themselves (the Inkpane app does).
    public func captureWithoutPrompting(_ target: CaptureTarget) async throws -> Capture {
        guard ScreenRecordingPermission.isGranted else { throw InkpaneError.permissionDenied() }
        switch target {
        case .display(let index):
            return try await captureDisplay(index: index)
        case .window(let id):
            let info = WindowList.windows(.init(includeOffscreen: true)).first { $0.windowID == id }
            if let info { try refuseIfExcluded(info) }
            return try await captureWindow(id: id, info: info)
        case .app(let app, let titleContains):
            let windows = WindowList.windows()
            guard let info = WindowList.bestWindow(forApp: app, titleContains: titleContains, in: windows) else {
                throw InkpaneError.appWindowNotFound(app: app, title: titleContains)
            }
            try refuseIfExcluded(info)
            return try await captureWindow(id: info.windowID, info: info)
        case .region(let rect):
            return try await captureRegion(rect)
        }
    }

    /// Several displays at once: one window-list query shared by all of them and the screenshots
    /// taken in parallel, so freezing three displays costs about as much as one. Results are in
    /// the order of `indices`. `excludingWindowIDs` leaves those windows out of every image, e.g.
    /// the caller's own selection UI that is already on screen (with `exclusions` set, only
    /// windows the exclusions would otherwise keep can be left out this way). Windows just put
    /// on screen are waited for (about half a second at most) until the window list has them.
    public func captureDisplays(_ indices: [Int], excludingWindowIDs: Set<UInt32> = []) async throws -> [Capture] {
        try ScreenRecordingPermission.require()
        let displays = DisplayInfo.all()
        var content = try await shareableContent(onScreenWindowsOnly: true)
        // Windows ordered in a moment ago (a selection UI put up just before) can be missing
        // from the list for a little while, and a window that isn't listed can't be left out:
        // wait for them rather than capture them.
        var waited = 0
        while !excludingWindowIDs.isSubset(of: Set(content.windows.map(\.windowID))) {
            waited += 1
            guard waited <= 25 else { throw InkpaneError.captureFailed("The windows to leave out never appeared on screen.") }
            try await Task.sleep(for: .milliseconds(20))
            content = try await shareableContent(onScreenWindowsOnly: true)
        }
        var jobs: [(position: Int, info: DisplayInfo, filter: SCContentFilter, config: SCStreamConfiguration)] = []
        for (position, index) in indices.enumerated() {
            guard displays.indices.contains(index),
                  let display = content.displays.first(where: { $0.displayID == displays[index].displayID }) else {
                throw InkpaneError.displayNotFound(index: index, available: displays.count)
            }
            let info = displays[index]
            let config = baseConfiguration()
            config.width = info.pixelWidth
            config.height = info.pixelHeight
            jobs.append((position, info, displayFilter(display, content: content, excludingWindowIDs: excludingWindowIDs), config))
        }
        var images = [CGImage?](repeating: nil, count: indices.count)
        try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for job in jobs {
                group.addTask { (job.position, try await screenshot(filter: job.filter, configuration: job.config)) }
            }
            for try await (position, image) in group { images[position] = image }
        }
        let now = Date()
        return jobs.compactMap { job in
            images[job.position].map {
                Capture(image: $0, kind: .display, frame: job.info.frame, scale: job.info.scale, display: job.info, window: nil,
                        requestedRegion: nil, capturedAt: now, excludedApps: excludedApps(in: job.info.frame))
            }
        }
    }

    /// Throws `InkpaneError.excludedApp` when the window belongs to an excluded app.
    public func refuseIfExcluded(_ window: WindowInfo) throws {
        guard exclusions.excludes(window) else { return }
        throw InkpaneError.excludedApp(name: window.appName ?? window.bundleID ?? "This app")
    }

    // MARK: - Targets

    private func captureDisplay(index: Int) async throws -> Capture {
        let displays = DisplayInfo.all()
        guard displays.indices.contains(index) else {
            throw InkpaneError.displayNotFound(index: index, available: displays.count)
        }
        let info = displays[index]
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == info.displayID }) else {
            throw InkpaneError.displayNotFound(index: index, available: displays.count)
        }
        let filter = displayFilter(display, content: content)
        let config = baseConfiguration()
        config.width = info.pixelWidth
        config.height = info.pixelHeight
        let image = try await screenshot(filter: filter, configuration: config)
        return Capture(
            image: image, kind: .display, frame: info.frame, scale: info.scale, display: info, window: nil,
            requestedRegion: nil, capturedAt: Date(), excludedApps: excludedApps(in: info.frame))
    }

    private func captureWindow(id: UInt32, info: WindowInfo?) async throws -> Capture {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw InkpaneError.windowNotFound(id: id)
        }
        if let owner = window.owningApplication, !exclusions.exceptWindowIDs.contains(id),
           exclusions.excludes(bundleID: owner.bundleIdentifier) || exclusions.processIDs.contains(owner.processID) {
            throw InkpaneError.excludedApp(name: owner.applicationName.isEmpty ? owner.bundleIdentifier : owner.applicationName)
        }
        let frame = window.frame
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let config = baseConfiguration()
        config.width = max(1, Int((frame.width * scale).rounded()))
        config.height = max(1, Int((frame.height * scale).rounded()))
        config.ignoreShadowsSingleWindow = true
        let image = try await screenshot(filter: filter, configuration: config)
        let displays = DisplayInfo.all()
        let displayIndex = CoordinateConversion.bestDisplayIndex(for: frame, displayFrames: displays.map(\.frame.cgRect))
        return Capture(
            image: image, kind: .window, frame: Rect(frame), scale: scale,
            display: displayIndex.map { displays[$0] }, window: info, requestedRegion: nil, capturedAt: Date())
    }

    private func captureRegion(_ region: Rect) async throws -> Capture {
        guard region.width > 0, region.height > 0 else { throw InkpaneError.invalidRegion(region) }
        let displays = DisplayInfo.all()
        let rect = region.cgRect
        guard let index = CoordinateConversion.bestDisplayIndex(for: rect, displayFrames: displays.map(\.frame.cgRect))
        else { throw InkpaneError.regionOffScreen(region) }
        let info = displays[index]
        let clipped = rect.intersection(info.frame.cgRect).integral
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == info.displayID }) else {
            throw InkpaneError.displayNotFound(index: index, available: displays.count)
        }
        let filter = displayFilter(display, content: content)
        let config = baseConfiguration()
        config.sourceRect = CoordinateConversion.globalToDisplayLocal(clipped, displayFrame: info.frame.cgRect)
        config.width = max(1, Int((clipped.width * info.scale).rounded()))
        config.height = max(1, Int((clipped.height * info.scale).rounded()))
        let image = try await screenshot(filter: filter, configuration: config)
        return Capture(
            image: image, kind: .region, frame: Rect(clipped), scale: info.scale, display: info, window: nil,
            requestedRegion: clipped == rect ? nil : region, capturedAt: Date(), excludedApps: excludedApps(in: Rect(clipped)))
    }

    // MARK: - Exclusions

    /// The whole display, minus excluded apps' windows (but keeping `exceptWindowIDs`).
    private func displayFilter(_ display: SCDisplay, content: SCShareableContent, excludingWindowIDs: Set<UInt32> = []) -> SCContentFilter {
        guard !exclusions.isEmpty else {
            let left = excludingWindowIDs.isEmpty ? [] : content.windows.filter { excludingWindowIDs.contains($0.windowID) }
            return SCContentFilter(display: display, excludingWindows: left)
        }
        let apps = content.applications.filter {
            exclusions.excludes(bundleID: $0.bundleIdentifier) || exclusions.processIDs.contains($0.processID)
        }
        let kept = content.windows.filter { exclusions.exceptWindowIDs.contains($0.windowID) && !excludingWindowIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: kept)
    }

    /// Names of excluded apps with a visible window overlapping `frame`, for the report.
    /// Processes excluded by pid (the Inkpane app's own windows) aren't named.
    private func excludedApps(in frame: Rect) -> [String] {
        guard !exclusions.bundleIDs.isEmpty else { return [] }
        var names: [String] = []
        for window in WindowList.windows() where exclusions.excludes(bundleID: window.bundleID) {
            guard window.frame.cgRect.intersects(frame.cgRect) else { continue }
            let name = window.appName ?? window.bundleID ?? "?"
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    // MARK: - ScreenCaptureKit plumbing

    private func baseConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    private func shareableContent(onScreenWindowsOnly: Bool = false) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly)
        } catch {
            throw Self.mapError(error)
        }
    }

    private func screenshot(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await Screenshot.capture(filter: filter, configuration: configuration)
        } catch {
            throw Self.mapError(error)
        }
    }

    static func mapError(_ error: any Error) -> InkpaneError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return InkpaneError.permissionDenied()
        }
        return .captureFailed(nsError.localizedDescription)
    }
}
