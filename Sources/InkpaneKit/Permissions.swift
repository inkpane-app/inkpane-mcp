import CoreGraphics
import Darwin
import Foundation
import os

/// The `.app` bundle macOS holds responsible for this process. Privacy (TCC)
/// permissions such as Screen Recording are granted to that app, not to the
/// `inkpane-mcp` binary itself.
public struct HostApp: Codable, Sendable, Hashable {
    public var name: String
    public var bundlePath: String
    public var bundleID: String?

    public init(name: String, bundlePath: String, bundleID: String?) {
        self.name = name
        self.bundlePath = bundlePath
        self.bundleID = bundleID
    }

    /// The closest ancestor process that lives inside an `.app` bundle
    /// (Terminal, iTerm2, Claude, Cursor, ...).
    public static func detect() -> HostApp? {
        detectChain().first
    }

    /// Every distinct `.app` bundle in the parent-process chain, closest first.
    /// Usually the first one is what macOS holds responsible, but an app that
    /// embeds another (e.g. a CLI bundled inside a desktop app) may hand
    /// responsibility to an outer one.
    public static func detectChain() -> [HostApp] {
        detectChain(from: getpid())
    }

    /// Every distinct `.app` bundle in the parent-process chain of `start`, closest first.
    public static func detectChain(from start: pid_t) -> [HostApp] {
        var apps: [HostApp] = []
        var pid = start
        var visited = Set<pid_t>()
        // A tool shipped inside an app (`X.app/Contents/Helpers/inkpane-mcp`) isn't that app:
        // macOS holds whoever launched it responsible. Our own process only counts when it is
        // an app's main executable.
        let countsSelf = Bundle.main.bundleURL.pathExtension == "app"
        while pid > 1, !visited.contains(pid) {
            visited.insert(pid)
            if pid != getpid() || countsSelf,
                let path = executablePath(of: pid), let bundlePath = outermostAppBundle(in: path),
                !apps.contains(where: { $0.bundlePath == bundlePath })
            {
                apps.append(HostApp(bundlePath: bundlePath))
            }
            guard let parent = parentPID(of: pid) else { break }
            pid = parent
        }
        return apps
    }

    init(bundlePath: String) {
        let bundle = Bundle(path: bundlePath)
        let info = bundle?.infoDictionary
        let name =
            (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        self.init(name: name, bundlePath: bundlePath, bundleID: bundle?.bundleIdentifier)
    }

    /// `/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/...`
    /// → `/Applications/Visual Studio Code.app`
    public static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return String(path[path.startIndex..<path.index(range.lowerBound, offsetBy: 4)])
    }

    /// The executable of a process (`proc_pidpath`), if it is visible to this user.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The parent process id (`sysctl KERN_PROC_PID`).
    public static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

public enum ScreenRecordingPermission {
    /// Whether this process may capture screen content. Does not prompt.
    public static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks macOS to show its permission prompt (only shown once per app) and
    /// adds the host app to the Screen Recording list in System Settings.
    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Throws `InkpaneError.screenRecordingPermissionDenied` unless granted.
    /// The first failing call also triggers the system prompt so the host app
    /// shows up in System Settings.
    public static func require() throws {
        guard !isGranted else { return }
        requestOnce()
        throw InkpaneError.permissionDenied()
    }

    private static let requested = OSAllocatedUnfairLock(initialState: false)

    private static func requestOnce() {
        let shouldRequest = requested.withLock { done in
            defer { done = true }
            return !done
        }
        if shouldRequest { request() }
    }
}
