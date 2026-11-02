import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageUtilities {
    /// The pixel size an image should be scaled to so its longer edge is at
    /// most `maxDimension`. Never upscales; `nil` or `<= 0` means no limit.
    public static func targetSize(width: Int, height: Int, maxDimension: Int?) -> (width: Int, height: Int) {
        guard let maxDimension, maxDimension > 0, width > 0, height > 0 else { return (width, height) }
        let longest = max(width, height)
        guard longest > maxDimension else { return (width, height) }
        let factor = Double(maxDimension) / Double(longest)
        return (
            max(1, Int((Double(width) * factor).rounded())),
            max(1, Int((Double(height) * factor).rounded()))
        )
    }

    /// Returns `image` downscaled so its longer edge is at most `maxDimension`.
    public static func downscale(_ image: CGImage, maxDimension: Int?) throws -> CGImage {
        let size = targetSize(width: image.width, height: image.height, maxDimension: maxDimension)
        guard size.width != image.width || size.height != image.height else { return image }
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace.model == .rgb ? colorSpace : CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw InkpaneError.imageEncodingFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { throw InkpaneError.imageEncodingFailed }
        return scaled
    }

    /// PNG data, with `metadata` written as text chunks when given.
    public static func pngData(_ image: CGImage, metadata: ImageMetadata? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw InkpaneError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, metadata.map { $0.properties(for: .png) as CFDictionary })
        guard CGImageDestinationFinalize(destination) else { throw InkpaneError.imageEncodingFailed }
        return data as Data
    }

    public static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw InkpaneError.imageLoadFailed(path: url.path) }
        return image
    }

    /// Decodes PNG (or any ImageIO format) data.
    public static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Who made an image, stored in the file: PNG `Author` and `Software` text chunks; for other
/// formats the TIFF `Artist` and `Software` tags plus IPTC `By-line` and `Originating Program`
/// (ImageIO writes no TIFF tags into a JPEG, but keeps IPTC). Finder's Get Info and Preview's
/// inspector show them.
public struct ImageMetadata: Sendable, Hashable {
    public var author: String?
    public var software: String?

    public init(author: String? = nil, software: String? = nil) {
        self.author = author
        self.software = software
    }

    /// The `CGImageDestinationAddImage` properties for an image of `type`.
    public func properties(for type: UTType) -> [CFString: Any] {
        var fields: [CFString: Any] = [:]
        if type.conforms(to: .png) {
            if let author { fields[kCGImagePropertyPNGAuthor] = author }
            if let software { fields[kCGImagePropertyPNGSoftware] = software }
            return fields.isEmpty ? [:] : [kCGImagePropertyPNGDictionary: fields]
        }
        var iptc: [CFString: Any] = [:]
        if let author {
            fields[kCGImagePropertyTIFFArtist] = author
            iptc[kCGImagePropertyIPTCByline] = [author]
        }
        if let software {
            fields[kCGImagePropertyTIFFSoftware] = software
            iptc[kCGImagePropertyIPTCOriginatingProgram] = software
        }
        return fields.isEmpty ? [:] : [kCGImagePropertyTIFFDictionary: fields, kCGImagePropertyIPTCDictionary: iptc]
    }

    /// Reads it back from `CGImageSourceCopyPropertiesAtIndex` output; `nil` if neither is set.
    public init?(properties: [CFString: Any]) {
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let author = png[kCGImagePropertyPNGAuthor] as? String ?? tiff[kCGImagePropertyTIFFArtist] as? String
            ?? (iptc[kCGImagePropertyIPTCByline] as? [String])?.first
        let software = png[kCGImagePropertyPNGSoftware] as? String ?? tiff[kCGImagePropertyTIFFSoftware] as? String
            ?? iptc[kCGImagePropertyIPTCOriginatingProgram] as? String
        guard author != nil || software != nil else { return nil }
        self.init(author: author, software: software)
    }
}

/// Writes captures to disk so the user (and the agent) can refer to them later.
public struct CaptureStore: Sendable {
    public var directory: URL

    /// Defaults to `$TMPDIR/inkpane-mcp`.
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("inkpane-mcp", isDirectory: true)
    }

    /// `capture-20261030-142501-123-window.png`, or with a `label` (what was captured, see
    /// `fileLabel(_:)`) `capture-20261030-142501-123-window-Safari.png`.
    public static func fileName(kind: String, date: Date, label: String? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let millis = (c.nanosecond ?? 0) / 1_000_000
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d-%03d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis)
        let safeKind = kind.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let suffix = label.flatMap(fileLabel).map { "-\($0)" } ?? ""
        return "capture-\(stamp)-\(safeKind)\(suffix).png"
    }

    /// The longest label `fileLabel(_:)` returns, in characters.
    public static let maxLabelLength = 60

    /// `text` made safe for a file name: no path separators, colons or control characters,
    /// spaces collapsed, no leading dots, at most `maxLabelLength` characters. `nil` if nothing
    /// is left.
    public static func fileLabel(_ text: String) -> String? {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { unsafe.contains($0) ? " " : $0 }))
        var label = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        label = String(label.drop { $0 == "." || $0 == " " })
        label = String(label.prefix(maxLabelLength)).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    /// Saves PNG data and returns the file URL. Adds a numeric suffix rather
    /// than overwrite an existing file.
    public func save(png: Data, kind: String, label: String? = nil, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.fileName(kind: kind, date: date, label: label)
        let stem = (name as NSString).deletingPathExtension
        var url = directory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            counter += 1
            url = directory.appendingPathComponent("\(stem)-\(counter).png")
        }
        try png.write(to: url, options: .atomic)
        return url
    }
}
