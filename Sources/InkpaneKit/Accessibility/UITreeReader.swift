import ApplicationServices
import Foundation
import os

public enum AccessibilityPermission {
    /// Whether this process may read other apps' accessibility trees. Does not prompt.
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Throws `InkpaneError.accessibilityPermissionDenied` unless granted. The first failing
    /// call also shows the system prompt, which adds the host app to the Accessibility list.
    public static func require() throws {
        guard !isGranted else { return }
        let shouldPrompt = prompted.withLock { done in
            defer { done = true }
            return !done
        }
        if shouldPrompt {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        throw InkpaneError.accessibilityPermissionDenied(hostApp: HostApp.detect())
    }

    private static let prompted = OSAllocatedUnfairLock(initialState: false)
}

/// Reads the live accessibility tree of a window. Synchronous and potentially slow (bounded by
/// `UITreeOptions.timeLimit`), so call it off the main thread.
public struct UITreeReader: Sendable {
    /// Apps that must not be read (the same list captures use).
    public var exclusions: CaptureExclusions
    public var redaction: RedactionOptions
    /// Per AX call; an app that doesn't answer is skipped quickly.
    public var messagingTimeout: Float

    public init(exclusions: CaptureExclusions = .none, redaction: RedactionOptions = .off, messagingTimeout: Float = 0.5) {
        self.exclusions = exclusions
        self.redaction = redaction
        self.messagingTimeout = messagingTimeout
    }

    public init(policy: CapturePolicy) {
        self.init(exclusions: policy.exclusions, redaction: policy.redaction)
    }

    /// Reads `target`. Throws `InkpaneError.accessibilityPermissionDenied` without permission
    /// (and, when `prompt` is true, shows the system prompt once), `.excludedApp` for excluded
    /// apps, and the usual window-not-found errors.
    public func read(_ target: UITreeTarget, options: UITreeOptions, prompt: Bool = true) throws -> UITreeResult {
        if prompt {
            try AccessibilityPermission.require()
        } else if !AccessibilityPermission.isGranted {
            throw InkpaneError.accessibilityPermissionDenied(hostApp: HostApp.detect())
        }
        let includeOffscreen: Bool = if case .window = target { true } else { false }
        let windows = WindowList.windows(WindowListOptions(includeOffscreen: includeOffscreen))
        let window = try UITreeWindowResolver.resolve(target, windows: windows, exclusions: exclusions)
        guard let element = Self.axWindow(for: window, timeout: messagingTimeout) else {
            throw InkpaneError.captureFailed(
                "\(window.appName ?? "The app") doesn't expose this window to Accessibility (some games, Java apps and custom-drawn UIs don't). Use read_screen_ocr instead.")
        }
        let builder = UITreeBuilder(options: options, redaction: redaction)
        return builder.build(LiveUIElement(element, timeout: messagingTimeout), window: window)
    }

    /// The AX window that matches a window-server window: same frame (within 2 points), then
    /// the same title, then the app's focused or main window.
    static func axWindow(for window: WindowInfo, timeout: Float) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let candidates: [AXUIElement] = LiveUIElement.copy(app, kAXWindowsAttribute) ?? []
        let target = window.frame.cgRect
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 2 }
        let framed = candidates.filter { element in
            guard let frame = LiveUIElement(element, timeout: timeout).frame else { return false }
            return close(frame.minX, target.minX) && close(frame.minY, target.minY)
                && close(frame.width, target.width) && close(frame.height, target.height)
        }
        if framed.count == 1 { return framed[0] }
        let pool = framed.isEmpty ? candidates : framed
        if let title = window.title,
           let titled = pool.first(where: { (LiveUIElement.copy($0, kAXTitleAttribute) as String?) == title }) {
            return titled
        }
        if !framed.isEmpty { return framed[0] }
        if let focused: AXUIElement = LiveUIElement.copy(app, kAXFocusedWindowAttribute) { return focused }
        if let main: AXUIElement = LiveUIElement.copy(app, kAXMainWindowAttribute) { return main }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

/// `UIElement` over a live `AXUIElement`.
struct LiveUIElement: UIElement {
    let element: AXUIElement
    let timeout: Float

    init(_ element: AXUIElement, timeout: Float) {
        self.element = element
        self.timeout = timeout
        AXUIElementSetMessagingTimeout(element, timeout)
    }

    private static let names: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
        kAXSelectedAttribute, kAXPositionAttribute, kAXSizeAttribute,
    ]

    func attributes() -> UIElementAttributes {
        var raw: CFArray?
        // One round trip for every attribute; missing ones come back as AXValue errors.
        guard AXUIElementCopyMultipleAttributeValues(element, Self.names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [AnyObject], values.count == Self.names.count
        else { return UIElementAttributes() }
        func value(_ name: String) -> AnyObject? {
            guard let index = Self.names.firstIndex(of: name) else { return nil }
            let value = values[index]
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
        func string(_ name: String) -> String? { Self.text(value(name)) }
        func bool(_ name: String) -> Bool? {
            guard let value = value(name) else { return nil }
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
            return (value as? NSNumber)?.boolValue
        }
        var frame: Rect?
        if let position = value(kAXPositionAttribute), let size = value(kAXSizeAttribute),
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var extent = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) {
                frame = Rect(CGRect(origin: point, size: extent))
            }
        }
        return UIElementAttributes(
            role: string(kAXRoleAttribute), subrole: string(kAXSubroleAttribute), title: string(kAXTitleAttribute),
            label: string(kAXDescriptionAttribute), value: string(kAXValueAttribute), help: string(kAXHelpAttribute),
            placeholder: string(kAXPlaceholderValueAttribute), identifier: string(kAXIdentifierAttribute),
            enabled: bool(kAXEnabledAttribute), focused: bool(kAXFocusedAttribute), selected: bool(kAXSelectedAttribute), frame: frame)
    }

    func children() -> [any UIElement] {
        let elements: [AXUIElement] = Self.copy(element, kAXChildrenAttribute) ?? []
        return elements.map { LiveUIElement($0, timeout: timeout) }
    }

    func childCount() -> Int {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else { return 0 }
        return count
    }

    var frame: CGRect? {
        guard let position: AXValue = Self.copy(element, kAXPositionAttribute), let size: AXValue = Self.copy(element, kAXSizeAttribute)
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func copy<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Strings, numbers, booleans, attributed strings and URLs as text; anything else
    /// (elements, ranges, points) as `nil`.
    static func text(_ value: AnyObject?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }
}
