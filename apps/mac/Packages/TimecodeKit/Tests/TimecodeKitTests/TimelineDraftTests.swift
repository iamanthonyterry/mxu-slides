import Foundation
import Testing
@testable import TimecodeKit

struct TimelineDraftTests {

    /// Frames at 25 fps, as times.
    private func f(_ frames: Int) -> Double { Double(frames) / 25 }

    private func frames(_ draft: TimelineDraft) -> [Int] {
        draft.cues.map { draft.frameIndex($0.time) }
    }

    private func make(_ frameTimes: [Int]) -> (TimelineDraft, [UUID]) {
        let cues = frameTimes.enumerated().map { TimelineDraft.Cue(slideID: "s\($0.offset)", time: f($0.element)) }
        let draft = TimelineDraft(cues: cues, offset: 3_600)
        return (draft, draft.cues.map(\.id))
    }

    @Test func importedTimesSnapToFramesAndSort() {
        let draft = TimelineDraft(cues: [
            .init(slideID: "b", time: 2.013), .init(slideID: "a", time: 0.99),
        ])
        #expect(frames(draft) == [25, 50])
        #expect(draft.cues.map(\.slideID) == ["a", "b"])
    }

    @Test func duplicateFramesAreSeparatedOnLoad() {
        let draft = TimelineDraft(cues: [
            .init(slideID: "a", time: 1), .init(slideID: "b", time: 1.001), .init(slideID: "c", time: 1),
        ])
        #expect(Set(frames(draft)).count == 3, "no two cues share a frame")
        #expect(frames(draft) == [25, 26, 27])
    }

    @Test func nudgeMovesByWholeFrames() {
        var (draft, ids) = make([100, 200, 300])
        draft.nudge([ids[1]], frames: 3)
        #expect(frames(draft) == [100, 203, 300])
        draft.nudge([ids[1]], frames: -10)
        #expect(frames(draft) == [100, 193, 300])
    }

    @Test func movingOntoAnotherCueStepsPastIt() {
        var (draft, ids) = make([100, 110])
        draft.move([ids[0]], by: f(10))
        #expect(frames(draft) == [110, 111], "landed on 110, pushed one frame further right")
        #expect(draft.cues.last?.id == ids[0])
        var (back, backIDs) = make([100, 110])
        back.move([backIDs[1]], by: -f(10))
        #expect(frames(back) == [99, 100], "moving left pushes further left")
    }

    @Test func dragCanPassOtherCues() {
        var (draft, ids) = make([100, 200, 300])
        draft.move([ids[0]], by: f(150))
        #expect(frames(draft) == [200, 250, 300])
        #expect(draft.cues.map(\.id) == [ids[1], ids[0], ids[2]])
    }

    @Test func moveIsClampedAtZero() {
        var (draft, ids) = make([10, 50])
        draft.move(Set(ids), by: -f(100))
        #expect(frames(draft) == [0, 40], "the group stops when its first cue hits zero, spacing kept")
    }

    @Test func rippleMovesEverythingAfter() {
        var (draft, ids) = make([100, 200, 300, 400])
        draft.move([ids[1]], by: f(25), ripple: true)
        #expect(frames(draft) == [100, 225, 325, 425])
    }

    @Test func multiSelectionKeepsSpacing() {
        var (draft, ids) = make([100, 130, 400])
        draft.move([ids[0], ids[1]], by: f(7))
        #expect(frames(draft) == [107, 137, 400])
    }

    @Test func setTimeIsExactAndResolvesCollisions() {
        var (draft, ids) = make([100, 200])
        draft.setTime(ids[1], to: f(100))
        #expect(frames(draft) == [99, 100] || frames(draft) == [100, 101])
        draft.setTime(ids[1], to: 12.345)
        #expect(draft.cue(ids[1])?.time == draft.quantize(12.345))
    }

