import CoreGraphics
import Foundation
import MCP
import InkpaneKit

// `diff_screenshots`: what changed between two images (files, library captures, or "now").
// The comparison itself is `ImageDiff` in InkpaneKit.

extension ToolCatalog {
    public static let diffScreenshots = "diff_screenshots"

    static let diffScreenshotsTool = Tool(
        name: diffScreenshots,
        title: "Compare two screenshots",
        description: """
            Find what changed between two screenshots: the changed regions (bounding boxes), the \
            percentage of pixels that changed, and an image of the difference (the newer image \
            faded, changes in red, regions outlined). before and after are image file paths (e.g. \
            from an earlier capture) or screen://assets/{id} library captures; omit after to \
            compare before with a capture taken now (choose it like capture_*: display, window_id, \
            app + title, or x/y/width/height; default the main display). Small anti-aliasing \
            noise is ignored (see threshold). Images with the same aspect ratio but different \
            resolution are compared at the smaller size; other size differences are an error. \
            Boxes are in pixels at the compared size (compared_width × compared_height) and, when \
            the screen area is known (a capture taken now, or frame), \
            in global screen points too; annotate: true then draws them on the user's screen \
            (needs the Inkpane app). \(privacyNote)
            """,
        inputSchema: .object([
            "type": "object",
            "additionalProperties": false,
            "required": ["before"],
            "properties": .object([
                "before": .object(["type": "string", "description": "The earlier image: a file path or screen://assets/{id}."]),
                "after": .object(["type": "string", "description": "The later image: a file path or screen://assets/{id}. Omit to capture now."]),
                "display": .object(["type": "integer", "minimum": 0, "description": "Without after: capture this display (0 = main)."]),
                "window_id": .object(["type": "integer", "minimum": 1, "description": "Without after: capture this window."]),
                "app": .object(["type": "string", "description": "Without after: capture this app's frontmost window."]),
                "title": .object(["type": "string", "description": "With app: only windows whose title contains this text."]),
                "x": .object(["type": "number", "description": "Without after: capture this region (global points)."]),
                "y": .object(["type": "number"]),
                "width": .object(["type": "number"]),
                "height": .object(["type": "number"]),
                "frame": .object([
                    "type": "object", "additionalProperties": false, "required": ["x", "y", "width", "height"],
                    "properties": .object(["x": .object(["type": "number"]), "y": .object(["type": "number"]), "width": .object(["type": "number"]), "height": .object(["type": "number"])]),
                    "description": "The screen area (global points) both images show, e.g. the frame from the capture metadata, so boxes are also given in screen points. Defaults to the frame of a capture taken now.",
                ]),
                "threshold": .object([
                    "type": "number", "minimum": 0, "maximum": 1,
                    "description": .string("How much a colour channel must differ (0-1) for a pixel to count as changed. Default \(ImageDiffOptions.defaultThreshold); 0 counts every difference."),
                ]),
                "include_image": .object(["type": "boolean", "description": "Return the difference image. Default true (it is always saved to disk)."]),
                "max_dimension": .object(["type": "integer", "minimum": 0, "description": .string("Longest edge of the returned difference image in pixels (default \(ArgumentParsing.defaultMaxDimension); 0 = full size).")]),
                "annotate": .object(["type": "boolean", "description": "Draw the changed regions on the user's screen with annotate_screen (needs the Inkpane app and screen coordinates). Default false."]),
                "ttl_seconds": .object(["type": "number", "minimum": 0, "maximum": .double(AnnotateParams.maxTTL), "description": "With annotate: how long the boxes stay. Default 10."]),
            ]),
        ]),
        annotations: Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false))
}

extension ArgumentParsing {
    public enum DiffImageSource: Sendable, Hashable {
        case file(path: String)
        case asset(id: Int64)
        case capture(CaptureTarget)
    }

    public struct DiffRequest: Sendable, Equatable {
        public var before: DiffImageSource
        public var after: DiffImageSource
        public var frame: Rect?
        public var threshold: Double
        public var includeImage: Bool
        public var maxDimension: Int?
        public var annotate: Bool
        public var ttl: Double
    }

    static func diffImageSource(_ args: ToolArguments, _ key: String) throws -> DiffImageSource? {
        guard let value = try args.string(key) else { return nil }
        if value.hasPrefix(ToolCatalog.assetURIPrefix) {
            let id = String(value.dropFirst(ToolCatalog.assetURIPrefix.count))
            guard let number = Int64(id), number > 0 else {
                throw ArgumentError("\(key): \(value) is not a library capture; use screen://assets/{id} with an id from \(ToolCatalog.recentAssetsURI).")
            }
            return .asset(id: number)
        }
        if value.contains("://"), !value.hasPrefix("file://") {
            throw ArgumentError("\(key) must be an image file path or screen://assets/{id}.")
        }
        let path = value.hasPrefix("file://") ? (URL(string: value)?.path ?? value) : value
        return .file(path: (path as NSString).expandingTildeInPath)
    }

