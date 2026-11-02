import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import InkpaneKit

@Suite struct CoordinateConversionTests {
    @Test func flipsVisionNormalizedRectToTopLeftOrigin() {
        // Vision: bottom-left origin. A box hugging the top edge has maxY == 1.
        let vision = CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.2)
        let flipped = CoordinateConversion.flipNormalized(vision)
        #expect(flipped.minX == 0.1)
        #expect(abs(flipped.minY - 0) < 1e-9)
        #expect(flipped.width == 0.5)
        #expect(abs(flipped.height - 0.2) < 1e-9)
    }

    @Test func flipIsAnInvolution() {
        let rect = CGRect(x: 0.25, y: 0.1, width: 0.3, height: 0.45)
        let twice = CoordinateConversion.flipNormalized(CoordinateConversion.flipNormalized(rect))
        #expect(abs(twice.minY - rect.minY) < 1e-9)
        #expect(abs(twice.height - rect.height) < 1e-9)
    }

    @Test func normalizedToPixels() {
        let px = CoordinateConversion.normalizedToPixels(
            CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5), imageSize: CGSize(width: 800, height: 400))
        #expect(px == CGRect(x: 400, y: 100, width: 200, height: 200))
    }

    @Test func pixelsToScreenOnRetinaWindow() {
        // A 2x capture of a window at (100, 50) sized 400×300 points → 800×600 px.
        let screen = CoordinateConversion.pixelsToScreen(
            CGRect(x: 200, y: 100, width: 80, height: 40),
            imageSize: CGSize(width: 800, height: 600),
            captureFrame: CGRect(x: 100, y: 50, width: 400, height: 300))
        #expect(screen == CGRect(x: 200, y: 100, width: 40, height: 20))
    }

    @Test func pixelsToScreenOnSecondaryDisplayWithNegativeOrigin() {
        // Display to the left of the main display, 1x.
        let screen = CoordinateConversion.pixelsToScreen(
            CGRect(x: 10, y: 20, width: 30, height: 40),
            imageSize: CGSize(width: 1920, height: 1080),
            captureFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1080))
        #expect(screen == CGRect(x: -1910, y: -180, width: 30, height: 40))
    }

    @Test func pixelsToScreenWithEmptyImageIsNull() {
        let screen = CoordinateConversion.pixelsToScreen(
            CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: .zero, captureFrame: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(screen.isNull)
    }

    @Test func cocoaGlobalRoundTrip() {
        // Main display 1080 points tall; a Cocoa rect at the bottom-left.
        let cocoa = CGRect(x: 10, y: 0, width: 100, height: 80)
        let global = CoordinateConversion.flipCocoaGlobal(cocoa, mainDisplayHeight: 1080)
        #expect(global == CGRect(x: 10, y: 1000, width: 100, height: 80))
        #expect(CoordinateConversion.flipCocoaGlobal(global, mainDisplayHeight: 1080) == cocoa)
    }

    @Test func globalToDisplayLocal() {
        let local = CoordinateConversion.globalToDisplayLocal(
            CGRect(x: 1600, y: 100, width: 50, height: 50), displayFrame: CGRect(x: 1512, y: -300, width: 2560, height: 1440))
        #expect(local == CGRect(x: 88, y: 400, width: 50, height: 50))
    }

    @Test func bestDisplayPicksLargestOverlap() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: 1512, y: -300, width: 2560, height: 1440),
        ]
        // Mostly on the second display.
        #expect(CoordinateConversion.bestDisplayIndex(for: CGRect(x: 1400, y: 0, width: 400, height: 300), displayFrames: displays) == 1)
        // Mostly on the first.
        #expect(CoordinateConversion.bestDisplayIndex(for: CGRect(x: 1200, y: 0, width: 400, height: 300), displayFrames: displays) == 0)
        // Off-screen.
        #expect(CoordinateConversion.bestDisplayIndex(for: CGRect(x: -500, y: 0, width: 100, height: 100), displayFrames: displays) == nil)
    }

    @Test func rectRounding() {
        let rect = Rect(x: 1.23456, y: 2.5, width: 3.14159, height: 0.00004)
        #expect(rect.rounded(places: 2) == Rect(x: 1.23, y: 2.5, width: 3.14, height: 0))
    }
}

