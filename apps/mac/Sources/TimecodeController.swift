import AVFoundation
import AudioEngine
import Foundation
import Observation
import PresenterCore
import QuartzCore
import SwiftUI
import TimecodeKit

/// Taps one mono channel of an audio input and decodes LTC from it on the audio
/// thread. Decoded frames and the input level are handed to `onFrames` / `onLevel`.
final class TimecodeAudioInput: @unchecked Sendable {
    typealias FramesHandler = @Sendable (_ frames: [LTCFrame], _ bufferStartHost: Double, _ sampleRate: Double) -> Void
    typealias LevelHandler = @Sendable (_ peak: Float, _ locked: Bool) -> Void

    private let lock = NSLock()
    private var hub: AudioInputHub?
    private var tapToken: UUID?
    private var deviceUID: String?
    private var decoder: LTCDecoder?
    private var lastLevelReport: Double = 0

    var onFrames: FramesHandler?
    var onLevel: LevelHandler?

    func start(deviceUID: String, channel: Int) throws {
        stop()
        try lock.withLock {
            let hub = try AudioInputHubPool.shared.acquire(deviceUID: deviceUID)
            self.hub = hub
            self.deviceUID = deviceUID
            tapToken = hub.addTap(channels: .mono(channel: channel)) { [weak self] buffer, _, hostSeconds in
                self?.process(buffer, hostSeconds: hostSeconds)
            }
        }
    }

    func stop() {
        lock.withLock {
            if let hub, let tapToken { hub.removeTap(tapToken) }
            if hub != nil, let deviceUID { AudioInputHubPool.shared.release(deviceUID: deviceUID) }
            hub = nil
            tapToken = nil
            deviceUID = nil
            decoder = nil
        }
    }

    /// Runs on the audio thread. The decoder is only touched here.
    private func process(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let sampleRate = buffer.format.sampleRate
        let decoder: LTCDecoder = lock.withLock {
            if let existing = self.decoder, existing.sampleRate == sampleRate { return existing }
            let made = LTCDecoder(sampleRate: sampleRate)
            self.decoder = made
            return made
        }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        let frames = decoder.push(samples)
        if !frames.isEmpty, decoder.isLocked {
            onFrames?(frames, hostSeconds, sampleRate)
        }
        if hostSeconds - lastLevelReport > 0.1 {
            lastLevelReport = hostSeconds
            onLevel?(decoder.inputPeak, decoder.isLocked)
        }
    }
}

/// Follows incoming LTC and fires timeline cues in the current service.
///
/// Mirrors ProPresenter's per-song timelines: each song's timeline has a timecode
/// offset (01:00:00:00 for song one, 02:00:00:00 for song two, …) and the slide
/// cues on it fire as the timecode passes them.
@MainActor
@Observable
final class TimecodeController {

    enum Status: Equatable {
        case off
        case noInput
        case waiting
        case running
        case stopped
        case failed(String)

        var label: String {
            switch self {
            case .off: "Off"
            case .noInput: "Choose an input"
            case .waiting: "Waiting for timecode"
            case .running: "Following"
            case .stopped: "Timecode stopped"
            case .failed(let message): message
            }
        }
    }

