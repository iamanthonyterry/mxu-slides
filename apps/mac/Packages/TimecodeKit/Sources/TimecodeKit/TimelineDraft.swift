import Foundation

/// An editable copy of a presentation timeline.
///
/// Every edit keeps three promises, so the timeline can't drift into a state the
/// chase engine would play ambiguously:
/// - every cue sits exactly on a frame boundary of `rate`,
/// - no cue is before zero,
/// - no two cues share a frame (a collision is pushed one frame further in the
///   direction the edit was moving).
/// Cues stay sorted by time.
public struct TimelineDraft: Equatable, Sendable {

    public struct Cue: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var slideID: String
        public var time: Double

        public init(id: UUID = UUID(), slideID: String, time: Double) {
            self.id = id
            self.slideID = slideID
            self.time = time
        }
    }

    public private(set) var cues: [Cue]
    public var timecodeEnabled: Bool
    /// Timecode label (seconds) of the timeline's zero: 3600 for 01:00:00:00.
    public var offset: Double
    public var duration: Double?
    public var rate: TimecodeRate

    public init(
        cues: [Cue], timecodeEnabled: Bool = true, offset: Double = 0,
        duration: Double? = nil, rate: TimecodeRate = .fps25
    ) {
        self.cues = []
        self.timecodeEnabled = timecodeEnabled
        self.offset = offset
        self.duration = duration
        self.rate = rate
        for cue in cues.sorted(by: { $0.time < $1.time }) {
            var placed = cue
            placed.time = quantize(cue.time)
            self.cues.append(placed)
            resolveCollision(of: placed.id, direction: 1)
        }
    }

    public var frameLength: Double { 1 / Double(rate.nominalFrames) }

    /// Snaps a time to the nearest frame, never below zero.
    public func quantize(_ time: Double) -> Double {
        guard time.isFinite else { return 0 }
        let fps = Double(rate.nominalFrames)
        // Divide rather than multiply by 1/fps: whole frames then come out
        // bit-identical to times typed or computed as frames / fps.
        return (max(0, time) * fps).rounded() / fps
    }

    public func frameIndex(_ time: Double) -> Int {
        Int((time * Double(rate.nominalFrames)).rounded())
    }

    public func cue(_ id: UUID) -> Cue? { cues.first { $0.id == id } }

    /// End of the editable range: the duration, or a bit past the last cue.
    public var visibleLength: Double {
        max(duration ?? 0, (cues.last?.time ?? 0) + 15, 60)
    }

    // MARK: Edits

    @discardableResult
    public mutating func add(slideID: String, at time: Double) -> UUID {
        let cue = Cue(slideID: slideID, time: quantize(time))
        insertSorted(cue)
        resolveCollision(of: cue.id, direction: 1)
        return cue.id
    }

    public mutating func delete(_ ids: Set<UUID>) {
        cues.removeAll { ids.contains($0.id) }
    }

    public mutating func reassign(_ id: UUID, to slideID: String) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        cues[index].slideID = slideID
    }

    /// Puts one cue at an exact time (typed into the inspector).
    public mutating func setTime(_ id: UUID, to time: Double) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let old = cues[index].time
        var cue = cues.remove(at: index)
        cue.time = quantize(time)
        insertSorted(cue)
        resolveCollision(of: id, direction: cue.time >= old ? 1 : -1)
    }

    /// Moves cues by a delta, in whole frames. The delta is clamped so nothing
    /// goes below zero. With `ripple`, every cue after the earliest moved one
    /// moves too, so the rest of the song keeps its spacing.
    public mutating func move(_ ids: Set<UUID>, by delta: Double, ripple: Bool = false) {
        let frames = (delta / frameLength).rounded()
        guard frames != 0 else { return }
        var moving = ids.intersection(cues.map(\.id))
        guard !moving.isEmpty else { return }
        if ripple, let earliest = cues.filter({ moving.contains($0.id) }).map(\.time).min() {
            moving.formUnion(cues.filter { $0.time >= earliest }.map(\.id))
        }
        let lowest = cues.filter { moving.contains($0.id) }.map(\.time).min() ?? 0
        let applied = max(frames * frameLength, -lowest)
        guard applied != 0 else { return }
        for i in cues.indices where moving.contains(cues[i].id) {
            cues[i].time = quantize(cues[i].time + applied)
        }
        cues.sort { $0.time < $1.time }
        // Settle collisions with cues that stayed put, leading edge first.
        let direction: Double = applied > 0 ? 1 : -1
        let order = cues.filter { moving.contains($0.id) }
            .sorted { direction > 0 ? $0.time > $1.time : $0.time < $1.time }
        for cue in order { resolveCollision(of: cue.id, direction: direction) }
    }

    public mutating func nudge(_ ids: Set<UUID>, frames: Int) {
        move(ids, by: Double(frames) * frameLength)
    }

    /// Replaces every cue in `[start, end]` with the given taps — a punch-in
    /// re-record that leaves the rest of the song alone.
    public mutating func punch(from start: Double, to end: Double, taps: [(slideID: String, time: Double)]) {
        let lo = quantize(min(start, end)), hi = quantize(max(start, end))
        cues.removeAll { $0.time >= lo - 1e-9 && $0.time <= hi + 1e-9 }
        for tap in taps.sorted(by: { $0.time < $1.time }) {
            add(slideID: tap.slideID, at: tap.time)
        }
    }

    /// The closest snap target within `threshold` seconds: other cues, the
    /// playhead, or zero. Cues in `excluding` (the ones being dragged) don't count.
    public func snapTarget(
        for time: Double, excluding: Set<UUID>, playhead: Double?, threshold: Double
    ) -> Double? {
        var targets = cues.filter { !excluding.contains($0.id) }.map(\.time)
        if let playhead { targets.append(playhead) }
        targets.append(0)
        let best = targets.min { abs($0 - time) < abs($1 - time) }
        guard let best, abs(best - time) <= threshold else { return nil }
        return quantize(best)
    }

    // MARK: Conversions

    public init(_ timeline: ChaseTimeline, timecodeEnabled: Bool = true, rate: TimecodeRate = .fps25) {
        self.init(
            cues: timeline.cues.map { Cue(slideID: $0.slideID, time: $0.time) },
            timecodeEnabled: timecodeEnabled, offset: timeline.offset,
            duration: timeline.duration, rate: rate)
    }

    // MARK: Internals

    private mutating func insertSorted(_ cue: Cue) {
        let index = cues.firstIndex { $0.time > cue.time } ?? cues.endIndex
        cues.insert(cue, at: index)
    }

    /// If `id` shares a frame with another cue, step it one frame at a time in
    /// `direction` until it's alone (turning around at zero).
    private mutating func resolveCollision(of id: UUID, direction: Double) {
        guard var index = cues.firstIndex(where: { $0.id == id }) else { return }
        var step = direction >= 0 ? 1.0 : -1.0
        var guardCount = 0
        while cues.contains(where: { $0.id != id && frameIndex($0.time) == frameIndex(cues[index].time) }) {
            var cue = cues.remove(at: index)
            var next = cue.time + step * frameLength
            if next < 0 { step = 1; next = cue.time + frameLength }
            cue.time = quantize(next)
            insertSorted(cue)
            index = cues.firstIndex { $0.id == id }!
            guardCount += 1
            if guardCount > 100_000 { break }
        }
    }
}