@Suite struct ImageUtilitiesTests {
    @Test func targetSizeNeverUpscales() {
        #expect(ImageUtilities.targetSize(width: 800, height: 600, maxDimension: 1568) == (800, 600))
    }

    @Test func targetSizeKeepsAspectRatio() {
        let size = ImageUtilities.targetSize(width: 3024, height: 1964, maxDimension: 1568)
        #expect(size.width == 1568)
        #expect(size.height == 1018)
        let tall = ImageUtilities.targetSize(width: 1000, height: 4000, maxDimension: 1000)
        #expect(tall == (250, 1000))
    }

    @Test func targetSizeWithoutLimit() {
        #expect(ImageUtilities.targetSize(width: 5000, height: 3000, maxDimension: nil) == (5000, 3000))
        #expect(ImageUtilities.targetSize(width: 5000, height: 3000, maxDimension: 0) == (5000, 3000))
    }

    @Test func downscaleAndEncodeFixture() throws {
        let image = try ImageUtilities.loadImage(at: Fixtures.ocrSample)
        let scaled = try ImageUtilities.downscale(image, maxDimension: 400)
        #expect(scaled.width == 400)
        #expect(scaled.height == 150)
        let png = try ImageUtilities.pngData(scaled)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func captureFileNamesAreSortableAndSafe() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        (components.year, components.month, components.day) = (2026, 10, 30)
        (components.hour, components.minute, components.second, components.nanosecond) = (9, 5, 7, 42_000_000)
        let date = try #require(components.date)
        #expect(CaptureStore.fileName(kind: "window", date: date) == "capture-20261030-090507-042-window.png")
        #expect(CaptureStore.fileName(kind: "../evil", date: date) == "capture-20261030-090507-042-evil.png")
        #expect(CaptureStore.fileName(kind: "window", date: date, label: "Safari - Inkpane")
            == "capture-20261030-090507-042-window-Safari - Inkpane.png")
        #expect(CaptureStore.fileName(kind: "area", date: date, label: " \n ") == "capture-20261030-090507-042-area.png")
    }

    @Test func fileLabelsAreSafe() {
        #expect(CaptureStore.fileLabel("../../etc/passwd") == "etc passwd")
        #expect(CaptureStore.fileLabel("a: b?\n\"c\"  <d>|e*\\f") == "a b c d e f")
        #expect(CaptureStore.fileLabel("...hidden") == "hidden")
        #expect(CaptureStore.fileLabel("微信 — 聊天") == "微信 — 聊天")
        #expect(CaptureStore.fileLabel(String(repeating: "长", count: 100))?.count == CaptureStore.maxLabelLength)
        #expect(CaptureStore.fileLabel("/:") == nil)
    }

    @Test func pngMetadataRoundTrips() throws {
        let image = try ImageUtilities.loadImage(at: Fixtures.ocrSample)
        let metadata = ImageMetadata(author: "inkpane.app", software: "Inkpane 1.0")
        let png = try ImageUtilities.pngData(image, metadata: metadata)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(ImageMetadata(properties: properties) == metadata)
        let plain = try #require(CGImageSourceCreateWithData(try ImageUtilities.pngData(image) as CFData, nil))
        #expect(ImageMetadata(properties: CGImageSourceCopyPropertiesAtIndex(plain, 0, nil) as? [CFString: Any] ?? [:]) == nil)
    }

    @Test func storeDoesNotOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkpane-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CaptureStore(directory: dir)
        let date = Date()
        let a = try store.save(png: Data([1]), kind: "display", date: date)
        let b = try store.save(png: Data([2]), kind: "display", date: date)
        #expect(a != b)
        #expect(try Data(contentsOf: a) == Data([1]))
        #expect(try Data(contentsOf: b) == Data([2]))
        // The counter goes before the extension, not after a ".png" inside the label.
        let c = try store.save(png: Data([3]), kind: "window", label: "a.png - Preview", date: date)
        let d = try store.save(png: Data([4]), kind: "window", label: "a.png - Preview", date: date)
        #expect(d.lastPathComponent == c.deletingPathExtension().lastPathComponent + "-2.png")
    }
}