    @Test func punchReplacesOnlyTheRecordedRange() {
        var (draft, _) = make([100, 200, 300, 400])
        draft.punch(from: f(150), to: f(350), taps: [("x", f(160)), ("y", f(330))])
        #expect(frames(draft) == [100, 160, 330, 400])
        #expect(draft.cues.map(\.slideID) == ["s0", "x", "y", "s3"])
    }

    @Test func snapFindsNearbyCuesAndPlayhead() {
        let (draft, ids) = make([100, 200])
        #expect(draft.snapTarget(for: f(203), excluding: [ids[0]], playhead: nil, threshold: f(5)) == f(200))
        #expect(draft.snapTarget(for: f(203), excluding: [ids[1]], playhead: nil, threshold: f(5)) == nil)
        #expect(draft.snapTarget(for: f(150), excluding: [], playhead: f(152), threshold: f(5)) == f(152))
    }

    @Test func historyUndoesAndRedoesWholeEdits() {
        var (draft, ids) = make([100, 200])
        var history = TimelineHistory(draft)
        history.edit { $0.nudge([ids[0]], frames: 5) }
        history.edit { $0.delete([ids[1]]) }
        history.edit { _ in }
        #expect(frames(history.current) == [105])
        history.undo()
        #expect(frames(history.current) == [105, 200])
        history.undo()
        #expect(frames(history.current) == [100, 200])
        #expect(!history.canUndo, "the no-op edit made no step")
        history.redo()
        #expect(frames(history.current) == [105, 200])
        draft = history.current
        history.edit { $0.add(slideID: "z", at: 1) }
        #expect(!history.canRedo, "a new edit clears redo")
    }

    @Test func recordingAdvancesThroughTheArrangement() {
        let arranged = ["v1", "v2", "ch", "v1", "v2", "ch", "ch"]
        let (draft, _) = make([])
        var pass = TimelineRecording(start: 0, arranged: arranged, existing: draft)
        for (i, t) in [4.0, 12, 20, 36, 44, 52, 60].enumerated() {
            #expect(pass.advance(at: t, arranged: arranged) == arranged[i])
        }
        #expect(pass.advance(at: 70, arranged: arranged) == nil, "past the end of the arrangement")
        let recorded = pass.applied(to: draft, end: 70)
        #expect(recorded.cues.map(\.slideID) == arranged)
    }

    @Test func recordingFromMidSongPicksUpWhereTheCuesLeaveOff() {
        let arranged = ["a", "b", "c", "d"]
        let draft = TimelineDraft(cues: [
            .init(slideID: "a", time: 2), .init(slideID: "b", time: 10), .init(slideID: "c", time: 20),
        ])
        var pass = TimelineRecording(start: 15, arranged: arranged, existing: draft)
        #expect(pass.advance(at: 19, arranged: arranged) == "c", "two cues before 15, so the next is the third")
        #expect(pass.advance(at: 25, arranged: arranged) == "d")
        let result = pass.applied(to: draft, end: 30)
        #expect(result.cues.map(\.slideID) == ["a", "b", "c", "d"])
        #expect(result.cues.map(\.time) == [2, 10, 19, 25])
    }

    @Test func clickingASlideJumpsTheCursor() {
        let arranged = ["v1", "ch", "v2", "ch", "br", "ch"]
        var pass = TimelineRecording(start: 0, arranged: arranged, existing: TimelineDraft(cues: []))
        pass.advance(at: 1, arranged: arranged)
        pass.tap(slideID: "br", at: 5, arranged: arranged)
        #expect(pass.advance(at: 9, arranged: arranged) == "ch", "continues after the bridge")
        pass.tap(slideID: "v1", at: 8, arranged: arranged)
        #expect(pass.taps.count == 3, "a tap earlier than the last one is ignored")
    }

    @Test func emptyPassChangesNothing() {
        let (draft, _) = make([100, 200])
        let pass = TimelineRecording(start: 0, arranged: ["a"], existing: draft)
        #expect(pass.applied(to: draft, end: 30) == draft)
    }
}
