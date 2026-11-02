import Foundation
import MCP
import InkpaneKit

/// A tool call failed because of its arguments.
public struct ArgumentError: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Typed, forgiving access to MCP tool arguments. Numbers may arrive as JSON
/// ints, doubles or numeric strings depending on the client.
public struct ToolArguments: Sendable {
    public var values: [String: Value]

    public init(_ values: [String: Value]?) {
        self.values = (values ?? [:]).filter { !$0.value.isNull }
    }

    public func has(_ key: String) -> Bool { values[key] != nil }

    public func rejectUnknown(allowed: [String]) throws {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw ArgumentError(
                "Unknown argument(s): \(unknown.joined(separator: ", ")). Allowed: \(allowed.joined(separator: ", ")).")
        }
    }

    public func string(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let string = value.stringValue else { throw ArgumentError("\(key) must be a string.") }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func double(_ key: String) throws -> Double? {
        guard let value = values[key] else { return nil }
        switch value {
        case .int(let i): return Double(i)
        case .double(let d) where d.isFinite: return d
        case .string(let s):
            if let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
        default: break
        }
        throw ArgumentError("\(key) must be a number.")
    }

    public func int(_ key: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        switch value {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 1e15: return Int(d)
        case .string(let s):
            if let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        default: break
        }
        throw ArgumentError("\(key) must be an integer.")
    }

    public func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        switch value {
        case .bool(let b): return b
        case .string(let s) where ["true", "false"].contains(s.lowercased()): return s.lowercased() == "true"
        default: throw ArgumentError("\(key) must be a boolean.")
        }
    }

    /// Accepts a JSON array of strings or a comma-separated string.
    public func stringArray(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        let items: [String]
        switch value {
        case .array(let array):
            items = try array.map {
                guard let s = $0.stringValue else { throw ArgumentError("\(key) must be an array of strings.") }
                return s
            }
        case .string(let s):
            items = s.split(separator: ",").map(String.init)
        default:
            throw ArgumentError("\(key) must be an array of strings.")
        }
        let cleaned = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Argument parsing for each tool, separate from execution so it can be unit tested.
public enum ArgumentParsing {
    /// Default longest edge, in pixels, for images returned to the client.
    public static let defaultMaxDimension = 1568

    static let maxDimensionKey = "max_dimension"
    static let regionKeys = ["x", "y", "width", "height"]
    static let windowKeys = ["window_id", "app", "title"]

    /// `nil` means "do not downscale".
    public static func maxDimension(_ args: ToolArguments) throws -> Int? {
        guard let value = try args.int(maxDimensionKey) else { return defaultMaxDimension }
        guard value >= 0 else { throw ArgumentError("max_dimension must be >= 0 (0 disables downscaling).") }
        return value == 0 ? nil : value
    }

    public static func captureScreen(_ args: ToolArguments) throws -> CaptureTarget {
        try args.rejectUnknown(allowed: ["display", maxDimensionKey])
        return try displayTarget(args)
    }

    public static func captureWindow(_ args: ToolArguments) throws -> CaptureTarget {
        try args.rejectUnknown(allowed: windowKeys + [maxDimensionKey])
        guard let target = try windowTarget(args) else {
            throw ArgumentError("Provide window_id (from list_windows) or app (app name or bundle id).")
        }
        return target
    }

    public static func captureRegion(_ args: ToolArguments) throws -> CaptureTarget {
        try args.rejectUnknown(allowed: regionKeys + [maxDimensionKey])
        guard let target = try regionTarget(args) else {
            throw ArgumentError("Provide x, y, width and height in global screen points.")
        }
        return target
    }

    public enum OCRSource: Sendable, Hashable {
        case capture(CaptureTarget)
        case image(path: String)
    }

    public struct OCRRequest: Sendable {
        public var source: OCRSource
        public var recognizer: TextRecognizer
        public var includeImage: Bool
        public var includeBoxes: Bool
        public var maxDimension: Int?
    }

    public static func readScreenOCR(_ args: ToolArguments) throws -> OCRRequest {
        try args.rejectUnknown(
            allowed: ["display", "image_path"] + windowKeys + regionKeys + [
                "languages", "recognition_level", "min_confidence", "include_image", "include_boxes", maxDimensionKey,
            ])

        var sources: [OCRSource] = []
        if let path = try args.string("image_path") {
            sources.append(.image(path: (path as NSString).expandingTildeInPath))
        }
        if let window = try windowTarget(args) { sources.append(.capture(window)) }
        if let region = try regionTarget(args) { sources.append(.capture(region)) }
        if args.has("display") { sources.append(.capture(try displayTarget(args))) }
        guard sources.count <= 1 else {
            throw ArgumentError("Choose one target: display, window_id, app, a region (x/y/width/height) or image_path.")
        }
        let source = sources.first ?? .capture(.display(index: 0))

        var recognizer = TextRecognizer()
        if let languages = try args.stringArray("languages") { recognizer.languages = languages }
        if let level = try args.string("recognition_level") {
            guard let parsed = TextRecognizer.Level(rawValue: level.lowercased()) else {
                throw ArgumentError("recognition_level must be \"accurate\" or \"fast\".")
            }
            recognizer.level = parsed
        }
        if let minConfidence = try args.double("min_confidence") {
            guard (0...1).contains(minConfidence) else { throw ArgumentError("min_confidence must be between 0 and 1.") }
            recognizer.minimumConfidence = minConfidence
        }
        return OCRRequest(
            source: source, recognizer: recognizer,
            includeImage: try args.bool("include_image") ?? false,
            includeBoxes: try args.bool("include_boxes") ?? true,
            maxDimension: try maxDimension(args))
    }

    public static func listWindows(_ args: ToolArguments) throws -> WindowListOptions {
        try args.rejectUnknown(allowed: ["app", "include_offscreen", "include_system"])
        return WindowListOptions(
            includeOffscreen: try args.bool("include_offscreen") ?? false,
            includeSystemLayers: try args.bool("include_system") ?? false,
            app: try args.string("app"))
    }

    // MARK: - Shared target parsing

    static func displayTarget(_ args: ToolArguments) throws -> CaptureTarget {
        let index = try args.int("display") ?? 0
        guard index >= 0 else { throw ArgumentError("display must be >= 0 (0 is the main display).") }
        return .display(index: index)
    }

    static func windowTarget(_ args: ToolArguments) throws -> CaptureTarget? {
        let id = try args.int("window_id")
        let app = try args.string("app")
        let title = try args.string("title")
        if id != nil && app != nil { throw ArgumentError("Provide either window_id or app, not both.") }
        if let id {
            guard id > 0, id <= Int(UInt32.max) else { throw ArgumentError("window_id must be a positive window id.") }
            if title != nil { throw ArgumentError("title can only be used together with app.") }
            return .window(id: UInt32(id))
        }
        if let app { return .app(app, titleContains: title) }
        if title != nil { throw ArgumentError("title can only be used together with app.") }
        return nil
    }

    static func regionTarget(_ args: ToolArguments) throws -> CaptureTarget? {
        let present = regionKeys.filter(args.has)
        guard !present.isEmpty else { return nil }
        let missing = regionKeys.filter { !args.has($0) }
        guard missing.isEmpty else {
            throw ArgumentError("A region needs x, y, width and height; missing \(missing.joined(separator: ", ")).")
        }
        let rect = Rect(
            x: try args.double("x")!, y: try args.double("y")!,
            width: try args.double("width")!, height: try args.double("height")!)
        guard rect.width > 0, rect.height > 0 else { throw ArgumentError("width and height must be positive.") }
        return .region(rect)
    }
}
