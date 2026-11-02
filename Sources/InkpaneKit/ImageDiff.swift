import CoreGraphics
import Foundation

// Compares two screenshots: which areas changed, how much, and a picture of it. Pure image code
// (no screen access), so it works on any two images.
//
// A pixel counts as changed when any channel differs by more than `threshold` (a fraction of
// the full range), which ignores the faint colour shifts of anti-aliasing and compression.
// Changed pixels are grouped into regions on a coarse grid (nearby changes merge into one box);
// regions with fewer than `minRegionPixels` changed pixels are treated as noise.

public struct ImageDiffOptions: Sendable, Hashable {
    public static let defaultThreshold = 0.1

    /// 0–1: how much a channel must differ for a pixel to count as changed.
    public var threshold: Double
    /// Regions with fewer changed pixels than this are ignored as noise.
    public var minRegionPixels: Int
    /// Changes closer than this many pixels end up in the same region.
    public var mergeDistance: Int
    /// At most this many regions are returned (the largest first).
    public var maxRegions: Int

    public init(threshold: Double = defaultThreshold, minRegionPixels: Int = 4, mergeDistance: Int = 8, maxRegions: Int = 50) {
        self.threshold = threshold
        self.minRegionPixels = minRegionPixels
        self.mergeDistance = mergeDistance
        self.maxRegions = maxRegions
    }
}

public struct ImageDiffRegion: Codable, Sendable, Hashable {
    /// In pixels at the compared size (`ImageDiffResult.width` × `height`), top-left origin.
    public var pixelBox: Rect
    public var changedPixels: Int
    /// Global screen points, when the screen area the images show is known.
    public var screenBox: Rect?

    public init(pixelBox: Rect, changedPixels: Int, screenBox: Rect? = nil) {
        self.pixelBox = pixelBox
        self.changedPixels = changedPixels
        self.screenBox = screenBox
    }
}

public struct ImageDiffResult: Sendable {
    /// The size both images were compared at: the smaller one's.
    public var width: Int
    public var height: Int
    /// Whether one image was scaled to the other's size (same aspect ratio, different resolution).
    public var scaled: Bool
    /// Changed pixels in the reported regions and the ones beyond `maxRegions` (noise excluded).
    public var changedPixels: Int
    /// The largest regions, at most `maxRegions`.
    public var regions: [ImageDiffRegion]
    /// Regions beyond `maxRegions`.
    public var omittedRegions: Int
    /// Changed pixels (noise excluded), row by row, for the visualisation.
    var mask: [Bool]

    /// 0–100.
    public var changedPercent: Double {
        let total = width * height
        return total > 0 ? Double(changedPixels) / Double(total) * 100 : 0
    }

    public var isIdentical: Bool { changedPixels == 0 }

    /// Adds `screenBox` to every region, for images that show `frame` (global points).
    public mutating func locate(in frame: Rect) {
        guard width > 0, height > 0 else { return }
        let sx = frame.width / Double(width)
        let sy = frame.height / Double(height)
        for index in regions.indices {
            let box = regions[index].pixelBox
            regions[index].screenBox = Rect(x: frame.x + box.x * sx, y: frame.y + box.y * sy, width: box.width * sx, height: box.height * sy)
                .rounded(places: 1)
        }
    }
}

public enum ImageDiffError: Error, LocalizedError, Sendable, Equatable {
    /// The images have different aspect ratios, so they can't show the same area.
    case sizeMismatch(beforeWidth: Int, beforeHeight: Int, afterWidth: Int, afterHeight: Int)
    case tooLarge(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case .sizeMismatch(let bw, let bh, let aw, let ah):
            "The images have different shapes (\(bw)×\(bh) vs \(aw)×\(ah) pixels), so they can't show the same area. Compare captures of the same window, display or region."
        case .tooLarge(let width, let height):
            "The images are too large to compare (\(width)×\(height) pixels)."
        }
    }
}

public enum ImageDiff {
    /// Larger images are refused (about 8K × 4.5K, i.e. a 6K display at 2x is fine).
    public static let maxPixels = 40_000_000
    /// Grid cell for grouping, in pixels.
    static let cell = 4

