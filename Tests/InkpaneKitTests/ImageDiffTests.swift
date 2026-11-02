import CoreGraphics
import Foundation
import Testing
@testable import InkpaneKit

/// Generated images: a light background with a few shapes, optionally with per-pixel noise.
enum TestImages {
    struct Fill {
        var rect: CGRect  // top-left origin, pixels
        var rgb: (UInt8, UInt8, UInt8)
    }

    static func make(width: Int, height: Int, fills: [Fill] = [], noise: Int = 0, seed: UInt64 = 1) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var random = SplitMix(seed: seed)
        for y in 0..<height {
            for x in 0..<width {
                var rgb: (UInt8, UInt8, UInt8) = (240, 240, 236)
                // Some structure, so scaling and noise have something to act on.
                if (x / 10 + y / 10) % 2 == 0 { rgb = (220, 224, 230) }
                for fill in fills where fill.rect.contains(CGPoint(x: x, y: y)) { rgb = fill.rgb }
                let p = (y * width + x) * 4
                func jitter(_ v: UInt8) -> UInt8 {
                    guard noise > 0 else { return v }
                    let delta = Int(random.next() % UInt64(2 * noise + 1)) - noise
                    return UInt8(clamping: Int(v) + delta)
                }
                pixels[p] = jitter(rgb.0)
                pixels[p + 1] = jitter(rgb.1)
                pixels[p + 2] = jitter(rgb.2)
                pixels[p + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

@Suite struct ImageDiffTests {
    @Test func identicalImagesHaveNoChanges() throws {
        let image = TestImages.make(width: 120, height: 80)
        let result = try ImageDiff.compare(image, image)
        #expect(result.isIdentical)
        #expect(result.regions.isEmpty)
        #expect(result.changedPercent == 0)
        #expect(!result.scaled)
    }

    @Test func smallNoiseIsIgnored() throws {
        let before = TestImages.make(width: 160, height: 100, noise: 0)
        // ±12 per channel everywhere: well under the default threshold (25/255).
        let after = TestImages.make(width: 160, height: 100, noise: 12, seed: 7)
        let result = try ImageDiff.compare(before, after)
        #expect(result.isIdentical)
        // With no threshold at all, the noise counts.
        #expect(try ImageDiff.compare(before, after, options: ImageDiffOptions(threshold: 0)).changedPixels > 1000)
    }

    @Test func isolatedPixelsAreNoise() throws {
        let before = TestImages.make(width: 100, height: 100)
        let after = TestImages.make(width: 100, height: 100, fills: [
            .init(rect: CGRect(x: 10, y: 10, width: 1, height: 1), rgb: (0, 0, 0)),
            .init(rect: CGRect(x: 80, y: 60, width: 1, height: 2), rgb: (0, 0, 0)),
        ])
        #expect(try ImageDiff.compare(before, after).isIdentical)
        #expect(try ImageDiff.compare(before, after, options: ImageDiffOptions(minRegionPixels: 1)).regions.count == 2)
    }

    @Test func findsAChangedRectangle() throws {
        let before = TestImages.make(width: 200, height: 120)
        let after = TestImages.make(width: 200, height: 120, fills: [.init(rect: CGRect(x: 30, y: 40, width: 50, height: 20), rgb: (255, 59, 48))])
        var result = try ImageDiff.compare(before, after)
        #expect(result.regions.count == 1)
        let region = try #require(result.regions.first)
        #expect(region.pixelBox == Rect(x: 30, y: 40, width: 50, height: 20))
        #expect(region.changedPixels == 1000)
        #expect(abs(result.changedPercent - 1000.0 / 24000 * 100) < 0.001)

        // Screen points for an image of a 100 × 60 point area at (500, 300): 2 px per point.
        result.locate(in: Rect(x: 500, y: 300, width: 100, height: 60))
        #expect(result.regions.first?.screenBox == Rect(x: 515, y: 320, width: 25, height: 10))
    }

    @Test func nearbyChangesMergeAndDistantOnesDont() throws {
        let before = TestImages.make(width: 200, height: 200)
        let after = TestImages.make(width: 200, height: 200, fills: [
            .init(rect: CGRect(x: 10, y: 10, width: 20, height: 10), rgb: (0, 0, 0)),
            .init(rect: CGRect(x: 33, y: 10, width: 20, height: 10), rgb: (0, 0, 0)),  // 3 px away: same region
            .init(rect: CGRect(x: 150, y: 150, width: 30, height: 30), rgb: (0, 0, 255)),
        ])
        let result = try ImageDiff.compare(before, after)
        #expect(result.regions.count == 2)
        #expect(result.regions[0].pixelBox == Rect(x: 150, y: 150, width: 30, height: 30), "largest first")
        #expect(result.regions[1].pixelBox == Rect(x: 10, y: 10, width: 43, height: 10))

        let capped = try ImageDiff.compare(before, after, options: ImageDiffOptions(maxRegions: 1))
        #expect(capped.regions.count == 1 && capped.omittedRegions == 1)
        #expect(capped.changedPixels == result.changedPixels)
    }

    @Test func sameShapeDifferentResolutionIsScaled() throws {
        let standard = TestImages.make(width: 200, height: 120, fills: [.init(rect: CGRect(x: 40, y: 40, width: 40, height: 40), rgb: (0, 0, 0))])
        // The same picture at 2x, as a Retina capture of the same area would be.
        let context = try #require(CGContext(
            data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(standard, in: CGRect(x: 0, y: 0, width: 400, height: 240))
        let retina = try #require(context.makeImage())
        let result = try ImageDiff.compare(retina, standard)
        #expect(result.scaled)
        #expect(result.width == 200 && result.height == 120)
        #expect(result.isIdentical, "the same content at another scale isn't a change (\(result.changedPixels) px)")
    }

    @Test func differentShapesAreReported() {
        let a = TestImages.make(width: 200, height: 100)
        let b = TestImages.make(width: 200, height: 150)
        #expect(throws: ImageDiffError.sizeMismatch(beforeWidth: 200, beforeHeight: 100, afterWidth: 200, afterHeight: 150)) {
            try ImageDiff.compare(a, b)
        }
    }

    @Test func visualizationMarksTheChange() throws {
        let before = TestImages.make(width: 100, height: 60)
        let after = TestImages.make(width: 100, height: 60, fills: [.init(rect: CGRect(x: 20, y: 20, width: 20, height: 10), rgb: (0, 0, 255))])
        let result = try ImageDiff.compare(before, after)
        let visual = try ImageDiff.visualize(result, over: after)
        #expect(visual.width == 100 && visual.height == 60)
        let pixels = try ImageDiff.rgba(visual, width: 100, height: 60)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[((y * 100 + x) * 4)..<((y * 100 + x) * 4 + 4)]) }
        let changed = pixel(30, 25)
        #expect(changed[0] > 150 && changed[2] < 120, "changed pixels are red: \(changed)")
        let untouched = pixel(80, 50)
        #expect(untouched[0] > 200 && untouched[1] > 200 && untouched[2] > 200, "the rest is faded: \(untouched)")
    }
}
