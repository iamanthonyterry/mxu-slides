import Foundation
import Testing
@testable import TimecodeKit

struct LTCDecoderTests {

    /// Decoded labels must be a contiguous run of the encoded ones. The final frame
    /// never completes (its closing edge belongs to the next frame), so allow a short tail.
    private func expectContiguous(
        _ frames: [LTCFrame], start: Timecode, count: Int, nominal: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let got = frames.map { Timecode(hours: $0.timecode.hours, minutes: $0.timecode.minutes,
                                         seconds: $0.timecode.seconds, frames: $0.timecode.frames) }
        let expected = LTCTestSignal.sequence(from: start, count: count, nominal: nominal)
        #expect(got.count >= count - 2, "decoded \(got.count)/\(count)", sourceLocation: sourceLocation)
        let aligned = (0...2).contains { k in
            k + got.count <= expected.count && Array(expected[k..<(k + got.count)]) == got
        }
        #expect(aligned, "labels are in order with none skipped", sourceLocation: sourceLocation)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var sampleRate: Double
        var fps: Double
        var nominal: Int
        var expectedRate: TimecodeRate
        var amplitude: Float = 0.5
        var noise: Float = 0
        var dc: Float = 0
        var rise: Float = 0
        var drop = false
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "48k 25fps clean", sampleRate: 48_000, fps: 25, nominal: 25, expectedRate: .fps25),
        Case(name: "48k 25fps quiet, noisy, DC offset", sampleRate: 48_000, fps: 25, nominal: 25,
             expectedRate: .fps25, amplitude: 0.05, noise: 0.008, dc: 0.02, rise: 3),
        Case(name: "44.1k 25fps", sampleRate: 44_100, fps: 25, nominal: 25, expectedRate: .fps25, rise: 2),
        Case(name: "48k 24fps", sampleRate: 48_000, fps: 24, nominal: 24, expectedRate: .fps24),
        Case(name: "48k 30fps", sampleRate: 48_000, fps: 30, nominal: 30, expectedRate: .fps30),
        Case(name: "48k 29.97 drop", sampleRate: 48_000, fps: 29.97, nominal: 30,
             expectedRate: .fps2997Drop, drop: true),
        Case(name: "96k 25fps", sampleRate: 96_000, fps: 25, nominal: 25, expectedRate: .fps25, rise: 4),
        Case(name: "48k 25fps running 2% fast", sampleRate: 48_000, fps: 25.5, nominal: 25, expectedRate: .fps25),
    ]

    @Test(arguments: cases)
    func decodesEveryFrameInOrder(_ c: Case) {
        let start = Timecode(hours: 2, minutes: 0, seconds: 59, frames: 20)
        var options = LTCTestSignal.Options()
        options.amplitude = c.amplitude
        options.noise = c.noise
        options.dcOffset = c.dc
        options.rise = c.rise
        options.dropFrame = c.drop
        let audio = LTCTestSignal.encode(
            from: start, frames: 60, fps: c.fps, nominal: c.nominal,
            sampleRate: c.sampleRate, options: options)
        let frames = LTCTestSignal.decode(audio, sampleRate: c.sampleRate)
        expectContiguous(frames, start: start, count: 60, nominal: c.nominal)
        #expect(frames.last?.rate == c.expectedRate)
        #expect(frames.last?.timecode.dropFrame == c.drop)
    }

    @Test func joinsMidStreamWithInvertedPolarity() {
        let sr = 48_000.0
        var audio = LTCTestSignal.encode(
            from: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0), frames: 40, fps: 25,
            nominal: 25, sampleRate: sr, options: .init(rise: 3))
        audio = Array(audio[3_337...]).map { -$0 }
        let frames = LTCTestSignal.decode(audio, sampleRate: sr, chunk: 256)
        #expect(frames.count >= 36, "locks within a couple of frames")
        #expect(frames.first?.timecode.hours == 1)
    }

    @Test func followsAJumpBetweenSongsAcrossSilence() {
        let sr = 48_000.0
        let songOne = LTCTestSignal.encode(
            from: Timecode(hours: 1, minutes: 0, seconds: 30, frames: 10), frames: 25, fps: 25,
            nominal: 25, sampleRate: sr, options: .init(rise: 3))
        let songTwo = LTCTestSignal.encode(
            from: Timecode(hours: 2, minutes: 0, seconds: 0, frames: 0), frames: 25, fps: 25,
            nominal: 25, sampleRate: sr, options: .init(rise: 3))
        let audio = songOne + [Float](repeating: 0, count: 19_200) + songTwo
        let hours = LTCTestSignal.decode(audio, sampleRate: sr, chunk: 256).map(\.timecode.hours)
        #expect(hours.contains(1))
        #expect(hours.filter { $0 == 2 }.count >= 22, "relocks on the new hour almost immediately")
    }

    @Test func neverDecodesFramesFromNoiseHumOrMusic() {
        let sr = 48_000.0
        var rng = SeededRandom(seed: 1)
        let n = Int(sr) * 3
        let noise = (0..<n).map { _ in 0.2 * rng.gaussian() }
        let hum = (0..<n).map { i in Float(0.3 * sin(2 * .pi * 60 * Double(i) / sr)) }
        let tones = (0..<n).map { i in
            Float(0.3 * sin(2 * .pi * 1_000 * Double(i) / sr) + 0.2 * sin(2 * .pi * 997 * Double(i) / sr))
        }
        for signal in [noise, hum, tones] {
            #expect(LTCTestSignal.decode(signal, sampleRate: sr).isEmpty)
        }
    }

    @Test func labelSecondsUseTheNominalRate() {
        let tc = Timecode(hours: 2, minutes: 1, seconds: 3, frames: 15)
        #expect(abs(tc.labelSeconds(rate: .fps25) - 7_263.6) < 1e-9)
        #expect(tc.labelSeconds(rate: .fps2997Drop) == 7_263.5)
        #expect(Timecode(string: "02:00:00:00")?.labelSeconds(rate: .fps25) == 7_200)
        #expect(Timecode(string: "02:00:00;00")?.dropFrame == true)
        #expect(Timecode(string: "25:00:00:00") == nil)
        #expect(tc.description == "02:01:03:15")
    }
}
