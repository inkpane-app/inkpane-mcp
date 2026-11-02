import Foundation

// Screen recording over the bridge (`record_start`, `record_stop`, `record_status`). The app
// records to an MP4 in its captures folder, with the user's on-screen drawings and agent
// annotations burned in, and shows its recording controls (which are not recorded) so the user
// always knows a recording is running and can stop it.

// MARK: - record_start

public struct RecordStartParams: Codable, Sendable, Equatable {
    public enum Target: String, Codable, Sendable, CaseIterable {
        /// A whole display (`displayIndex`, default 0).
        case display
        /// The area of one window (`windowId`), as it is when the recording starts. Whatever
        /// overlaps it is recorded too, including annotations.
        case window
        /// A rectangle in global screen points (`region`).
        case region
    }

    public static let defaultMaxDuration: Double = 300
    public static let maxDurationLimit: Double = 3600
    public static let frameRates = 1...60

    public var target: Target
    /// Index into `DisplayInfo.all()`, for `display`.
    public var displayIndex: Int?
    public var windowId: UInt32?
    public var region: Rect?
    /// Frames per second; the app's setting when omitted.
    public var fps: Int?
    /// Highlight clicks; the app's setting when omitted.
    public var showClicks: Bool?
    /// Show the keys pressed (needs Accessibility permission for the app); the app's setting when omitted.
    public var showKeys: Bool?
    /// Record the mouse pointer; the app's setting when omitted.
    public var showCursor: Bool?
    /// The recording stops by itself after this many seconds (default 300, at most 3600).
    public var maxDuration: Double?
    /// Record the microphone (macOS 15+; needs Microphone permission for the app); the app's
    /// setting when omitted. Apps from before sound ignore it (their result has no `microphone`).
    public var microphone: Bool?
    /// Record what the Mac plays, without the app's own sounds (macOS 15+); the app's setting
    /// when omitted.
    public var systemAudio: Bool?

    public init(
        target: Target = .display, displayIndex: Int? = nil, windowId: UInt32? = nil, region: Rect? = nil, fps: Int? = nil,
        showClicks: Bool? = nil, showKeys: Bool? = nil, showCursor: Bool? = nil, maxDuration: Double? = nil,
        microphone: Bool? = nil, systemAudio: Bool? = nil
    ) {
        self.target = target
        self.displayIndex = displayIndex
        self.windowId = windowId
        self.region = region
        self.fps = fps
        self.showClicks = showClicks
        self.showKeys = showKeys
        self.showCursor = showCursor
        self.maxDuration = maxDuration
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    /// Whether any sound was asked for explicitly.
    public var requestsAudio: Bool { microphone == true || systemAudio == true }

    public var effectiveMaxDuration: Double { maxDuration ?? Self.defaultMaxDuration }

    public func validate() throws(BridgeErrorPayload) {
        func fail(_ message: String) -> BridgeErrorPayload { BridgeErrorPayload(.invalidRequest, message) }
        switch target {
        case .display:
            if let displayIndex, displayIndex < 0 { throw fail("display_index must be >= 0.") }
            if windowId != nil || region != nil { throw fail("A display recording takes only display_index.") }
        case .window:
            guard let windowId, windowId > 0 else { throw fail("A window recording needs window_id.") }
            if displayIndex != nil || region != nil { throw fail("A window recording takes only window_id.") }
        case .region:
            guard let region else { throw fail("A region recording needs region.") }
            guard [region.x, region.y, region.width, region.height].allSatisfy(\.isFinite), region.width >= 16, region.height >= 16 else {
                throw fail("region needs finite values and a size of at least 16×16 points.")
            }
            if displayIndex != nil || windowId != nil { throw fail("A region recording takes only region.") }
        }
        if let fps, !Self.frameRates.contains(fps) { throw fail("fps must be between 1 and 60.") }
        if let maxDuration, !(maxDuration.isFinite && maxDuration > 0 && maxDuration <= Self.maxDurationLimit) {
            throw fail("max_duration must be between 0 and \(Int(Self.maxDurationLimit)) seconds.")
        }
    }
}

public struct RecordStartResult: Codable, Sendable, Equatable {
    /// Pass to `record_stop`.
    public var recordingId: String
    /// The recorded area in global points.
    public var frame: Rect
    public var displayIndex: Int?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fps: Int
    public var showClicks: Bool
    public var showKeys: Bool
    public var maxDuration: Double
    /// Set when a requested option couldn't be honoured (e.g. keys without Accessibility, sound
    /// on macOS 14 or without Microphone permission).
    public var note: String?
    /// Whether the microphone and system audio are recorded. `nil` from apps that can't record
    /// sound at all.
    public var microphone: Bool?
    public var systemAudio: Bool?

