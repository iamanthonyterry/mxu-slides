import Foundation
@testable import TimecodeKit

/// Synthesizes LTC audio for tests (biphase-mark, SMPTE 12M bit layout).
enum LTCTestSignal {

    struct Options {
        var amplitude: Float = 0.5
        var noise: Float = 0
        var dcOffset: Float = 0
        /// One-pole smoothing in samples, to mimic real cable/converter slopes.
        var rise: Float = 0
        var dropFrame = false
    }

    static func frameBits(_ tc: Timecode, dropFrame: Bool) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 80)
        func put(_ start: Int, _ value: Int, _ count: Int) {
            for i in 0..<count { bits[start + i] = UInt8((value >> i) & 1) }
        }
        put(0, tc.frames % 10, 4); put(8, tc.frames / 10, 2)
        bits[10] = dropFrame ? 1 : 0
        put(16, tc.seconds % 10, 4); put(24, tc.seconds / 10, 3)
        put(32, tc.minutes % 10, 4); put(40, tc.minutes / 10, 3)
        put(48, tc.hours % 10, 4); put(56, tc.hours / 10, 2)
        let sync: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
        for (i, b) in sync.enumerated() { bits[64 + i] = b }
        if bits.filter({ $0 == 0 }).count % 2 == 1 { bits[27] = 1 }
        return bits
    }

    static func advance(_ tc: Timecode, nominal: Int) -> Timecode {
        var t = tc
        t.frames += 1
        if t.frames >= nominal { t.frames = 0; t.seconds += 1 }
        if t.seconds >= 60 { t.seconds = 0; t.minutes += 1 }
        if t.minutes >= 60 { t.minutes = 0; t.hours += 1 }
        return t
    }

    static func sequence(from start: Timecode, count: Int, nominal: Int) -> [Timecode] {
        var out: [Timecode] = []
        var tc = start
        for _ in 0..<count {
            out.append(tc)
            tc = advance(tc, nominal: nominal)
        }
        return out
    }

    static func encode(
        from start: Timecode, frames count: Int, fps: Double, nominal: Int,
        sampleRate: Double, options: Options = Options()
    ) -> [Float] {
        let bitLength = sampleRate / (80 * fps)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(count) * 80 * bitLength) + 1)
        var level: Float = 1
        var t: Double = 0
        for tc in sequence(from: start, count: count, nominal: nominal) {
            for bit in frameBits(tc, dropFrame: options.dropFrame) {
                level = -level
                let half = Int(t + bitLength / 2)
                while out.count < half { out.append(level) }
                if bit == 1 { level = -level }
                let end = Int(t + bitLength)
                while out.count < end { out.append(level) }
                t += bitLength
            }
        }
        if options.rise > 0 {
            let a = 1 / options.rise
            var y: Float = 0
            for i in out.indices { y += a * (out[i] - y); out[i] = y }
        }
        var rng = SeededRandom(seed: 7)
        return out.map { options.amplitude * $0 + options.dcOffset + options.noise * rng.gaussian() }
    }

    static func decode(_ audio: [Float], sampleRate: Double, chunk: Int = 512) -> [LTCFrame] {
        let decoder = LTCDecoder(sampleRate: sampleRate)
        var frames: [LTCFrame] = []
        var i = 0
        while i < audio.count {
            frames += decoder.push(Array(audio[i..<min(i + chunk, audio.count)]))
            i += chunk
        }
        return frames
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func gaussian() -> Float {
        let u1 = max(unit(), 1e-7), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
