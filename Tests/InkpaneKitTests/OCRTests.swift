import Foundation
import Testing

@testable import InkpaneKit

enum Fixtures {
    static let ocrSample = Bundle.module.url(forResource: "ocr-sample", withExtension: "png", subdirectory: "Fixtures")!
}

/// Uses `Fixtures/ocr-sample.png` (800×300 px, see Scripts/make-ocr-fixture.swift):
/// three lines whose tops sit at 30, 120 and 210 px.
@Suite struct OCRTests {
    @Test func recognizesEnglishAndChinese() throws {
        let image = try ImageUtilities.loadImage(at: Fixtures.ocrSample)
        let result = try TextRecognizer().recognize(image)
        #expect(result.imageWidth == 800)
        #expect(result.imageHeight == 300)
        let text = result.text.replacingOccurrences(of: " ", with: "")
        #expect(text.contains("InkpaneOCRFixture"))
        #expect(text.contains("你好"))
        #expect(text.contains("世界"))
        #expect(text.contains("Version2026"))
        #expect(result.lines.allSatisfy { $0.screenBox == nil })
    }

    @Test func boxesAreTopLeftOriginAndOrdered() throws {
        let image = try ImageUtilities.loadImage(at: Fixtures.ocrSample)
        let result = try TextRecognizer().recognize(image)
        let first = try #require(result.lines.first { $0.text.contains("Fixture") })
        let last = try #require(result.lines.first { $0.text.contains("2026") })
        // Top-left origin: the first line is near the top of the image.
        #expect(first.pixelBox.y < 80)
        #expect(last.pixelBox.y > 180)
        #expect(first.pixelBox.x > 20 && first.pixelBox.x < 60)
        #expect(abs(first.normalizedBox.y - first.pixelBox.y / 300) < 0.001)
        #expect(abs(first.normalizedBox.x - first.pixelBox.x / 800) < 0.001)
    }

    @Test func screenBoxesMapThroughCaptureFrame() throws {
        let image = try ImageUtilities.loadImage(at: Fixtures.ocrSample)
        // Pretend the image is a 2x capture of a 400×150 pt window at (1000, 200).
        let frame = Rect(x: 1000, y: 200, width: 400, height: 150)
        let result = try TextRecognizer().recognize(image, captureFrame: frame)
        let line = try #require(result.lines.first { $0.text.contains("2026") })
        let screen = try #require(line.screenBox)
        #expect(abs(screen.x - (1000 + line.pixelBox.x / 2)) < 0.001)
        #expect(abs(screen.y - (200 + line.pixelBox.y / 2)) < 0.001)
        #expect(abs(screen.width - line.pixelBox.width / 2) < 0.001)
    }

    @Test func minimumConfidenceFilters() throws {
        let image = try ImageUtilities.loadImage(at: Fixtures.ocrSample)
        let result = try TextRecognizer(minimumConfidence: 1.01).recognize(image)
        #expect(result.lines.isEmpty)
    }

    @Test func rejectsUnknownLanguage() throws {
        let image = try ImageUtilities.loadImage(at: Fixtures.ocrSample)
        #expect(throws: InkpaneError.self) {
            try TextRecognizer(languages: ["xx-NOPE"]).recognize(image)
        }
    }

    @Test func defaultLanguagesAreSupported() {
        let supported = TextRecognizer.supportedLanguages()
        for language in TextRecognizer.defaultLanguages {
            #expect(supported.contains(language))
        }
    }
}