    /// Compares `before` with `after`. Images of different resolution but the same aspect ratio
    /// (within a pixel or 1 %) are compared at the smaller one's size (scaling down blurs less
    /// than scaling up); other size differences throw `ImageDiffError.sizeMismatch`.
    public static func compare(_ before: CGImage, _ after: CGImage, options: ImageDiffOptions = .init()) throws -> ImageDiffResult {
        guard after.width > 0, after.height > 0, before.width > 0, before.height > 0 else {
            throw ImageDiffError.sizeMismatch(beforeWidth: before.width, beforeHeight: before.height, afterWidth: after.width, afterHeight: after.height)
        }
        let scaled = before.width != after.width || before.height != after.height
        if scaled {
            // Same shape: `before`'s height at `after`'s width is within a pixel (or 1 %) of `after`'s height.
            let expected = Double(before.height) * Double(after.width) / Double(before.width)
            guard abs(expected - Double(after.height)) <= max(1, Double(after.height) * 0.01) else {
                throw ImageDiffError.sizeMismatch(
                    beforeWidth: before.width, beforeHeight: before.height, afterWidth: after.width, afterHeight: after.height)
            }
        }
        let smaller = before.width * before.height < after.width * after.height ? before : after
        let width = smaller.width, height = smaller.height
        guard width * height <= maxPixels else { throw ImageDiffError.tooLarge(width: width, height: height) }
        let a = try rgba(before, width: width, height: height)
        let b = try rgba(after, width: width, height: height)

        let limit = Int((min(max(options.threshold, 0), 1) * 255).rounded(.down))
        var mask = [Bool](repeating: false, count: width * height)
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var cellCounts = [Int](repeating: 0, count: columns * rows)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for y in 0..<height {
                    let rowCell = (y / cell) * columns
                    for x in 0..<width {
                        let p = (y * width + x) * 4
                        var difference = 0
                        for channel in 0..<4 {
                            let d = abs(Int(pa[p + channel]) - Int(pb[p + channel]))
                            if d > difference { difference = d }
                        }
                        if difference > limit {
                            mask[y * width + x] = true
                            cellCounts[rowCell + x / cell] += 1
                        }
                    }
                }
            }
        }

        // Group changed cells; cells within `mergeDistance` of each other join.
        let reach = max(1, (max(options.mergeDistance, 0) + cell - 1) / cell)
        var component = [Int](repeating: -1, count: columns * rows)
        struct Group { var minX: Int, minY: Int, maxX: Int, maxY: Int, pixels: Int, cells: [Int] }
        var groups: [Group] = []
        for start in cellCounts.indices where cellCounts[start] > 0 && component[start] < 0 {
            let id = groups.count
            var group = Group(minX: .max, minY: .max, maxX: .min, maxY: .min, pixels: 0, cells: [])
            var stack = [start]
            component[start] = id
            while let current = stack.popLast() {
                group.cells.append(current)
                group.pixels += cellCounts[current]
                let cx = current % columns, cy = current / columns
                for ny in max(0, cy - reach)...min(rows - 1, cy + reach) {
                    for nx in max(0, cx - reach)...min(columns - 1, cx + reach) {
                        let neighbor = ny * columns + nx
                        if cellCounts[neighbor] > 0 && component[neighbor] < 0 {
                            component[neighbor] = id
                            stack.append(neighbor)
                        }
                    }
                }
            }
            groups.append(group)
        }

        var kept: [ImageDiffRegion] = []
        var changed = 0
        for group in groups {
            if group.pixels < max(options.minRegionPixels, 1) {
                for index in group.cells { clear(cell: index, columns: columns, width: width, height: height, in: &mask) }
                continue
            }
            var box = group
            for index in group.cells {
                let cx = index % columns, cy = index / columns
                for y in (cy * cell)..<min(height, cy * cell + cell) {
                    for x in (cx * cell)..<min(width, cx * cell + cell) where mask[y * width + x] {
                        box.minX = min(box.minX, x)
                        box.maxX = max(box.maxX, x)
                        box.minY = min(box.minY, y)
                        box.maxY = max(box.maxY, y)
                    }
                }
            }
            changed += group.pixels
            kept.append(ImageDiffRegion(
                pixelBox: Rect(x: Double(box.minX), y: Double(box.minY), width: Double(box.maxX - box.minX + 1), height: Double(box.maxY - box.minY + 1)),
                changedPixels: group.pixels))
        }
        kept.sort { $0.changedPixels != $1.changedPixels ? $0.changedPixels > $1.changedPixels : ($0.pixelBox.y, $0.pixelBox.x) < ($1.pixelBox.y, $1.pixelBox.x) }
        let maxRegions = max(options.maxRegions, 1)
        return ImageDiffResult(
            width: width, height: height, scaled: scaled, changedPixels: changed, regions: Array(kept.prefix(maxRegions)),
            omittedRegions: max(0, kept.count - maxRegions), mask: mask)
    }

    private static func clear(cell index: Int, columns: Int, width: Int, height: Int, in mask: inout [Bool]) {
        let cx = index % columns, cy = index / columns
        for y in (cy * cell)..<min(height, cy * cell + cell) {
            for x in (cx * cell)..<min(width, cx * cell + cell) { mask[y * width + x] = false }
        }
    }

    /// `after` faded, with changed pixels in red and each region outlined.
    public static func visualize(_ result: ImageDiffResult, over after: CGImage) throws -> CGImage {
        let width = result.width, height = result.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw InkpaneError.imageEncodingFailed }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(after, in: bounds)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.6))
        context.fill(bounds)

        // Changed pixels: premultiplied red at 80 %.
        var overlay = [UInt8](repeating: 0, count: width * height * 4)
        for index in result.mask.indices where result.mask[index] {
            overlay[index * 4] = 204
            overlay[index * 4 + 3] = 204
        }
        let provider = CGDataProvider(data: Data(overlay) as CFData)
        if let provider, let mask = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent) {
            context.draw(mask, in: bounds)
        }

        let line = max(2, CGFloat(max(width, height)) / 500)
        context.setStrokeColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.setLineWidth(line)
        for region in result.regions {
            let box = region.pixelBox
            // Core Graphics contexts have a bottom-left origin.
            let rect = CGRect(x: box.x, y: Double(height) - box.y - box.height, width: box.width, height: box.height)
            context.stroke(rect.insetBy(dx: -line, dy: -line))
        }
        guard let image = context.makeImage() else { throw InkpaneError.imageEncodingFailed }
        return image
    }

    /// `image` as premultiplied sRGB RGBA bytes at `width` × `height`, top row first.
    static func rgba(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw InkpaneError.imageEncodingFailed }
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = image.width == width && image.height == height ? .none : .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw InkpaneError.imageEncodingFailed }
        return bytes
    }
}
