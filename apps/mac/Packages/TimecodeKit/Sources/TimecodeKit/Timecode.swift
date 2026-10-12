import Foundation

/// SMPTE frame rates LTC can carry.
public enum TimecodeRate: String, CaseIterable, Codable, Sendable {
    case fps24 = "24"
    case fps25 = "25"
    case fps2997Drop = "29.97df"
    case fps30 = "30"

    /// Frames per timecode-second as written on the label (29.97 drop still counts to 30).
    public var nominalFrames: Int {
        switch self {
        case .fps24: 24
        case .fps25: 25
        case .fps2997Drop, .fps30: 30
        }
    }

    public var label: String {
        switch self {
        case .fps24: "24 fps"
        case .fps25: "25 fps"
        case .fps2997Drop: "29.97 fps drop"
        case .fps30: "30 fps"
        }
    }

    /// The closest standard rate to a measured rate. The drop-frame flag in the
    /// stream decides 29.97 drop vs 30, since their bit rates are 0.1% apart.
    public static func nearest(measured fps: Double, dropFlag: Bool) -> TimecodeRate {
        if fps >= 27.5 { return dropFlag ? .fps2997Drop : .fps30 }
        return fps < 24.5 ? .fps24 : .fps25
    }
}

/// One timecode label: hours, minutes, seconds, frames.
public struct Timecode: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var dropFrame: Bool

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, dropFrame: Bool = false) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.dropFrame = dropFrame
    }

    /// The label as seconds, counting frames at the label's nominal rate.
    ///
    /// Pro7 timelines and offsets are compared against the label, not wall time,
    /// so 01:00:00:00 is always 3600 regardless of drop frame.
    public func labelSeconds(rate: TimecodeRate) -> Double {
        Double(hours * 3600 + minutes * 60 + seconds)
            + Double(frames) / Double(rate.nominalFrames)
    }

    public var description: String {
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return "\(two(hours)):\(two(minutes)):\(two(seconds))\(dropFrame ? ";" : ":")\(two(frames))"
    }

    /// Parses "HH:MM:SS:FF" (or ";" before frames).
    public init?(string: String) {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard parts.count == 4, let h = Int(parts[0]), let m = Int(parts[1]),
              let s = Int(parts[2]), let f = Int(parts[3]),
              (0...23).contains(h), (0...59).contains(m), (0...59).contains(s), (0...29).contains(f)
        else { return nil }
        self.init(hours: h, minutes: m, seconds: s, frames: f, dropFrame: string.contains(";"))
    }
}