    public static func diffScreenshots(_ args: ToolArguments) throws -> DiffRequest {
        try args.rejectUnknown(allowed: ["before", "after", "display", "frame", "threshold", "include_image", "annotate", "ttl_seconds", maxDimensionKey]
            + windowKeys + regionKeys)
        guard let before = try diffImageSource(args, "before") else { throw ArgumentError("before is required (an image path or screen://assets/{id}).") }
        var targets: [CaptureTarget] = []
        if let window = try windowTarget(args) { targets.append(window) }
        if let region = try regionTarget(args) { targets.append(region) }
        if args.has("display") { targets.append(try displayTarget(args)) }
        guard targets.count <= 1 else { throw ArgumentError("Choose one capture target: display, window_id, app or a region (x/y/width/height).") }
        let after: DiffImageSource
        if let given = try diffImageSource(args, "after") {
            guard targets.isEmpty else { throw ArgumentError("display, window_id, app and the region choose what to capture; they can't be combined with after.") }
            after = given
        } else {
            after = .capture(targets.first ?? .display(index: 0))
        }

        var frame: Rect?
        if let value = args.values["frame"] {
            guard let object = value.objectValue else { throw ArgumentError("frame must be an object with x, y, width and height.") }
            let inner = ToolArguments(object)
            try inner.rejectUnknown(allowed: regionKeys)
            guard case .region(let rect)? = try regionTarget(inner) else { throw ArgumentError("frame needs x, y, width and height.") }
            frame = rect
        }
        let threshold = try args.double("threshold") ?? ImageDiffOptions.defaultThreshold
        guard (0...1).contains(threshold) else { throw ArgumentError("threshold must be between 0 and 1.") }
        let ttl = try args.double("ttl_seconds") ?? AnnotateParams.defaultTTL
        guard ttl >= 0, ttl <= AnnotateParams.maxTTL else { throw ArgumentError("ttl_seconds must be between 0 and \(Int(AnnotateParams.maxTTL)).") }
        return DiffRequest(
            before: before, after: after, frame: frame, threshold: threshold, includeImage: try args.bool("include_image") ?? true,
            maxDimension: try maxDimension(args), annotate: try args.bool("annotate") ?? false, ttl: ttl)
    }
}

extension InkpaneTools {
    struct DiffImage {
        var image: CGImage
        var source: String
        var path: String?
        /// Global points the image covers, for captures taken now.
        var frame: Rect?
        var privacy: PrivacyReport?
        var note: String?
    }

    struct DiffSide: Encodable {
        var source: String
        var path: String?
        var pixelWidth: Int
        var pixelHeight: Int
        var frame: Rect?
    }

    struct DiffMetadata: Encodable {
        var before: DiffSide
        var after: DiffSide
        var comparedWidth: Int
        var comparedHeight: Int
        var scaled: Bool?
        var threshold: Double
        var changedPercent: Double
        var changedPixels: Int
        var regions: [ImageDiffRegion]
        var omittedRegions: Int?
        /// The screen area the boxes' `screen_box` refers to.
        var frame: Rect?
        var diffPath: String?
        var annotationIds: [String]?
        var privacy: PrivacyReport?
        var note: String?
    }

