import Foundation
import CoreGraphics

/// A rectangle that encodes to JSON as `{x, y, width, height}`.
///
/// Unless stated otherwise, rectangles in InkpaneKit use the *global screen
/// space* of Core Graphics: units are points, the origin is the top-left corner
/// of the main display, and y grows downward. This is the space used by
/// `CGWindowListCopyWindowInfo`, `CGDisplayBounds` and ScreenCaptureKit.
public struct Rect: Codable, Sendable, Hashable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x), y: Double(rect.origin.y),
            width: Double(rect.size.width), height: Double(rect.size.height))
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Returns a copy with every component rounded to `places` decimal places.
    public func rounded(places: Int) -> Rect {
        let factor = pow(10, Double(places))
        func r(_ v: Double) -> Double { (v * factor).rounded() / factor }
        return Rect(x: r(x), y: r(y), width: r(width), height: r(height))
    }

    public var description: String {
        "(\(x), \(y), \(width)×\(height))"
    }
}

/// Pure conversions between the coordinate spaces InkpaneKit deals with.
public enum CoordinateConversion {
    /// Converts a Vision normalized rectangle (origin bottom-left, 0...1) into a
    /// normalized rectangle with a top-left origin.
    public static func flipNormalized(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a top-left-origin normalized rectangle into image pixel coordinates.
    public static func normalizedToPixels(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * imageSize.width,
            y: rect.minY * imageSize.height,
            width: rect.width * imageSize.width,
            height: rect.height * imageSize.height)
    }

    /// Maps a pixel rectangle inside a captured image back to global screen
    /// points, given the global frame (in points) the image covers.
    public static func pixelsToScreen(_ rect: CGRect, imageSize: CGSize, captureFrame: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .null }
        let sx = captureFrame.width / imageSize.width
        let sy = captureFrame.height / imageSize.height
        return CGRect(
            x: captureFrame.minX + rect.minX * sx,
            y: captureFrame.minY + rect.minY * sy,
            width: rect.width * sx,
            height: rect.height * sy)
    }

    /// Converts between Cocoa (AppKit) screen coordinates — origin at the
    /// bottom-left of the main display, y up — and global Core Graphics
    /// coordinates. The conversion is its own inverse.
    public static func flipCocoaGlobal(_ rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a global rectangle into the local point space of a display.
    public static func globalToDisplayLocal(_ rect: CGRect, displayFrame: CGRect) -> CGRect {
        rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
    }

    /// Picks the display whose frame overlaps `rect` the most. Returns `nil`
    /// when `rect` is entirely off-screen.
    public static func bestDisplayIndex(for rect: CGRect, displayFrames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in displayFrames.enumerated() {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area {
                best = (index, area)
            }
        }
        return best?.index
    }
}