    private enum Key {
        static let enabled = "timecode.enabled"
        static let deviceUID = "timecode.deviceUID"
        static let channel = "timecode.channel"
        static let earlyFrames = "timecode.earlyFrames"
        static let lastRate = "timecode.lastRate"
    }

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled); restart() }
    }
    var deviceUID: String {
        didSet { UserDefaults.standard.set(deviceUID, forKey: Key.deviceUID); restart() }
    }
    /// Zero-based input channel carrying LTC.
    var channel: Int {
        didSet { UserDefaults.standard.set(channel, forKey: Key.channel); restart() }
    }
    /// Fires cues this many frames early, to make up for projector or switcher delay.
    var earlyFrames: Int {
        didSet { UserDefaults.standard.set(earlyFrames, forKey: Key.earlyFrames) }
    }

    private(set) var status: Status = .off
    private(set) var timecode: Timecode?
    private(set) var rate: TimecodeRate?

    /// The rate timecode last arrived at (remembered across launches), for
    /// editing timelines when no timecode is running.
    var editingRate: TimecodeRate {
        rate ?? UserDefaults.standard.string(forKey: Key.lastRate).flatMap(TimecodeRate.init(rawValue:)) ?? .fps25
    }
    private(set) var inputPeak: Float = 0
    private(set) var activeSongName: String?
    private(set) var serviceName: String?
    private(set) var followedSongCount = 0

    /// Latest timecode label (seconds, one frame past the decoded label, without
    /// the fire-early adjustment) and the host time it was current at.
    private(set) var liveLabel: Double?
    private(set) var liveLabelHost: Double?

    /// While true, cues are tracked but not fired — the timeline editor sets this
    /// during a record pass so the old cues don't fire over the new taps.
    var suppressFiring = false

    /// The timecode label right now, extrapolated between frames for a smooth
    /// playhead. Nil unless timecode is actually running.
    func livePosition(at now: Double = CACurrentMediaTime()) -> Double? {
        guard status == .running, let label = liveLabel, let host = liveLabelHost else { return nil }
        let elapsed = now - host
        guard elapsed >= 0, elapsed < 1 else { return label }
        return label + elapsed
    }

    private let bridge: AppAPIBridge
    private let input = TimecodeAudioInput()
    private var chase = TimecodeChase()
    private var songNames: [String: String] = [:]
    private var loop: Task<Void, Never>?

    init(bridge: AppAPIBridge) {
        self.bridge = bridge
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Key.enabled)
        deviceUID = defaults.string(forKey: Key.deviceUID) ?? ""
        channel = defaults.integer(forKey: Key.channel)
        earlyFrames = defaults.integer(forKey: Key.earlyFrames)

        input.onFrames = { [weak self] frames, host, sampleRate in
            guard let self else { return }
            Task { @MainActor in self.receive(frames, bufferStartHost: host, sampleRate: sampleRate) }
        }
        input.onLevel = { [weak self] peak, _ in
            guard let self else { return }
            Task { @MainActor in self.inputPeak = peak }
        }
    }

    func attach() {
        restart()
    }

    var inputDevices: [AudioDeviceList.AudioInputDevice] {
        AudioDeviceList.inputDevices()
    }

    private func restart() {
        input.stop()
        loop?.cancel()
        loop = nil
        chase = TimecodeChase(timelines: chase.timelines)
        timecode = nil
        rate = nil
        activeSongName = nil
        guard enabled else { status = .off; return }
        guard !deviceUID.isEmpty, AudioDeviceList.inputDevice(uid: deviceUID) != nil else {
            status = .noInput
            return
        }
        do {
            try input.start(deviceUID: deviceUID, channel: channel)
        } catch {
            status = .failed("Input unavailable")
            DiagnosticsStore.shared.note("timecode.input", detail: "\(error)")
            return
        }
        status = .waiting
        loop = Task { [weak self] in
            var lastRefresh = -Double.infinity
            while !Task.isCancelled {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if now - lastRefresh >= 2 {
                    lastRefresh = now
                    await self.refreshTimelines()
                }
                self.handle(self.chase.tick(at: now))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Rebuilds the chase list from the current service. Cheap: decks the
    /// service already holds open are reused.
    func refreshTimelines() async {
        let found = await bridge.timecodePresentations()
        serviceName = found.serviceName
        var names: [String: String] = [:]
        let timelines: [ChaseTimeline] = found.decks.compactMap { deck in
            guard let timeline = deck.timeline else { return nil }
            names[deck.id] = deck.name
            return ChaseTimeline(
                presentationID: deck.id, name: deck.name,
                offset: timeline.offsetSeconds, duration: timeline.durationSeconds,
                cues: timeline.cues.map { .init(slideID: $0.slideId, time: $0.timeSeconds) })
        }
        songNames = names
        followedSongCount = timelines.count
        let ordered = TimecodeChase.ordered(timelines)
        if ordered != chase.timelines {
            chase.timelines = ordered
            chase.resync()
        }
    }

    private func receive(_ frames: [LTCFrame], bufferStartHost: Double, sampleRate: Double) {
        for frame in frames {
            let rate = frame.rate
            let frameLength = 1 / Double(rate.nominalFrames)
            // The label names the frame that just finished, so the clock is one frame past it.
            let current = frame.timecode.labelSeconds(rate: rate) + frameLength
            let label = current + frameLength * Double(earlyFrames)
            let at = bufferStartHost + Double(frame.sampleIndex) / sampleRate
            liveLabel = current
            liveLabelHost = at
            timecode = frame.timecode
            if self.rate != rate {
                self.rate = rate
                UserDefaults.standard.set(rate.rawValue, forKey: Key.lastRate)
            }
            handle(chase.receive(position: label, at: at))
        }
        if chase.isRunning { status = .running }
    }

    /// Re-fires whatever cue the timecode is on now, e.g. after the editor
    /// saves a timeline or finishes a record pass.
    func resync() {
        chase.resync()
        Task { await refreshTimelines() }
    }

    private func handle(_ events: [ChaseEvent]) {
        for event in events {
            switch event {
            case .fire(let presentationID, let slideID, _, let occurrence):
                activeSongName = songNames[presentationID]
                if suppressFiring { continue }
                DiagnosticsStore.shared.note("timecode.fire", detail: "\(timecode?.description ?? "") \(slideID)")
                Task { await bridge.fireTimelineCue(
                    presentationID: presentationID, slideID: slideID, occurrence: occurrence) }
            case .stopped:
                status = .stopped
            }
        }
    }
}

private struct TimecodeControllerKey: EnvironmentKey {
    static let defaultValue: TimecodeController? = nil
}

extension EnvironmentValues {
    var timecode: TimecodeController? {
        get { self[TimecodeControllerKey.self] }
        set { self[TimecodeControllerKey.self] = newValue }
    }
}
