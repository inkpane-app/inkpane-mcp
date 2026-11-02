import AppKit
import CoreGraphics

/// An active display. `index` 0 is always the main display.
public struct DisplayInfo: Codable, Sendable, Hashable {
    public var index: Int
    public var displayID: UInt32
    /// Global frame in points.
    public var frame: Rect
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels per point (2 on Retina displays).
    public var scale: Double
    public var isMain: Bool

    // `displayId` so that snake_case JSON (`display_id`) round-trips.
    private enum CodingKeys: String, CodingKey {
        case index, displayID = "displayId", frame, pixelWidth, pixelHeight, scale, isMain
    }

    public init(index: Int, displayID: UInt32, frame: Rect, pixelWidth: Int, pixelHeight: Int, scale: Double, isMain: Bool) {
        self.index = index
        self.displayID = displayID
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.isMain = isMain
    }

    /// Active displays, main display first. Does not require any permission.
    public static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let mainID = CGMainDisplayID()
        // CGGetActiveDisplayList documents the main display as the first entry;
        // sort defensively so index 0 is always the main display.
        let ordered = ids.prefix(Int(count)).sorted { a, b in (a == mainID ? 0 : 1) < (b == mainID ? 0 : 1) }
        return ordered.enumerated().map { index, id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelWidth = mode?.pixelWidth ?? Int(bounds.width)
            let pixelHeight = mode?.pixelHeight ?? Int(bounds.height)
            let scale = bounds.width > 0 ? Double(pixelWidth) / Double(bounds.width) : 1
            return DisplayInfo(
                index: index, displayID: id, frame: Rect(bounds),
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, isMain: id == mainID)
        }
    }
}

/// A window as reported by the window server.
public struct WindowInfo: Codable, Sendable, Hashable {
    public var windowID: UInt32
    public var appName: String?
    public var bundleID: String?
    public var pid: Int32
    /// Window title. `nil` when Screen Recording permission is missing — macOS
    /// hides other apps' window titles without it.
    public var title: String?
    /// Global frame in points.
    public var frame: Rect
    /// Window level. 0 is a normal app window; menus, the Dock, the menu bar
    /// and overlays use other layers.
    public var layer: Int
    public var isOnScreen: Bool
    /// Front-to-back position in the window server's list; lower is closer to
    /// the front. Only comparable within one enumeration, and not contiguous
    /// when system layers are filtered out.
    public var zOrder: Int
    public var alpha: Double
    /// Index of the display that shows most of the window (see `DisplayInfo`).
    public var displayIndex: Int?

    // `windowId`/`bundleId` so that snake_case JSON (`window_id`, `bundle_id`) round-trips.
    private enum CodingKeys: String, CodingKey {
        case windowID = "windowId", appName, bundleID = "bundleId", pid, title, frame, layer, isOnScreen, zOrder, alpha, displayIndex
    }

    public init(
        windowID: UInt32, appName: String?, bundleID: String?, pid: Int32, title: String?, frame: Rect,
        layer: Int, isOnScreen: Bool, zOrder: Int, alpha: Double, displayIndex: Int?
    ) {
        self.windowID = windowID
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.zOrder = zOrder
        self.alpha = alpha
        self.displayIndex = displayIndex
    }

    /// Whether `query` matches this window's app name or bundle id (case-insensitive).
    public func matchesApp(_ query: String) -> Bool {
        let q = query.lowercased()
        return appName?.lowercased() == q || bundleID?.lowercased() == q
    }
}

public struct WindowListOptions: Sendable, Hashable {
    /// Include windows that are minimized, hidden or on another Space.
    public var includeOffscreen: Bool
    /// Include windows outside layer 0 (menu bar, Dock, status items, overlays).
    public var includeSystemLayers: Bool
    /// Only windows whose app name or bundle id equals this (case-insensitive).
    public var app: String?

    public init(includeOffscreen: Bool = false, includeSystemLayers: Bool = false, app: String? = nil) {
        self.includeOffscreen = includeOffscreen
        self.includeSystemLayers = includeSystemLayers
        self.app = app
    }
}

public enum WindowList {
    /// Enumerates windows front to back. Works without Screen Recording
    /// permission, but titles are then `nil` for other apps' windows.
    public static func windows(_ options: WindowListOptions = .init()) -> [WindowInfo] {
        var cgOptions: CGWindowListOption = [.excludeDesktopElements]
        cgOptions.insert(options.includeOffscreen ? .optionAll : .optionOnScreenOnly)
        guard let raw = CGWindowListCopyWindowInfo(cgOptions, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let displayFrames = DisplayInfo.all().map(\.frame.cgRect)
        var bundleIDs: [pid_t: String?] = [:]

        var result: [WindowInfo] = []
        for (zOrder, entry) in raw.enumerated() {
            guard let number = entry[kCGWindowNumber as String] as? Int,
                let pid = entry[kCGWindowOwnerPID as String] as? Int32
            else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            if !options.includeSystemLayers && layer != 0 { continue }

            var frame = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: boundsDict)
            {
                frame = rect
            }
            if bundleIDs[pid] == nil {
                bundleIDs[pid] = .some(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            }
            let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let info = WindowInfo(
                windowID: UInt32(number),
                appName: entry[kCGWindowOwnerName as String] as? String,
                bundleID: bundleIDs[pid] ?? nil,
                pid: pid,
                title: title,
                frame: Rect(frame),
                layer: layer,
                isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
                zOrder: zOrder,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                displayIndex: CoordinateConversion.bestDisplayIndex(for: frame, displayFrames: displayFrames))
            if let app = options.app, !info.matchesApp(app) { continue }
            result.append(info)
        }
        return result
    }

    /// The frontmost normal window: the first on-screen, visible, layer-0
    /// window that is larger than a sliver.
    public static func frontmostWindow(in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { isUserFacing($0) }
    }

    /// The window to capture for an app: its frontmost user-facing window,
    /// optionally filtered by a case-insensitive title substring.
    public static func bestWindow(forApp app: String, titleContains: String?, in windows: [WindowInfo]) -> WindowInfo? {
        windows
            .filter { $0.matchesApp(app) && isUserFacing($0) }
            .filter { window in
                guard let titleContains, !titleContains.isEmpty else { return true }
                return window.title?.localizedCaseInsensitiveContains(titleContains) ?? false
            }
            .min { $0.zOrder < $1.zOrder }
    }

    static func isUserFacing(_ window: WindowInfo) -> Bool {
        window.layer == 0 && window.isOnScreen && window.alpha > 0
            && window.frame.width >= 40 && window.frame.height >= 40
    }
}