    func diffScreenshots(_ request: ArgumentParsing.DiffRequest) async throws -> CallTool.Result {
        let before = try await diffImage(request.before, role: "before")
        let after = try await diffImage(request.after, role: "after")
        var result = try ImageDiff.compare(before.image, after.image, options: ImageDiffOptions(threshold: request.threshold))

        var notes = [before.note, after.note].compactMap { $0 }
        // Only `after` can be a capture taken now; `before` is a file or a library capture.
        let frame = request.frame ?? after.frame
        if let frame {
            result.locate(in: frame)
            if request.frame == nil {
                notes.append("Screen boxes assume before shows the same area as the capture taken now (\(frame.rounded(places: 1))).")
            }
        }

        var diffPath: String?
        var imageContent: Tool.Content?
        if !result.isIdentical {
            let visual = try ImageDiff.visualize(result, over: after.image)
            let png = try ImageUtilities.pngData(visual)
            diffPath = try store.save(png: png, kind: "diff").path
            if request.includeImage {
                let scaled = try ImageUtilities.downscale(visual, maxDimension: request.maxDimension)
                imageContent = Self.image(scaled === visual ? png : try ImageUtilities.pngData(scaled))
            }
        }

        var annotationIDs: [String]?
        if request.annotate {
            let boxes = result.regions.compactMap(\.screenBox).prefix(20)
            if result.isIdentical {
                notes.append("Nothing changed, so nothing was drawn.")
            } else if boxes.isEmpty {
                notes.append("annotate needs screen coordinates: compare against a capture taken now, or pass frame.")
            } else {
                do {
                    let drawn = try await bridge.annotate(AnnotateParams(
                        annotations: boxes.map { BridgeAnnotation.box($0, color: "#FF9500") }, ttl: request.ttl))
                    annotationIDs = drawn.ids
                } catch BridgeClientError.appNotRunning {
                    notes.append("The changed regions were not drawn: annotate needs the Inkpane app, which is not running.")
                } catch {
                    notes.append("The changed regions were not drawn: \(error.localizedDescription)")
                }
            }
        }

        let privacy = [before.privacy, after.privacy].compactMap { $0 }.first { !$0.isEmpty }
        let metadata = DiffMetadata(
            before: DiffSide(source: before.source, path: before.path, pixelWidth: before.image.width, pixelHeight: before.image.height, frame: before.frame),
            after: DiffSide(source: after.source, path: after.path, pixelWidth: after.image.width, pixelHeight: after.image.height, frame: after.frame),
            comparedWidth: result.width, comparedHeight: result.height, scaled: result.scaled ? true : nil,
            threshold: request.threshold, changedPercent: (result.changedPercent * 100).rounded() / 100, changedPixels: result.changedPixels,
            regions: result.regions.map { region in
                var rounded = region
                rounded.pixelBox = region.pixelBox.rounded(places: 0)
                return rounded
            },
            omittedRegions: result.omittedRegions > 0 ? result.omittedRegions : nil, frame: frame, diffPath: diffPath,
            annotationIds: annotationIDs, privacy: privacy, note: notes.isEmpty ? nil : notes.joined(separator: " "))

        var summary: String
        if result.isIdentical {
            summary = "No changes between \(before.source) and \(after.source) (threshold \(request.threshold))."
        } else {
            let percent = result.changedPercent < 0.01 ? "<0.01" : String(format: "%.2f", result.changedPercent)
            let regionCount = result.regions.count + result.omittedRegions
            summary = "\(percent)% of the image changed, in \(regionCount) region(s), between \(before.source) and \(after.source)."
            if let path = diffPath { summary += " Difference image saved to \(path)." }
        }
        if let privacy = privacy?.summary { summary += "\n" + privacy }
        var content: [Tool.Content] = [Self.text(summary + "\n" + JSON.encode(metadata))]
        if let imageContent { content.append(imageContent) }
        return CallTool.Result(content: content, isError: false)
    }

    func diffImage(_ source: ArgumentParsing.DiffImageSource, role: String) async throws -> DiffImage {
        switch source {
        case .file(let path):
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ArgumentError("\(role): no file at \(url.path).") }
            return DiffImage(image: try ImageUtilities.loadImage(at: url), source: url.lastPathComponent, path: url.path)
        case .asset(let id):
            do {
                let result = try await bridge.asset(AssetParams(id: id))
                guard let data = Data(base64Encoded: result.pngBase64), let image = ImageUtilities.decodeImage(data) else {
                    throw BridgeClientError.invalidResponse("asset image is not a valid PNG")
                }
                return DiffImage(
                    image: image, source: "\(ToolCatalog.assetURIPrefix)\(id)", path: result.asset.path,
                    privacy: result.privacy.flatMap { $0.isEmpty ? nil : $0 })
            } catch BridgeClientError.appNotRunning(let path) {
                throw ArgumentError("\(role): library captures (screen://assets) need the Inkpane app, which is not running (nothing is listening on \(path)). Pass a file path instead.")
            }
        case .capture(let target):
            let obtained = try await obtainCapture(target, ocr: nil, tool: ToolCatalog.diffScreenshots)
            let capture = obtained.capture
            let url = try store.save(png: try ImageUtilities.pngData(capture.image), kind: capture.kind.rawValue, date: capture.capturedAt)
            return DiffImage(
                image: capture.image, source: "a capture of \(Self.describe(capture)) taken now", path: url.path, frame: capture.frame,
                privacy: obtained.privacy.flatMap { $0.isEmpty ? nil : $0 }, note: obtained.note)
        }
    }
}
