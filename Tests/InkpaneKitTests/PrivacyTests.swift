import CoreGraphics
import Foundation
import Testing
@testable import InkpaneKit

@Suite struct SensitiveTextDetectorTests {
    let detector = SensitiveTextDetector()

    private func kinds(_ text: String) -> [SensitiveMatch.Kind] { detector.matches(in: text).map(\.kind) }
    private func texts(_ text: String) -> [String] { detector.matches(in: text).map(\.text) }

    @Test func findsEmailAddresses() {
        #expect(texts("Contact jane.doe+test@example.co.uk today") == ["jane.doe+test@example.co.uk"])
        #expect(texts("a@b.io, ops@snap-board.dev") == ["a@b.io", "ops@snap-board.dev"])
        #expect(texts("联系邮箱：wang.wei@qq.com") == ["wang.wei@qq.com"])
        #expect(texts("not an email: user@localhost or @handle").isEmpty)
    }

    @Test(arguments: [
        "+1 (415) 555-0132", "415-555-0132", "(415) 555 0132", "+44 20 7946 0958", "+8613812345678",
        "13812345678", "138 1234 5678", "555-1234", "+49 30 901820",
    ])
    func findsPhoneNumbers(number: String) {
        let found = detector.matches(in: "Call \(number) now")
        #expect(found.map(\.kind) == [.phoneNumber], "\(number)")
        #expect(found.first?.text == number)
    }

    @Test(arguments: [
        "2026-10-30", "30.10.2026", "10/30/2026", "192.168.1.100", "v1.2.3.4", "1.2.3", "1234567890123",
        "Build 20261030", "Order 12345", "3.14159265", "12:30:45", "$1,299.00", "ID 4111111111111111",
    ])
    func ignoresThingsThatAreNotPhoneNumbers(text: String) {
        #expect(kinds("Value: \(text)").isEmpty, "\(text)")
    }

    @Test func redactsWithPlaceholders() {
        let text = "Mail bob@example.com or call +1 415 555 0132."
        #expect(detector.redact(text) == "Mail [email] or call [phone].")
        #expect(SensitiveTextDetector(emails: false, phoneNumbers: true).redact(text) == "Mail bob@example.com or call [phone].")
        #expect(SensitiveTextDetector(emails: true, phoneNumbers: false).redact(text) == "Mail [email] or call +1 415 555 0132.")
        #expect(detector.redact("nothing here") == "nothing here")
    }

    @Test func emailDigitsAreNotAlsoPhoneNumbers() {
        #expect(kinds("13812345678@qq.com") == [.email])
    }
}

@Suite struct CaptureExclusionTests {
    private func window(_ id: UInt32, bundle: String?, pid: Int32 = 10) -> WindowInfo {
        WindowInfo(windowID: id, appName: bundle, bundleID: bundle, pid: pid, title: nil, frame: Rect(x: 0, y: 0, width: 100, height: 100),
                   layer: 0, isOnScreen: true, zOrder: Int(id), alpha: 1, displayIndex: 0)
    }

    @Test func matchesBundleIDsCaseInsensitivelyAndProcessIDs() {
        let exclusions = CaptureExclusions(bundleIDs: ["com.1Password.1password"], processIDs: [42], exceptWindowIDs: [7])
        #expect(exclusions.excludes(window(1, bundle: "com.1password.1password")))
        #expect(!exclusions.excludes(window(2, bundle: "com.apple.Safari")))
        #expect(exclusions.excludes(window(3, bundle: "app.inkpane.Inkpane", pid: 42)))
        #expect(!exclusions.excludes(window(7, bundle: "app.inkpane.Inkpane", pid: 42)), "excepted window")
        #expect(!exclusions.excludes(window(4, bundle: nil)))
        #expect(exclusions.filter([window(1, bundle: "com.1password.1password"), window(2, bundle: "x")]).map(\.windowID) == [2])
    }

