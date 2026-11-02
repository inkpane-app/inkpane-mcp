// Regenerates Tests/InkpaneKitTests/Fixtures/ocr-sample.png.
// Usage: swift Scripts/make-ocr-fixture.swift Tests/InkpaneKitTests/Fixtures/ocr-sample.png
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "ocr-sample.png"
let width = 800
let height = 300
let lines = ["Inkpane OCR Fixture", "你好，世界", "Version 2026"]

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 44, weight: .medium),
    .foregroundColor: NSColor.black,
]
// Line i is drawn with its top at 30 + i*90 px from the top of the image.
for (i, line) in lines.enumerated() {
    let top = 30 + i * 90
    let y = height - top - 56
    (line as NSString).draw(at: NSPoint(x: 40, y: y), withAttributes: attributes)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
