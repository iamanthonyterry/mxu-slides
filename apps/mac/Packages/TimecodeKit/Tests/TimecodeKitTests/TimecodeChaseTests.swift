import Foundation
import Testing
@testable import TimecodeKit

struct TimecodeChaseTests {

    struct Fired: Equatable {
        var at: Double
        var presentation: String
        var slide: String
        var cue: Int
        var occurrence: Int
    }

    /// Hour-per-song: song one at 01:00:00:00, song two at 02:00:00:00.
    let songOne = ChaseTimeline(presentationID: "s1", offset: 3_600, cues: [
        .init(slideID: "chorus", time: 20), .init(slideID: "v1", time: 4),
        .init(slideID: "v2", time: 36), .init(slideID: "chorus", time: 52),
    ])
    let songTwo = ChaseTimeline(presentationID: "s2", offset: 7_200, duration: 240, cues: [
        .init(slideID: "a", time: 0), .init(slideID: "b", time: 10),
    ])

    private func play(
        _ chase: inout TimecodeChase, from label: Double, seconds: Double, startingAt t0: Double, fps: Double = 25
    ) -> [Fired] {
        var fired: [Fired] = []
        for i in 0..<Int(seconds * fps) {
            let dt = Double(i) / fps
            for event in chase.receive(position: label + dt, at: t0 + dt) {
                if case .fire(let p, let s, let c, let o) = event {
                    fired.append(Fired(at: t0 + dt, presentation: p, slide: s, cue: c, occurrence: o))
                }
            }
        }
        return fired
    }

    @Test func firesEachCueOnceInOrder() {
        var chase = TimecodeChase(timelines: [songTwo, songOne])
        let fired = play(&chase, from: 3_600, seconds: 60, startingAt: 0)
        #expect(fired.map(\.slide) == ["v1", "chorus", "v2", "chorus"])
        #expect(fired.map(\.at) == [4, 20, 36, 52])
        #expect(fired.last?.occurrence == 1, "the second chorus is the second occurrence")
    }

    @Test func nextHourSwitchesSongsWithinAFewFrames() {
        var chase = TimecodeChase(timelines: [songOne, songTwo])
        _ = play(&chase, from: 3_600, seconds: 60, startingAt: 0)
        let fired = play(&chase, from: 7_200, seconds: 12, startingAt: 60)
        #expect(fired.map(\.slide) == ["a", "b"])
        #expect(fired.first?.presentation == "s2")
        #expect((fired.first?.at ?? 99) <= 60 + 3.0 / 25 + 1e-9, "a jump is confirmed after three agreeing frames")
    }

    @Test func joiningMidSongLandsOnTheCurrentSlide() {
        var chase = TimecodeChase(timelines: [songOne])
        let fired = play(&chase, from: 3_630, seconds: 2, startingAt: 0)
        #expect(fired.map(\.slide) == ["chorus"])
        #expect(fired.first?.at == 0)
    }

    @Test func aSingleCorruptFrameIsIgnored() {
        var chase = TimecodeChase(timelines: [songOne, songTwo])
        _ = play(&chase, from: 3_600, seconds: 10, startingAt: 0)
        #expect(chase.receive(position: 7_205, at: 10).isEmpty)
        let after = play(&chase, from: 3_610.04, seconds: 2, startingAt: 10.04)
        #expect(after.isEmpty, "still on song one, no refire")
    }

    @Test func dropoutReportsStoppedAndResumeFiresWhereverWeAre() {
        var chase = TimecodeChase(timelines: [songOne])
        _ = play(&chase, from: 3_600, seconds: 25, startingAt: 0)
        #expect(chase.tick(at: 25).isEmpty)
        #expect(chase.tick(at: 26) == [.stopped])
        #expect(chase.tick(at: 27).isEmpty, "reported once")
        let resumed = chase.receive(position: 3_605, at: 30)
        #expect(resumed == [.fire(presentationID: "s1", slideID: "v1", cueIndex: 0, occurrence: 0)])
    }

    @Test func nothingFiresBeforeTheFirstCueOrOutsideAnyWindow() {
        var chase = TimecodeChase(timelines: [songOne])
        #expect(chase.receive(position: 3_601, at: 0).isEmpty)
        var other = TimecodeChase(timelines: [songTwo])
        #expect(other.receive(position: 7_200 + 300, at: 0).isEmpty, "past the song's duration")
        #expect(other.receive(position: 100, at: 1).isEmpty)
    }

    @Test func resyncRefiresTheCurrentCue() {
        var chase = TimecodeChase(timelines: [songOne])
        _ = play(&chase, from: 3_621, seconds: 1, startingAt: 0)
        chase.resync()
        #expect(chase.receive(position: 3_622, at: 1) == [
            .fire(presentationID: "s1", slideID: "chorus", cueIndex: 1, occurrence: 0),
        ])
    }

    @Test func songWindows() {
        let chase = TimecodeChase(timelines: [songOne, songTwo])
        #expect(chase.timeline(containing: 3_599) == nil)
        #expect(chase.timeline(containing: 3_600 + 600)?.presentationID == "s1", "stays live past the last cue")
        #expect(chase.timeline(containing: 3_600 + 52 + 601) == nil, "but not forever")
        #expect(chase.timeline(containing: 7_200)?.presentationID == "s2")

        var crowded = TimecodeChase(timelines: [songOne])
        crowded.timelines.append(ChaseTimeline(presentationID: "s3", offset: 3_660, cues: []))
        #expect(crowded.timeline(containing: 3_659)?.presentationID == "s1")
        #expect(crowded.timeline(containing: 3_660)?.presentationID == "s3", "the next song's offset ends the window")
    }
}