    @Test func defaultListCoversTheRequiredCategories() {
        let ids = Set(DefaultExclusions.bundleIDs)
        for required in ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords",
                         "com.apple.MobileSMS", "com.tencent.xinWeChat", "ru.keepcoder.Telegram",
                         "org.whispersystems.signal-desktop", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp"] {
            #expect(ids.contains(required), "\(required)")
        }
        #expect(ids.count == DefaultExclusions.entries.count, "no duplicates")
        #expect(DefaultExclusions.name(for: "COM.TINYSPECK.SLACKMACGAP") == "Slack")
    }
}

@Suite struct RedactionTests {
    static func image(width: Int = 100, height: Int = 50) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// RGBA of the pixel at (x, y), top-left origin.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }

    @Test func blackOutUsesTopLeftPixelCoordinates() throws {
        let output = try ImageRedactor.blackOut(Self.image(), pixelRects: [CGRect(x: 10, y: 5, width: 20, height: 10)], padding: 0)
        #expect(Self.pixel(output, 15, 8) == [0, 0, 0, 255])
        #expect(Self.pixel(output, 50, 8) == [255, 255, 255, 255])
        #expect(Self.pixel(output, 15, 40) == [255, 255, 255, 255], "not flipped to the bottom")
    }

    @Test func screenRectsMapIntoImagePixels() throws {
        let frame = Rect(x: 100, y: 200, width: 50, height: 25) // a 2× capture: 100×50 px
        let rect = try #require(ImageRedactor.pixelRect(forScreenRect: Rect(x: 110, y: 205, width: 10, height: 5), imageWidth: 100, imageHeight: 50, frame: frame))
        #expect(rect == CGRect(x: 20, y: 10, width: 20, height: 10))
        #expect(ImageRedactor.pixelRect(forScreenRect: Rect(x: 0, y: 0, width: 10, height: 10), imageWidth: 100, imageHeight: 50, frame: frame) == nil)
        let clipped = try #require(ImageRedactor.pixelRect(forScreenRect: Rect(x: 140, y: 190, width: 100, height: 20), imageWidth: 100, imageHeight: 50, frame: frame))
        #expect(clipped == CGRect(x: 80, y: 0, width: 20, height: 20))
    }

    private func line(_ text: String, pixelBox: CGRect) -> RecognizedText {
        RecognizedText(text: text, confidence: 0.9, normalizedBox: Rect(x: 0, y: 0, width: 0, height: 0), pixelBox: Rect(pixelBox), screenBox: nil)
    }

    @Test func filterBlacksOutMatchesAndRedactsOCRText() throws {
        let capture = Capture(image: Self.image(), kind: .region, frame: Rect(x: 0, y: 0, width: 100, height: 50), scale: 1)
        let lines = [
            line("Mail bob@example.com", pixelBox: CGRect(x: 0, y: 0, width: 100, height: 10)),
            line("Nothing to hide", pixelBox: CGRect(x: 0, y: 20, width: 100, height: 10)),
            line("••••••", pixelBox: CGRect(x: 0, y: 40, width: 30, height: 8)),
        ]
        let policy = CapturePolicy(
            redaction: RedactionOptions(emails: true, phoneNumbers: true, secureFields: true),
            secureFieldRects: [Rect(x: 0, y: 38, width: 40, height: 12)])
        var askedToLocate = false
        let output = try PrivacyFilter.apply(to: capture, policy: policy, wantsOCR: true) { image, frame, locating in
            askedToLocate = locating != nil
            #expect(frame == capture.frame)
            let result = OCRResult(imageWidth: image.width, imageHeight: image.height, languages: ["en-US"], lines: lines)
            // Vision would place "bob@example.com" at the right of the first line.
            return (result, [[Rect(x: 30, y: 0, width: 70, height: 10)], [], []])
        }
        #expect(askedToLocate)
        #expect(output.report.redactedEmails == 1)
        #expect(output.report.redactedSecureFields == 1)
        #expect(output.ocr?.lines.map(\.text) == ["Mail [email]", "Nothing to hide"], "password field text is dropped")
        #expect(Self.pixel(output.capture.image, 50, 5) == [0, 0, 0, 255], "email blacked out")
        #expect(Self.pixel(output.capture.image, 10, 5) == [255, 255, 255, 255], "rest of the line kept")
        #expect(Self.pixel(output.capture.image, 10, 45) == [0, 0, 0, 255], "password field blacked out")
        #expect(Self.pixel(output.capture.image, 50, 25) == [255, 255, 255, 255])
        #expect(output.report.summary?.contains("1 email address(es)") == true)
    }

