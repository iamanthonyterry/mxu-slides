import Foundation

/// A presentation's timeline as the chase engine sees it.
public struct ChaseTimeline: Equatable, Sendable {
    public struct Cue: Equatable, Sendable {
        public var slideID: String
        /// Seconds from the start of the timeline.
        public var time: Double
        public init(slideID: String, time: Double) {
            self.slideID = slideID
            self.time = time
        }
    }

    public var presentationID: String
    public var name: String
    /// Timecode label (in seconds) where this timeline's zero sits, e.g. 7200 for 02:00:00:00.
    public var offset: Double
    public var duration: Double?
    public var cues: [Cue]

    public init(presentationID: String, name: String = "", offset: Double, duration: Double? = nil, cues: [Cue]) {
        self.presentationID = presentationID
        self.name = name
        self.offset = offset
        self.duration = duration
        self.cues = cues.sorted { $0.time < $1.time }
    }
}

/// What the chase engine wants the show to do.
public enum ChaseEvent: Equatable, Sendable {
    /// Fire this slide. `occurrence` counts earlier cues in the same timeline that
    /// name the same slide (a repeated chorus is occurrence 1, 2, …), so callers
    /// can pick the matching spot in an arrangement.
    case fire(presentationID: String, slideID: String, cueIndex: Int, occurrence: Int)
    /// Timecode stopped arriving. Nothing is cleared; the last slide stays up.
    case stopped
}

/// Follows incoming timecode and decides which slide should be live.
///
/// The song is the timeline whose window contains the timecode (the hour-per-song
/// layout gives every song its own hour); the slide is the last cue at or before
/// the timecode. Because the decision is "where are we", not "what's next",
/// scrubbing, restarting a track, or joining mid-song all land on the right slide.
///
/// LTC carries no checksum, so a corrupted frame can look like a jump. A position
/// that continues smoothly from the last one is trusted at once; a jump is only
/// believed after `jumpConfirmFrames` frames agree with each other.
public struct TimecodeChase: Sendable {

    /// Kept sorted by offset (ties by id) so equal lists always compare equal.
    public var timelines: [ChaseTimeline] {
        didSet {
            let sorted = Self.ordered(timelines)
            if sorted != timelines { timelines = sorted }
        }
    }

    public static func ordered(_ timelines: [ChaseTimeline]) -> [ChaseTimeline] {
        timelines.sorted { ($0.offset, $0.presentationID) < ($1.offset, $1.presentationID) }
    }

    /// Seconds without a frame before reporting `.stopped`.
    public var dropoutSeconds: Double = 0.5
    /// When a timeline has no duration, how long past its last cue it stays active
    /// (bounded by the next timeline's offset).
    public var tailSeconds: Double = 600
    public var jumpConfirmFrames = 3

    public private(set) var position: Double?
    public private(set) var active: (presentationID: String, cueIndex: Int)?
    public private(set) var isRunning = false

    private var lastFrameAt: Double?
    private var pendingJump: (position: Double, at: Double, count: Int)?

    public init(timelines: [ChaseTimeline] = []) {
        self.timelines = Self.ordered(timelines)
    }

    /// Feed one decoded position (label seconds, already latency-compensated).
    /// `now` is a monotonic clock in seconds.
    public mutating func receive(position label: Double, at now: Double) -> [ChaseEvent] {
        defer { lastFrameAt = now }
        if let previous = position, let last = lastFrameAt, isRunning {
            let predicted = previous + (now - last)
            if abs(label - predicted) > 0.25 {
                if let jump = pendingJump, abs(label - (jump.position + (now - jump.at))) <= 0.25 {
                    pendingJump = (label, now, jump.count + 1)
                } else {
                    pendingJump = (label, now, 1)
                }
                guard let jump = pendingJump, jump.count >= jumpConfirmFrames else {
                    position = predicted
                    return []
                }
            }
        }
        pendingJump = nil
        position = label
        isRunning = true
        return evaluate(label)
    }

    /// Call periodically (e.g. 10×/s) so a dropout is reported.
    public mutating func tick(at now: Double) -> [ChaseEvent] {
        guard isRunning, let last = lastFrameAt, now - last > dropoutSeconds else { return [] }
        isRunning = false
        pendingJump = nil
        return [.stopped]
    }

    /// Forget the current slide so the next frame fires again (e.g. after the
    /// operator takes over or the service changes).
    public mutating func resync() {
        active = nil
    }

    /// The timeline whose window contains a label, if any.
    public func timeline(containing label: Double) -> ChaseTimeline? {
        var match: ChaseTimeline?
        for (i, t) in timelines.enumerated() where t.offset <= label {
            let nextOffset = i + 1 < timelines.count ? timelines[i + 1].offset : .infinity
            let natural = t.duration ?? ((t.cues.last?.time ?? 0) + tailSeconds)
            if label < min(t.offset + natural, nextOffset) { match = t }
        }
        return match
    }

    private mutating func evaluate(_ label: Double) -> [ChaseEvent] {
        guard let t = timeline(containing: label) else { return [] }
        let local = label - t.offset
        guard let index = t.cues.lastIndex(where: { $0.time <= local + 1e-6 }) else { return [] }
        if let active, active.presentationID == t.presentationID, active.cueIndex == index {
            return []
        }
        active = (t.presentationID, index)
        let cue = t.cues[index]
        let occurrence = t.cues[..<index].filter { $0.slideID == cue.slideID }.count
        return [.fire(presentationID: t.presentationID, slideID: cue.slideID, cueIndex: index, occurrence: occurrence)]
    }
}