@Suite struct HostAppTests {
    @Test func outermostAppBundle() {
        #expect(
            HostApp.outermostAppBundle(
                in: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
                == "/Applications/Visual Studio Code.app")
        #expect(HostApp.outermostAppBundle(in: "/Applications/iTerm.app/Contents/MacOS/iTerm2") == "/Applications/iTerm.app")
        #expect(HostApp.outermostAppBundle(in: "/Applications/Ghostty.app") == "/Applications/Ghostty.app")
        #expect(HostApp.outermostAppBundle(in: "/opt/homebrew/bin/node") == nil)
        #expect(HostApp.outermostAppBundle(in: "/Users/me/my.application/bin/tool") == nil)
    }

    @Test func permissionMessageNamesTheHostApp() {
        let error = InkpaneError.screenRecordingPermissionDenied(
            hostApp: HostApp(name: "iTerm2", bundlePath: "/Applications/iTerm.app", bundleID: "com.googlecode.iterm2"))
        let message = error.localizedDescription
        #expect(message.contains("\"iTerm2\""))
        #expect(message.contains("Screen & System Audio Recording"))
        #expect(message.contains("/Applications/iTerm.app"))
    }

    @Test func permissionMessageWithoutHostAppStillGuides() {
        let message = InkpaneError.screenRecordingPermissionDenied(hostApp: nil).localizedDescription
        #expect(message.contains("terminal"))
        #expect(message.contains("AI client"))
    }
}

@Suite struct WindowSelectionTests {
    func window(_ id: UInt32, app: String, bundle: String, title: String?, z: Int, layer: Int = 0, onScreen: Bool = true) -> WindowInfo {
        WindowInfo(
            windowID: id, appName: app, bundleID: bundle, pid: 100, title: title,
            frame: Rect(x: 0, y: 0, width: 800, height: 600), layer: layer, isOnScreen: onScreen, zOrder: z, alpha: 1,
            displayIndex: 0)
    }

    @Test func bestWindowPrefersFrontmostAndMatchesBundleID() {
        let windows = [
            window(1, app: "Window Server", bundle: "", title: "Menubar", z: 0, layer: 25),
            window(2, app: "Safari", bundle: "com.apple.Safari", title: "GitHub", z: 1),
            window(3, app: "Safari", bundle: "com.apple.Safari", title: "Docs", z: 2),
        ]
        #expect(WindowList.bestWindow(forApp: "safari", titleContains: nil, in: windows)?.windowID == 2)
        #expect(WindowList.bestWindow(forApp: "com.apple.Safari", titleContains: "docs", in: windows)?.windowID == 3)
        #expect(WindowList.bestWindow(forApp: "Safari", titleContains: "nope", in: windows) == nil)
        #expect(WindowList.frontmostWindow(in: windows)?.windowID == 2)
    }

    @Test func bestWindowSkipsOffscreenWindows() {
        let windows = [
            window(2, app: "Notes", bundle: "com.apple.Notes", title: "A", z: 0, onScreen: false),
            window(3, app: "Notes", bundle: "com.apple.Notes", title: "B", z: 1),
        ]
        #expect(WindowList.bestWindow(forApp: "Notes", titleContains: nil, in: windows)?.windowID == 3)
    }

    @Test func enumerationWorksWithoutPermission() {
        // Must not crash or require Screen Recording; content depends on the machine.
        let windows = WindowList.windows(.init(includeOffscreen: true, includeSystemLayers: true))
        #expect(windows.map(\.zOrder) == windows.map(\.zOrder).sorted())
        let displays = DisplayInfo.all()
        if let first = displays.first { #expect(first.isMain && first.index == 0) }
    }
}
