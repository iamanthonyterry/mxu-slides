import Foundation

/// A decoded LTC frame.
public struct LTCFrame: Equatable, Sendable {
    public var timecode: Timecode
    /// Frame rate measured from the bit clock (tracks vari-speed).
    public var measuredFPS: Double
    /// Index into the buffer passed to `push` where this frame's last bit ended.
    /// The label refers to the start of the frame, so the label was current one
    /// frame-length before this point.
    public var sampleIndex: Int

    public var rate: TimecodeRate {
        TimecodeRate.nearest(measured: measuredFPS, dropFlag: timecode.dropFrame)
    }
}

/// Decodes SMPTE 12M linear timecode from mono audio samples.
///
/// LTC is biphase-mark coded: the level flips at every bit boundary, and a 1 bit
/// flips again mid-bit. So the decoder only measures the spacing of level changes:
/// one full bit-period is a 0, two half-periods are a 1. The bit-period estimate
/// adapts continuously, so it locks to 24/25/29.97/30 fps at any sample rate and
/// follows vari-speed. A frame is accepted only when the 16-bit sync word closes
/// it and every BCD field is in range, which keeps noise, hum and music from ever
/// producing a frame.
///
/// Not thread-safe; feed it from one audio thread.
public final class LTCDecoder {
    private static let sync: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]

    public let sampleRate: Double

    private var period: Double = 0
    private var previous: Float = 0
    private var level: Int = 0
    private var sinceEdge: Double = 0
    private var halfPending = false
    private var bits: [UInt8] = []
    private var peak: Float = 0
    private var dc: Float = 0
    private var lockedFrames = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        bits.reserveCapacity(81)
        reset()
    }

    /// True after a few consecutive valid frames.
    public var isLocked: Bool { lockedFrames >= 2 }

    /// Peak input level (0…1) after DC removal, for a signal meter.
    public var inputPeak: Float { peak }

    public func reset() {
        period = sampleRate / 2000
        previous = 0
        level = 0
        sinceEdge = 0
        halfPending = false
        bits.removeAll(keepingCapacity: true)
        peak = 0
        dc = 0
        lockedFrames = 0
    }

    public func push(_ samples: [Float]) -> [LTCFrame] {
        samples.withUnsafeBufferPointer { push($0) }
    }

    public func push(_ samples: UnsafeBufferPointer<Float>) -> [LTCFrame] {
        var frames: [LTCFrame] = []
        for (index, x) in samples.enumerated() {
            dc += (x - dc) * 0.0005
            let v = x - dc
            peak = max(abs(v), peak * 0.9995)
            let threshold = max(peak * 0.2, 0.002)
            sinceEdge += 1
            var next = level
            if v > threshold {
                next = 1
            } else if v < -threshold {
                next = -1
            }
            if next != level, level != 0 {
                let edge = next == 1 ? threshold : -threshold
                var fraction: Double = 0
                if v != previous {
                    fraction = min(max(Double((v - edge) / (v - previous)), 0), 1)
                }
                let interval = sinceEdge - fraction
                sinceEdge = fraction
                if let frame = onInterval(interval, sampleIndex: index) {
                    frames.append(frame)
                }
            }
            if level == 0, next != 0 { sinceEdge = 0 }
            level = next
            previous = v
        }
        return frames
    }

    private func onInterval(_ interval: Double, sampleIndex: Int) -> LTCFrame? {
        let p = period
        if interval > 3 * p || interval < 0.25 * p {
            if interval > 3 * p, interval < 8 * p, lockedFrames == 0 {
                period = interval
            }
            halfPending = false
            bits.removeAll(keepingCapacity: true)
            return nil
        }
        if interval < 0.75 * p {
            period += (2 * interval - p) * 0.05
            if halfPending {
                halfPending = false
                return onBit(1, sampleIndex: sampleIndex)
            }
            halfPending = true
            return nil
        }
        if interval > 1.5 * p, lockedFrames == 0 {
            period = interval
        } else {
            period += (interval - p) * 0.05
        }
        if halfPending {
            halfPending = false
            bits.removeAll(keepingCapacity: true)
            return nil
        }
        return onBit(0, sampleIndex: sampleIndex)
    }

    private func onBit(_ bit: UInt8, sampleIndex: Int) -> LTCFrame? {
        bits.append(bit)
        if bits.count > 80 { bits.removeFirst() }
        guard bits.count == 80, Array(bits[64..<80]) == Self.sync else { return nil }

        func value(_ start: Int, _ count: Int) -> Int {
            var result = 0
            for i in 0..<count { result |= Int(bits[start + i]) << i }
            return result
        }
        let frameUnits = value(0, 4), secondUnits = value(16, 4)
        let minuteUnits = value(32, 4), hourUnits = value(48, 4)
        let frames = frameUnits + 10 * value(8, 2)
        let seconds = secondUnits + 10 * value(24, 3)
        let minutes = minuteUnits + 10 * value(40, 3)
        let hours = hourUnits + 10 * value(56, 2)
        let dropFrame = bits[10] == 1
        bits.removeAll(keepingCapacity: true)

        guard frameUnits <= 9, secondUnits <= 9, minuteUnits <= 9, hourUnits <= 9,
              frames <= 29, seconds <= 59, minutes <= 59, hours <= 23
        else {
            lockedFrames = 0
            return nil
        }
        lockedFrames = min(lockedFrames + 1, 10)
        return LTCFrame(
            timecode: Timecode(
                hours: hours, minutes: minutes, seconds: seconds, frames: frames,
                dropFrame: dropFrame),
            measuredFPS: sampleRate / (80 * period),
            sampleIndex: sampleIndex
        )
    }
}