/// Undo/redo over whole drafts. Snapshots are cheap (a few dozen cues) and can't
/// get out of step with the edits the way inverse operations can.
public struct TimelineHistory: Sendable {
    public private(set) var current: TimelineDraft
    private var past: [TimelineDraft] = []
    private var future: [TimelineDraft] = []
    public var limit = 300

    public init(_ draft: TimelineDraft) { current = draft }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// Records the result of an edit. No-op edits don't create undo steps.
    public mutating func commit(_ next: TimelineDraft) {
        guard next != current else { return }
        past.append(current)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
        current = next
    }

    public mutating func edit(_ change: (inout TimelineDraft) -> Void) {
        var next = current
        change(&next)
        commit(next)
    }

    public mutating func undo() {
        guard let previous = past.popLast() else { return }
        future.append(current)
        current = previous
    }

    public mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(current)
        current = next
    }
}

/// A record pass. Taps are collected live and only touch the draft when the
/// pass ends, as a single punch-in over the recorded range — so an aborted pass
/// changes nothing, and one undo removes the whole pass.
public struct TimelineRecording: Sendable {
    public let start: Double
    public private(set) var taps: [(slideID: String, time: Double)] = []
    /// Position in the arranged slide order the next "advance" tap will place.
    public private(set) var cursor: Int

    /// - Parameters:
    ///   - arranged: slide ids in the song's arranged order (repeats included).
    ///   - existing: the draft being recorded over; the cursor starts after the
    ///     cues already placed before `start`.
    public init(start: Double, arranged: [String], existing: TimelineDraft) {
        self.start = start
        let before = existing.cues.filter { $0.time < start - 1e-9 }.count
        cursor = min(before, arranged.count)
    }

    /// Places the next slide in arranged order. Returns the slide id placed, or
    /// nil past the end of the arrangement.
    @discardableResult
    public mutating func advance(at time: Double, arranged: [String]) -> String? {
        guard cursor < arranged.count else { return nil }
        let slide = arranged[cursor]
        tap(slideID: slide, at: time, arranged: arranged)
        return slide
    }

    /// Places a specific slide (clicked in the list) and moves the cursor to just
    /// after that slide's next appearance in the arrangement.
    public mutating func tap(slideID: String, at time: Double, arranged: [String]) {
        guard time >= start - 1e-9 else { return }
        if let last = taps.last, time < last.time { return }
        taps.append((slideID, time))
        if let found = arranged[min(cursor, arranged.count)...].firstIndex(of: slideID)
            ?? arranged.firstIndex(of: slideID) {
            cursor = found + 1
        }
    }

    public mutating func undoLastTap() {
        guard !taps.isEmpty else { return }
        taps.removeLast()
        cursor = max(0, cursor - 1)
    }

    /// Applies the pass to a draft, replacing cues between `start` and `end`.
    public func applied(to draft: TimelineDraft, end: Double) -> TimelineDraft {
        var next = draft
        guard !taps.isEmpty else { return next }
        next.punch(from: start, to: max(end, taps.last?.time ?? end), taps: taps)
        return next
    }
}