    @Test func filterWithoutRedactionOnlyRunsOCRWhenAsked() throws {
        let capture = Capture(image: Self.image(), kind: .display, frame: Rect(x: 0, y: 0, width: 100, height: 50), scale: 1)
        var calls = 0
        let none = try PrivacyFilter.apply(to: capture, policy: .unrestricted, wantsOCR: false, excludedApps: ["Slack"]) { _, _, _ in
            calls += 1
            return (OCRResult(imageWidth: 1, imageHeight: 1, languages: [], lines: []), [])
        }
        #expect(calls == 0)
        #expect(none.ocr == nil)
        #expect(none.capture.image === capture.image)
        #expect(none.report.summary == "Privacy: windows of Slack were left out (excluded by the user).")
    }

    @Test func lowConfidenceTextIsStillRedactedButFilteredFromTheOutput() throws {
        let capture = Capture(image: Self.image(), kind: .region, frame: Rect(x: 0, y: 0, width: 100, height: 50), scale: 1)
        var low = line("bob@example.com", pixelBox: CGRect(x: 0, y: 0, width: 60, height: 10))
        low.confidence = 0.3
        let output = try PrivacyFilter.apply(
            to: capture, policy: CapturePolicy(redaction: RedactionOptions(emails: true)), wantsOCR: true, minimumConfidence: 0.9
        ) { image, _, _ in
            (OCRResult(imageWidth: image.width, imageHeight: image.height, languages: [], lines: [low, line("Fine", pixelBox: CGRect(x: 0, y: 20, width: 20, height: 10))]), [[], []])
        }
        #expect(output.report.redactedEmails == 1)
        #expect(Self.pixel(output.capture.image, 5, 5) == [0, 0, 0, 255])
        #expect(output.ocr?.lines.map(\.text) == ["Fine"])
    }

    @Test func wholeLineIsRedactedWhenVisionCannotPlaceTheMatch() throws {
        let capture = Capture(image: Self.image(), kind: .region, frame: Rect(x: 0, y: 0, width: 100, height: 50), scale: 1)
        let output = try PrivacyFilter.apply(to: capture, policy: CapturePolicy(redaction: RedactionOptions(phoneNumbers: true)), wantsOCR: false) { image, _, _ in
            (OCRResult(imageWidth: image.width, imageHeight: image.height, languages: [], lines: [line("Tel 13812345678", pixelBox: CGRect(x: 0, y: 0, width: 60, height: 10))]), [[]])
        }
        #expect(output.report.redactedPhoneNumbers == 1)
        #expect(output.ocr == nil)
        #expect(Self.pixel(output.capture.image, 5, 5) == [0, 0, 0, 255])
    }
}

@Suite struct PrivacyProtocolTests {
    @Test func captureTargetsRoundTrip() throws {
        for target in [CaptureTarget.display(index: 1), .window(id: 77), .app("Safari", titleContains: "Docs"), .region(Rect(x: 1, y: 2, width: 3, height: 4))] {
            let data = try BridgeJSON.encoder().encode(BridgeCaptureTarget(target))
            let decoded = try BridgeJSON.decoder().decode(BridgeCaptureTarget.self, from: data)
            #expect(try decoded.target() == target)
        }
        #expect(throws: BridgeErrorPayload.self) { try BridgeCaptureTarget(kind: .region, rect: Rect(x: 0, y: 0, width: 0, height: 5)).target() }
        #expect(throws: BridgeErrorPayload.self) { try BridgeCaptureTarget(kind: .window).target() }
    }

