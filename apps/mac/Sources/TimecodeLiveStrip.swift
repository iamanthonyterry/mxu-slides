import PresenterCore
import QuartzCore
import SwiftUI
import TimecodeKit

/// The live timeline under the slides in Present mode: the current song's cues
/// scroll past a fixed playhead, so the operator can see what's about to fire
/// and take over in a click.
///
/// - Hold stops firing (the strip keeps moving); releasing resumes at the next cue.
/// - Sync fires the cue the timeline is on now.
/// - Double-click a cue to fire that slide immediately.
struct TimecodeLiveStrip: View {
    let model: AppModel
    let timecode: TimecodeController

    @State private var editing: EditTarget?

    struct EditTarget: Identifiable { let id: String }

    /// Seconds of timeline shown, and where the playhead sits across the strip.
    private static let window: Double = 24
    private static let playheadFraction: CGFloat = 0.3
    static let height: CGFloat = 78

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: timecode.status != .running)) { _ in
            let label = timecode.livePosition() ?? timecode.liveLabel
            let song = label.flatMap { timecode.song(containing: $0) }
            HStack(spacing: 0) {
                info(song: song, label: label)
                    .frame(width: 230, alignment: .leading)
                    .padding(.horizontal, 12)
                Divider()
                lane(song: song, label: label)
                Divider()
                controls(song: song)
                    .padding(.horizontal, 12)
            }
        }
        .frame(height: Self.height)
        .background(timecode.held ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04))
        .overlay(alignment: .top) { Divider() }
        .sheet(item: $editing) { target in
            TimelineEditorSheet(model: model, presentationID: target.id)
        }
    }

    // MARK: Info

    private func info(song: ChaseTimeline?, label: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(timecode.held ? "HELD" : timecode.status.label)
                    .font(.caption.weight(timecode.held ? .bold : .regular))
                    .foregroundStyle(timecode.held ? Color.orange : Color.secondary)
                Spacer(minLength: 4)
                Text(timecode.timecode?.description ?? "--:--:--:--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(song?.name ?? waitingText)
                .font(.headline)
                .lineLimit(1)
            if let song, let label, let next = nextCue(in: song, at: label) {
                Text("Next: \(slideLabel(song, next.cue.slideID)) in \(countdown(next.cue.time - (label - song.offset)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if song != nil {
                Text("Last cue").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var waitingText: String {
        if timecode.serviceName == nil { return "No service selected" }
        if timecode.followedSongCount == 0 { return "No songs on timecode" }
        return "\(timecode.followedSongCount) song\(timecode.followedSongCount == 1 ? "" : "s") on timecode"
    }

    private var statusColor: Color {
        if timecode.held { return .orange }
        switch timecode.status {
        case .running: return .green
        case .waiting, .stopped: return .yellow
        case .failed, .noInput: return .red
        case .off: return .gray
        }
    }

    // MARK: Lane

    private func lane(song: ChaseTimeline?, label: Double?) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let pps = width / CGFloat(Self.window)
            let playheadX = width * Self.playheadFraction
            let local = (label ?? 0) - (song?.offset ?? 0)
            let active = timecode.activeCue
            ZStack(alignment: .topLeading) {
                if let song {
                    // Second ticks, drawn relative to the moving playhead.
                    Canvas { context, size in
                        let first = Int((local - Double(playheadX / pps)).rounded(.down))
                        let last = Int((local + Double((size.width - playheadX) / pps)).rounded(.up))
                        for second in max(0, first)...max(0, last) {
                            let x = playheadX + CGFloat(Double(second) - local) * pps
                            var tick = Path()
                            let major = second % 5 == 0
                            tick.move(to: CGPoint(x: x, y: size.height))
                            tick.addLine(to: CGPoint(x: x, y: size.height - (major ? 8 : 4)))
                            context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                        }
                    }

                    ForEach(Array(song.cues.enumerated()), id: \.offset) { index, cue in
                        let x = playheadX + CGFloat(cue.time - local) * pps
                        if x > -160, x < width + 20 {
                            cueView(
                                song: song, cue: cue, index: index,
                                state: cueState(index: index, song: song, active: active, local: local))
                                .offset(x: x)
                        }
                    }
                } else {
                    Text(timecode.enabled ? "Waiting for a song's timecode" : "Timecode is off — Settings › Timecode")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Rectangle()
                    .fill(timecode.held ? Color.orange : Color.red)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .offset(x: playheadX - 1)
                    .allowsHitTesting(false)
            }
            .clipped()
        }
        .frame(maxWidth: .infinity)
    }

    enum CueState { case past, live, next, upcoming }

    private func cueState(index: Int, song: ChaseTimeline, active: (presentationID: String, cueIndex: Int)?, local: Double) -> CueState {
        if let active, active.presentationID == song.presentationID {
            if index == active.cueIndex { return .live }
            if index == active.cueIndex + 1 { return .next }
            return index < active.cueIndex ? .past : .upcoming
        }
        return song.cues[index].time <= local ? .past : .upcoming
    }

    private func cueView(song: ChaseTimeline, cue: ChaseTimeline.Cue, index: Int, state: CueState) -> some View {
        let tint: Color = switch state {
        case .live: .green
        case .next: .accentColor
        case .past: .secondary
        case .upcoming: .primary
        }
        return VStack(alignment: .leading, spacing: 3) {
            Rectangle()
                .fill(tint.opacity(state == .past ? 0.4 : 1))
                .frame(width: state == .live ? 3 : 2, height: 22)
            Text(slideLabel(song, cue.slideID))
                .font(.caption.weight(state == .live || state == .next ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tint.opacity(state == .past ? 0.08 : 0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(state == .next ? Color.accentColor : .clear, lineWidth: 1)
                )
                .opacity(state == .past ? 0.55 : 1)
        }
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            let occurrence = song.cues[..<index].filter { $0.slideID == cue.slideID }.count
            timecode.fireManually(presentationID: song.presentationID, slideID: cue.slideID, occurrence: occurrence)
        }
        .help("Double-click to fire \(slideLabel(song, cue.slideID)) now")
    }

    // MARK: Controls

    private func controls(song: ChaseTimeline?) -> some View {
        HStack(spacing: 8) {
            Button {
                timecode.setHold(!timecode.held)
            } label: {
                Label(timecode.held ? "Resume" : "Hold", systemImage: timecode.held ? "play.fill" : "hand.raised.fill")
                    .frame(minWidth: 78)
            }
            .controlSize(.large)
            .tint(timecode.held ? .orange : nil)
            .buttonStyle(.borderedProminent)
            .help(timecode.held
                  ? "Resume automation at the next cue (the current slide stays as you left it)"
                  : "Stop firing cues so you can drive by hand. The timeline keeps moving.")

            Button {
                timecode.syncNow()
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Fire the cue the timeline is on right now (and release Hold)")

            Button {
                if let song { editing = EditTarget(id: song.presentationID) }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .disabled(song == nil)
            .help("Edit this song's timeline")
        }
    }

    // MARK: Helpers

    private func nextCue(in song: ChaseTimeline, at label: Double) -> (index: Int, cue: ChaseTimeline.Cue)? {
        let local = label - song.offset
        guard let index = song.cues.firstIndex(where: { $0.time > local + 1e-6 }) else { return nil }
        return (index, song.cues[index])
    }

    private func slideLabel(_ song: ChaseTimeline, _ slideID: String) -> String {
        timecode.slideLabels[song.presentationID]?[slideID] ?? "Slide"
    }

    private func countdown(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 10 { return String(format: "%.1fs", s) }
        let whole = Int(s.rounded(.down))
        return whole >= 60 ? "\(whole / 60):\(whole % 60 < 10 ? "0" : "")\(whole % 60)" : "\(whole)s"
    }
}