    public init(
        recordingId: String, frame: Rect, displayIndex: Int?, pixelWidth: Int, pixelHeight: Int, fps: Int,
        showClicks: Bool, showKeys: Bool, maxDuration: Double, note: String? = nil, microphone: Bool? = nil, systemAudio: Bool? = nil
    ) {
        self.recordingId = recordingId
        self.frame = frame
        self.displayIndex = displayIndex
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.showClicks = showClicks
        self.showKeys = showKeys
        self.maxDuration = maxDuration
        self.note = note
        self.microphone = microphone
        self.systemAudio = systemAudio
    }
}

/// A sound source heard in a recording.
public enum RecordAudioSource: String, Codable, Sendable, CaseIterable {
    case microphone
    case systemAudio = "system_audio"
}

// MARK: - record_stop

public struct RecordStopParams: Codable, Sendable, Equatable {
    /// The recording to stop; omitted means the current one.
    public var recordingId: String?
    /// Also export an animated GIF next to the MP4.
    public var gif: Bool?
    public var gifFps: Int?
    /// Maximum GIF width in pixels.
    public var gifWidth: Int?

    public init(recordingId: String? = nil, gif: Bool? = nil, gifFps: Int? = nil, gifWidth: Int? = nil) {
        self.recordingId = recordingId
        self.gif = gif
        self.gifFps = gifFps
        self.gifWidth = gifWidth
    }

    public func validate() throws(BridgeErrorPayload) {
        if let gifFps, !(1...30).contains(gifFps) { throw BridgeErrorPayload(.invalidRequest, "gif_fps must be between 1 and 30.") }
        if let gifWidth, !(64...3840).contains(gifWidth) { throw BridgeErrorPayload(.invalidRequest, "gif_width must be between 64 and 3840.") }
        if gif != true, gifFps != nil || gifWidth != nil {
            throw BridgeErrorPayload(.invalidRequest, "gif_fps and gif_width need gif: true.")
        }
    }
}

public struct RecordStopResult: Codable, Sendable, Equatable {
    public enum EndReason: String, Codable, Sendable {
        /// `record_stop` ended it.
        case agent
        /// The user pressed Stop (or the hotkey) first.
        case user
        case maxDuration = "max_duration"
        /// Capture stopped by itself (e.g. the display was disconnected); the file has what was
        /// recorded until then.
        case error
    }

    public var recordingId: String
    /// The MP4 in the app's captures folder.
    public var path: String
    /// Seconds, without paused stretches.
    public var duration: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var frameCount: Int
    public var frame: Rect
    public var endedBy: EndReason
    public var gifPath: String?
    /// Why the GIF couldn't be made, if it was asked for.
    public var gifError: String?
    /// What can be heard in the MP4's audio track (one track, mixed); empty or `nil` for a
    /// silent movie. GIFs never have sound.
    public var audio: [RecordAudioSource]?
    /// Set when the user chose "Annotations: Editable track" in the app (agent-started recordings
    /// are always burned in): the marks are in this JSON sidecar next to the MP4 instead of in the
    /// MP4, and the user can edit them and export a version with or without them. `nil` from apps
    /// before W6-2 and for burned-in recordings.
    public var annotationsPath: String?
    /// `true` when the MP4 has no annotations drawn in because they are on an editable track
    /// (`annotations_path`).
    public var annotationsEditable: Bool?

    public init(
        recordingId: String, path: String, duration: Double, pixelWidth: Int, pixelHeight: Int, frameCount: Int,
        frame: Rect, endedBy: EndReason, gifPath: String? = nil, gifError: String? = nil, audio: [RecordAudioSource]? = nil,
        annotationsPath: String? = nil, annotationsEditable: Bool? = nil
    ) {
        self.recordingId = recordingId
        self.path = path
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameCount = frameCount
        self.frame = frame
        self.endedBy = endedBy
        self.gifPath = gifPath
        self.gifError = gifError
        self.audio = audio
        self.annotationsPath = annotationsPath
        self.annotationsEditable = annotationsEditable
    }
}

// MARK: - record_status

public struct RecordStatusResult: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case idle, recording, paused
    }

    public var state: State
    public var recordingId: String?
    /// Seconds recorded so far (paused stretches excluded).
    public var elapsed: Double?
    public var frame: Rect?
    /// Whether an agent (rather than the user) started it.
    public var startedByAgent: Bool?

    public init(state: State, recordingId: String? = nil, elapsed: Double? = nil, frame: Rect? = nil, startedByAgent: Bool? = nil) {
        self.state = state
        self.recordingId = recordingId
        self.elapsed = elapsed
        self.frame = frame
        self.startedByAgent = startedByAgent
    }
}