    @Test func requestsCarryTheClientAndUnknownErrorCodesDecode() throws {
        let request = BridgeRequest(id: "1", token: "t", method: .capture, params: BridgeEmpty(),
                                    client: BridgeClientInfo(name: "claude-code", version: "2.0", via: "inkpane-mcp 0.9.0"))
        let json = String(decoding: try BridgeJSON.encoder().encode(request), as: UTF8.self)
        #expect(json.contains(#""client":{"name":"claude-code","version":"2.0","via":"inkpane-mcp 0.9.0"}"#))
        let header = try BridgeJSON.decoder().decode(BridgeRequestHeader.self, from: Data(json.utf8))
        #expect(header.client?.name == "claude-code")
        // A malformed client field doesn't break the header.
        let odd = try BridgeJSON.decoder().decode(BridgeRequestHeader.self, from: Data(#"{"v":1,"id":"x","client":5}"#.utf8))
        #expect(odd.id == "x" && odd.client == nil)

        let future = Data(#"{"v":1,"id":"1","ok":false,"error":{"code":"from_the_future","message":"m"}}"#.utf8)
        #expect(throws: BridgeClientError.remote(BridgeErrorPayload(.failed, "m"))) { try BridgeClient.decodeResult(future, as: BridgeEmpty.self) }
        let denied = Data(#"{"v":1,"id":"1","ok":false,"error":{"code":"excluded","message":"no"}}"#.utf8)
        #expect(throws: BridgeClientError.remote(BridgeErrorPayload(.excluded, "no"))) { try BridgeClient.decodeResult(denied, as: BridgeEmpty.self) }
    }

    @Test func policiesAndWindowsRoundTripThroughSnakeCaseJSON() throws {
        let policy = CapturePolicy(
            exclusions: CaptureExclusions(bundleIDs: ["com.apple.MobileSMS"], processIDs: [42], exceptWindowIDs: [7]),
            redaction: .all, secureFieldRects: [Rect(x: 1, y: 2, width: 3, height: 4)])
        let json = String(decoding: try BridgeJSON.encoder().encode(policy), as: UTF8.self)
        #expect(json.contains(#""bundle_ids":["com.apple.MobileSMS"]"#))
        #expect(try BridgeJSON.decoder().decode(CapturePolicy.self, from: Data(json.utf8)) == policy)

        let window = WindowInfo(windowID: 9, appName: "A", bundleID: "b.c", pid: 3, title: "T", frame: Rect(x: 0, y: 0, width: 1, height: 1),
                                layer: 0, isOnScreen: true, zOrder: 1, alpha: 1, displayIndex: 0)
        let display = DisplayInfo(index: 0, displayID: 5, frame: Rect(x: 0, y: 0, width: 1, height: 1), pixelWidth: 2, pixelHeight: 2, scale: 2, isMain: true)
        let windowJSON = String(decoding: try BridgeJSON.encoder().encode(window), as: UTF8.self)
        #expect(windowJSON.contains(#""window_id":9"#) && windowJSON.contains(#""bundle_id":"b.c""#))
        #expect(try BridgeJSON.decoder().decode(WindowInfo.self, from: Data(windowJSON.utf8)) == window)
        #expect(try BridgeJSON.decoder().decode(DisplayInfo.self, from: BridgeJSON.encoder().encode(display)) == display)
    }

    @Test func capturedImagesRoundTrip() throws {
        let capture = Capture(image: RedactionTests.image(width: 8, height: 4), kind: .window, frame: Rect(x: 1, y: 2, width: 4, height: 2), scale: 2)
        let wire = try BridgeCapturedImage(capture)
        let back = try wire.capture(excludedApps: ["Slack"])
        #expect(back.image.width == 8 && back.image.height == 4)
        #expect(back.frame == capture.frame && back.scale == 2 && back.kind == .window)
        #expect(back.excludedApps == ["Slack"])
    }
}
