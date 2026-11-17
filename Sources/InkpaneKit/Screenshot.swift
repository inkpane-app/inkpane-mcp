import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// `SCScreenshotManager` screenshots through its completion-handler API.
///
/// When the process passes the Screen Recording check but can't actually capture (seen with an
/// ad-hoc-signed build reusing a bundle ID whose grant belongs to a differently signed app),
/// ScreenCaptureKit calls the completion handler with neither an image nor an error. Swift's
/// `async` bridge of those methods force-unwraps the image and traps, which `try?` can't catch;
/// here that case throws `ScreenshotError.noImage` instead.
public enum Screenshot {
    public static func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                resume(continuation, image: image, error: error)
            }
        }
    }

    /// The screen as macOS draws it in `rect` (global points), menu shadows included.
    @available(macOS 15.2, *)
    public static func capture(in rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                resume(continuation, image: image, error: error)
            }
        }
    }

    private static func resume(_ continuation: CheckedContinuation<CGImage, any Error>, image: CGImage?, error: (any Error)?) {
        if let image {
            continuation.resume(returning: image)
        } else {
            continuation.resume(throwing: error ?? ScreenshotError.noImage)
        }
    }
}

public enum ScreenshotError: Error, LocalizedError, Sendable {
    /// ScreenCaptureKit returned neither an image nor an error.
    case noImage

    public var errorDescription: String? {
        "ScreenCaptureKit returned no image; this process may not be allowed to record the screen."
    }
}
