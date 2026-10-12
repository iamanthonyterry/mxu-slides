import AppKit
import PresenterCore
import QuartzCore
import SlideScene
import SwiftUI
import TimecodeKit

/// Edits a presentation's timecode timeline.
///
/// Everything happens on a draft with its own undo history; nothing touches the
/// library until Save, which lands as one app-level undo step. Record passes are
/// punch-ins: taps collect live and replace only the recorded range when the pass
/// ends, so a stopped or aborted pass never leaves half a take behind.
struct TimelineEditorSheet: View {
    let model: AppModel
    let presentationID: String

    @Environment(\.timecode) private var timecode
    @Environment(\.dismiss) private var dismiss

    @State private var presentationName = ""
    @State private var history: TimelineHistory?
    @State private var original: TimelineDraft?
    @State private var slides: [SlideRow] = []
    @State private var selection: Set<UUID> = []

    @State private var pixelsPerSecond: CGFloat = 40
    @State private var snapping = true
    @State private var following = true
    @State private var source: ClockSource = .timecode
    @State private var clock = EditorClock()

    @State private var recordArmed = false
    @State private var recording: TimelineRecording?
    @State private var dragOrigin: TimelineDraft?
    @State private var dragIDs: Set<UUID> = []
    @State private var dragPreview: TimelineDraft?

    @State private var startField = ""
    @State private var durationField = ""
    @State private var cueTimeField = ""
    @State private var confirmDiscard = false
    @FocusState private var canvasFocused: Bool

    enum ClockSource: String, CaseIterable, Identifiable {
        case timecode = "Timecode"
        case local = "Local"
        var id: String { rawValue }
    }

    struct SlideRow: Identifiable, Equatable {
        var id: Int
        var slideID: String
        var label: String
        var color: Color
    }

    private static let leftPad: CGFloat = 16
    private static let laneHeight: CGFloat = 64
    private static let rulerHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            if let draft = displayed {
                header(draft)
                Divider()
                transport(draft)
                Divider()
                timelineArea(draft)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    slideStrip(draft)
                    Divider()
                    inspector(draft)
                        .frame(width: 300)
                }
                .frame(height: 170)
                Divider()
                footer
            } else {
                ProgressView("Loading timeline…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 640, idealHeight: 720)
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { handleKey($0) }
        .task { await load() }
        .task(id: recordArmed) { await recordLoop() }
        .onDisappear {
            timecode?.suppressFiring = false
        }
        .confirmationDialog("Discard timeline changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    // MARK: Derived state

    private var current: TimelineDraft? { history?.current }
    private var displayed: TimelineDraft? { dragPreview ?? current }
    private var isDirty: Bool { current != original }
    private var rate: TimecodeRate { current?.rate ?? .fps25 }

    private var timecodeRunning: Bool { timecode?.status == .running }

    private var clockRunning: Bool {
        switch source {
        case .timecode: timecodeRunning
        case .local: clock.playing
        }
    }

    /// Song-relative playhead in seconds.
    private func playhead(at now: Double = CACurrentMediaTime()) -> Double {
        if source == .timecode, let label = timecode?.livePosition(at: now), let draft = current {
            return label - draft.offset
        }
        return clock.position(at: now)
    }

    private func nextSlideID(after time: Double, in draft: TimelineDraft) -> String? {
        let before = draft.cues.filter { $0.time < time - 1e-9 }.count
        guard !slides.isEmpty else { return nil }
        return slides[min(before, slides.count - 1)].slideID
    }

    private func label(for slideID: String) -> String {
        slides.first { $0.slideID == slideID }?.label ?? "Missing slide"
    }

    private func color(for slideID: String) -> Color {
        slides.first { $0.slideID == slideID }?.color ?? .gray
    }

    // MARK: Header

    private func header(_ draft: TimelineDraft) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentationName).font(.headline)
                Text("Timeline · \(draft.cues.count) cue\(draft.cues.count == 1 ? "" : "s") · \(rate.label)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Follow timecode", isOn: Binding(
                get: { draft.timecodeEnabled },
                set: { value in history?.edit { $0.timecodeEnabled = value } }
            ))
            .toggleStyle(.checkbox)
            .help("When on, this song fires from incoming timecode in a service.")

            LabeledContent("Starts at") {
                TextField("01:00:00:00", text: $startField)
                    .font(.body.monospacedDigit())
                    .frame(width: 104)
                    .onSubmit { commitStart() }
            }
            .fixedSize()

            Button("Use Incoming Hour") {
                guard let label = timecode?.livePosition() else { return }
                let hour = (label / 3600).rounded(.down) * 3600
                history?.edit { $0.offset = hour }
                startField = Self.absolute(hour, rate: rate)
            }
            .disabled(!timecodeRunning)
            .help("Set the start to the hour currently coming in — e.g. 02:00:00:00 for song two.")

            LabeledContent("Length") {
                TextField("auto", text: $durationField)
                    .font(.body.monospacedDigit())
                    .frame(width: 70)
                    .onSubmit { commitDuration() }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Transport

    private func transport(_ draft: TimelineDraft) -> some View {
        HStack(spacing: 12) {
            Picker("Clock", selection: $source) {
                ForEach(ClockSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .help("Timecode follows the incoming LTC (Ableton, Playback). Local is a silent clock for editing without it.")

            Button { park(at: 0) } label: { Image(systemName: "backward.end.fill") }
                .help("Playhead to start")
            Button {
                togglePlay()
            } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill")
            }
            .disabled(source == .timecode)
            .help("Play or pause the local clock (Space)")

            Button {
                if recording != nil || recordArmed { stopRecording(keep: true) } else { recordArmed = true }
            } label: {
                Label(recordLabel, systemImage: "record.circle")
                    .foregroundStyle(recordArmed || recording != nil ? Color.red : Color.primary)
            }
            .help("Arm, then start the track. Tap Return (or click slides below) as each slide should appear. Stops when the clock stops. Esc throws the pass away.")

            TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                let position = playhead()
                HStack(spacing: 10) {
                    Text(Self.songTime(position, rate: rate))
                        .font(.title3.monospacedDigit())
                    Text(Self.absolute(draft.offset + position, rate: rate))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if source == .timecode {
                        Text(timecodeRunning ? "TC running" : "No timecode")
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((timecodeRunning ? Color.green : Color.secondary).opacity(0.2), in: Capsule())
                    }
                }
            }

            Spacer()

            Button { history?.undo(); prune() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(history?.canUndo != true || recording != nil)
                .help("Undo (⌘Z)")
            Button { history?.redo(); prune() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(history?.canRedo != true || recording != nil)
                .help("Redo (⇧⌘Z)")
            Button("Select All") { selection = Set(draft.cues.map(\.id)) }
                .keyboardShortcut("a", modifiers: .command)

            Toggle("Snap", isOn: $snapping).toggleStyle(.checkbox)
                .help("Snap drags to other cues and the playhead. Hold ⌘ while dragging to ignore snapping.")
            Toggle("Follow", isOn: $following).toggleStyle(.checkbox)
                .help("Keep the playhead in view while the clock runs.")

            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: zoomBinding, in: 0...1)
                .frame(width: 110)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var recordLabel: String {
        if recording != nil { return "Recording" }
        if recordArmed {
            if !clockRunning { return "Armed — start the track" }
            return playheadInSong ? "Starting…" : "Armed — timecode is in another song's hour"
        }
        return "Record"
    }

    /// The incoming timecode is inside this song (not another song's hour).
    private var playheadInSong: Bool {
        let position = playhead()
        return position >= 0 && position < 3_600
    }

    /// Zoom on a log scale: 4 px/s (whole song) to 400 px/s (single frames).
    private var zoomBinding: Binding<Double> {
        Binding(
            get: { log(Double(pixelsPerSecond) / 4) / log(100) },
            set: { pixelsPerSecond = CGFloat(4 * pow(100, $0)) }
        )
    }

    // MARK: Timeline

    private func timelineArea(_ draft: TimelineDraft) -> some View {
        let length = draft.visibleLength
        let width = Self.leftPad * 2 + CGFloat(length) * pixelsPerSecond
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: !clockRunning && dragPreview == nil)) { _ in
                    let position = playhead()
                    ZStack(alignment: .topLeading) {
                        ruler(draft, width: width)
                        lane(draft, width: width)
                            .offset(y: Self.rulerHeight)
                        playheadLine(position)
                        // Padding (not offset) so the anchor's layout position —
                        // which scrollTo uses — sits at the playhead.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .padding(.leading, x(for: max(0, position)))
                            .id("playhead")
                    }
                    .frame(width: width, height: Self.rulerHeight + Self.laneHeight, alignment: .topLeading)
                }
            }
            .frame(height: Self.rulerHeight + Self.laneHeight + 16)
            .background(Color.black.opacity(0.12))
            .task(id: following && clockRunning) {
                while following && clockRunning && !Task.isCancelled {
                    withAnimation(.linear(duration: 0.25)) {
                        proxy.scrollTo("playhead", anchor: UnitPoint(x: 0.3, y: 0.5))
                    }
                    try? await Task.sleep(for: .milliseconds(750))
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func x(for time: Double) -> CGFloat {
        Self.leftPad + CGFloat(time) * pixelsPerSecond
    }

    private func time(at x: CGFloat) -> Double {
        max(0, Double((x - Self.leftPad) / pixelsPerSecond))
    }

    private static let tileWidth: CGFloat = 1_024

    private func tileCount(_ width: CGFloat) -> Int {
        max(1, Int((width / Self.tileWidth).rounded(.up)))
    }

    /// The ruler, drawn as lazy tiles so only the visible part is ever rendered.
    private func ruler(_ draft: TimelineDraft, width: CGFloat) -> some View {
        let pps = pixelsPerSecond
        let rate = self.rate
        let step = Self.tickStep(pixelsPerSecond: pps)
        let perMajor = max(1, Int((step.major / step.minor).rounded()))
        return LazyHStack(spacing: 0) {
            ForEach(0..<tileCount(width), id: \.self) { tile in
                let origin = CGFloat(tile) * Self.tileWidth
                Canvas { context, size in
                    // Ticks whose x falls in this tile, by integer index (no drift).
                    let firstTime = Double(max(0, origin - Self.leftPad) / pps)
                    let lastTime = Double((origin + size.width - Self.leftPad) / pps)
                    let first = max(0, Int((firstTime / step.minor).rounded(.down)))
                    let last = max(first, Int((lastTime / step.minor).rounded(.up)))
                    for index in first...last {
                        let t = Double(index) * step.minor
                        let px = Self.leftPad + CGFloat(t) * pps - origin
                        guard px >= -60, px <= size.width else { continue }
                        let major = index % perMajor == 0
                        var path = Path()
                        path.move(to: CGPoint(x: px, y: size.height))
                        path.addLine(to: CGPoint(x: px, y: size.height - (major ? 12 : 5)))
                        context.stroke(path, with: .color(.secondary), lineWidth: 1)
                        if major {
                            let text = Text(Self.songTime(t, rate: rate, showFrames: step.major < 1))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(.secondary)
                            context.draw(text, at: CGPoint(x: px + 3, y: 8), anchor: .leading)
                        }
                    }
                }
                .frame(width: min(Self.tileWidth, width - origin), height: Self.rulerHeight)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    park(at: time(at: location.x + origin))
                    canvasFocused = true
                }
            }
        }
        .frame(width: width, height: Self.rulerHeight, alignment: .leading)
        .help("Click to move the playhead")
    }

    /// Ruler spacing that keeps labels ~80 px apart at any zoom.
    static func tickStep(pixelsPerSecond pps: CGFloat) -> (major: Double, minor: Double) {
        let candidates: [(Double, Double)] = [
            (0.2, 0.04), (0.5, 0.1), (1, 0.2), (2, 0.5), (5, 1), (10, 2),
            (15, 5), (30, 5), (60, 10), (120, 30), (300, 60),
        ]
        for c in candidates where CGFloat(c.0) * pps >= 80 { return c }
        return (600, 60)
    }

    private func lane(_ draft: TimelineDraft, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            LazyHStack(spacing: 0) {
                ForEach(0..<tileCount(width), id: \.self) { tile in
                    let origin = CGFloat(tile) * Self.tileWidth
                    Rectangle()
                        .fill(Color.primary.opacity(0.04))
                        .frame(width: min(Self.tileWidth, width - origin), height: Self.laneHeight)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, coordinateSpace: .local) { location in
                            addCue(at: time(at: location.x + origin))
                        }
                        .onTapGesture(count: 1, coordinateSpace: .local) { location in
                            if !NSEvent.modifierFlags.contains(.shift) { selection = [] }
                            park(at: time(at: location.x + origin))
                            canvasFocused = true
                        }
                }
            }
            .frame(width: width, height: Self.laneHeight, alignment: .leading)

            if let duration = draft.duration {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 2, height: Self.laneHeight)
                    .offset(x: x(for: duration))
                    .help("End of timeline")
            }

            ForEach(draft.cues) { cue in
                cueMarker(cue, in: draft)
                    .offset(x: x(for: cue.time))
            }

            if let pass = recording {
                ForEach(Array(pass.taps.enumerated()), id: \.offset) { item in
                    VStack(spacing: 2) {
                        Rectangle().fill(Color.red).frame(width: 2, height: Self.laneHeight - 18)
                        Text(label(for: item.element.slideID))
                            .font(.caption2).lineLimit(1)
                            .foregroundStyle(.red)
                            .fixedSize()
                    }
                    .offset(x: x(for: item.element.time) - 1)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(width: width, height: Self.laneHeight, alignment: .topLeading)
    }

    private func cueMarker(_ cue: TimelineDraft.Cue, in draft: TimelineDraft) -> some View {
        let selected = selection.contains(cue.id)
        let tint = color(for: cue.slideID)
        return VStack(alignment: .leading, spacing: 3) {
            Rectangle()
                .fill(selected ? Color.accentColor : tint)
                .frame(width: selected ? 3 : 2, height: 26)
            Text(label(for: cue.slideID))
                .font(.caption2.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? Color.accentColor.opacity(0.35) : tint.opacity(0.25))
                )
                .fixedSize()
            Text(Self.songTime(cue.time, rate: rate))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .frame(height: Self.laneHeight, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            select(cue.id)
            canvasFocused = true
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in drag(cue.id, translation: value.translation.width) }
                .onEnded { _ in endDrag() }
        )
        .help("\(label(for: cue.slideID)) at \(Self.songTime(cue.time, rate: rate)) — drag to move, ←/→ to nudge a frame")
    }

    private func playheadLine(_ position: Double) -> some View {
        Rectangle()
            .fill(recording != nil ? Color.red : Color.orange)
            .frame(width: 2, height: Self.rulerHeight + Self.laneHeight)
            .offset(x: x(for: max(0, position)) - 1)
            .allowsHitTesting(false)
    }

    // MARK: Slide strip

    private func slideStrip(_ draft: TimelineDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording != nil
                 ? "Recording — click a slide to place it now, or press Return for the next one"
                 : "Click a slide to add it at the playhead · double-click the lane to add the next slide there")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(slides) { row in
                        Button {
                            slideClicked(row)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(row.color).frame(height: 4)
                                Text(row.label)
                                    .font(.caption)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                    .frame(width: 120, height: 48, alignment: .topLeading)
                                Text("\(row.id + 1)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isNextRecordSlot(row) ? Color.red.opacity(0.18) : Color.primary.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isNextRecordSlot(_ row: SlideRow) -> Bool {
        guard let pass = recording else { return false }
        return pass.cursor == row.id
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ draft: TimelineDraft) -> some View {
        let picked = draft.cues.filter { selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            if picked.isEmpty {
                Text("No cue selected").font(.headline)
                Text("Click a cue to select it. Shift-click for more. ←/→ nudges a frame, ⇧ ten frames, ⌥ one second. Option-drag ripples everything after.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if picked.count == 1, let cue = picked.first {
                Picker("Slide", selection: Binding(
                    get: { cue.slideID },
                    set: { id in history?.edit { $0.reassign(cue.id, to: id) } }
                )) {
                    ForEach(uniqueSlides) { row in Text(row.label).tag(row.slideID) }
                    if !slides.contains(where: { $0.slideID == cue.slideID }) {
                        Text("Missing slide").tag(cue.slideID)
                    }
                }
                LabeledContent("Time") {
                    TextField("0:00:00", text: $cueTimeField)
                        .font(.body.monospacedDigit())
                        .frame(width: 110)
                        .onSubmit { commitCueTime(cue.id) }
                }
                Text("Timecode \(Self.absolute(draft.offset + cue.time, rate: rate))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("\(picked.count) cues selected").font(.headline)
            }
            if !picked.isEmpty {
                HStack(spacing: 4) {
                    nudgeButton("−1s", frames: -rate.nominalFrames)
                    nudgeButton("−10f", frames: -10)
                    nudgeButton("−1f", frames: -1)
                    nudgeButton("+1f", frames: 1)
                    nudgeButton("+10f", frames: 10)
                    nudgeButton("+1s", frames: rate.nominalFrames)
                }
                HStack {
                    Button("Move to Playhead") {
                        let target = playhead()
                        guard let first = picked.first else { return }
                        history?.edit { $0.move(selection, by: target - first.time) }
                    }
                    Spacer()
                    Button("Delete", role: .destructive) { deleteSelection() }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: selection) { syncCueTimeField() }
        .onChange(of: history?.current) { syncCueTimeField() }
    }

    private var uniqueSlides: [SlideRow] {
        var seen = Set<String>()
        return slides.filter { seen.insert($0.slideID).inserted }
    }

    private func nudgeButton(_ title: String, frames: Int) -> some View {
        Button(title) { history?.edit { $0.nudge(selection, frames: frames) } }
            .controlSize(.small)
            .font(.caption.monospacedDigit())
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if !(timecode?.enabled ?? false) {
                Label("Timecode input is off — turn it on in Settings › Timecode to record against your track.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                if recording != nil { stopRecording(keep: false) }
                if isDirty { confirmDiscard = true } else { dismiss() }
            }
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(recording != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Actions

    private func load() async {
        var deck = model.presentation(presentationID)
        if deck == nil {
            deck = await model.presentationsFilled([presentationID])[presentationID]
        }
        guard let deck else { return }
        presentationName = deck.name
        let sectionInfo = Dictionary(
            (deck.sections ?? []).map { ($0.id, ($0.name, $0.colorHex)) },
            uniquingKeysWith: { first, _ in first })
        let arranged = SlideSceneBuilder.arrangedSlides(for: deck, arrangementId: deck.defaultArrangementId)
        slides = arranged.enumerated().map { index, slide in
            let section = slide.sectionId.flatMap { sectionInfo[$0] }
            return SlideRow(
                id: index, slideID: slide.id,
                label: Self.slideLabel(slide, section: section?.0),
                color: Self.color(hex: section?.1 ?? nil) ?? .gray)
        }
        let liveRate = timecode?.editingRate ?? .fps25
        let draft: TimelineDraft
        if let timeline = deck.timeline {
            draft = TimelineDraft(
                cues: timeline.cues.map { .init(slideID: $0.slideId, time: $0.timeSeconds) },
                timecodeEnabled: timeline.timecodeEnabled, offset: timeline.offsetSeconds,
                duration: timeline.durationSeconds, rate: liveRate)
        } else {
            draft = TimelineDraft(cues: [], timecodeEnabled: true, offset: 3_600, rate: liveRate)
        }
        original = draft
        history = TimelineHistory(draft)
        startField = Self.absolute(draft.offset, rate: liveRate)
        durationField = draft.duration.map { Self.songTime($0, rate: liveRate, showFrames: false) } ?? ""
        if !(timecode?.enabled ?? false) { source = .local }
        canvasFocused = true
    }

    private func save() {
        guard let draft = current else { return }
        let timeline: PresentationTimeline? = draft.cues.isEmpty && !draft.timecodeEnabled
            ? nil
            : PresentationTimeline(
                timecodeEnabled: draft.timecodeEnabled,
                offsetSeconds: draft.offset,
                cues: draft.cues.map { TimelineCue(slideId: $0.slideID, timeSeconds: $0.time) },
                durationSeconds: draft.duration)
        model.updatePresentationField(
            presentationID, \.timeline, key: "timeline", to: timeline, undoLabel: "Edit Timeline")
        timecode?.resync()
        original = draft
        dismiss()
    }

    private func select(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    private func drag(_ id: UUID, translation: CGFloat) {
        guard let base = current else { return }
        if dragOrigin == nil {
            if !selection.contains(id) { selection = [id] }
            dragOrigin = base
            dragIDs = selection
        }
        guard let origin = dragOrigin, let anchor = origin.cue(id) else { return }
        var delta = Double(translation / pixelsPerSecond)
        let flags = NSEvent.modifierFlags
        if snapping, !flags.contains(.command),
           let target = origin.snapTarget(
               for: anchor.time + delta, excluding: dragIDs, playhead: playhead(),
               threshold: Double(8 / pixelsPerSecond)) {
            delta = target - anchor.time
        }
        var next = origin
        next.move(dragIDs, by: delta, ripple: flags.contains(.option))
        dragPreview = next
    }

    private func endDrag() {
        if let preview = dragPreview { history?.commit(preview) }
        dragOrigin = nil
        dragPreview = nil
        dragIDs = []
    }

    private func addCue(at time: Double) {
        guard let draft = current, let slideID = nextSlideID(after: time, in: draft) else { return }
        var newID: UUID?
        history?.edit { newID = $0.add(slideID: slideID, at: time) }
        if let newID { selection = [newID] }
    }

    private func slideClicked(_ row: SlideRow) {
        if var pass = recording {
            pass.tap(slideID: row.slideID, at: playhead(), arranged: slides.map(\.slideID))
            recording = pass
            return
        }
        var newID: UUID?
        history?.edit { newID = $0.add(slideID: row.slideID, at: playhead()) }
        if let newID { selection = [newID] }
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        history?.edit { $0.delete(selection) }
        selection = []
    }

    private func prune() {
        let live = Set(current?.cues.map(\.id) ?? [])
        selection = selection.intersection(live)
    }

    private func park(at time: Double) {
        clock.park(at: max(0, time))
    }

    private func togglePlay() {
        guard source == .local else { return }
        if clock.playing { clock.pause() } else { clock.play() }
    }

    // MARK: Recording

    /// While armed: start a pass as soon as the clock runs, end it when the clock
    /// stops. Polling keeps this correct no matter how the clock stops (track
    /// ends, cable pulled, Ableton stopped, local pause).
    private func recordLoop() async {
        guard recordArmed else { return }
        while recordArmed, !Task.isCancelled {
            if recording == nil, clockRunning, playheadInSong, let draft = current {
                recording = TimelineRecording(
                    start: max(0, playhead()), arranged: slides.map(\.slideID), existing: draft)
                timecode?.suppressFiring = true
            } else if recording != nil, !clockRunning {
                stopRecording(keep: true)
                return
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func stopRecording(keep: Bool) {
        if keep, let pass = recording, let draft = current {
            let end = max(playhead(), pass.taps.last?.time ?? pass.start)
            history?.commit(pass.applied(to: draft, end: end))
        }
        recording = nil
        recordArmed = false
        timecode?.suppressFiring = false
        timecode?.resync()
    }

    // MARK: Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let mods = press.modifiers
        switch press.key {
        case .leftArrow, .rightArrow:
            let sign = press.key == .leftArrow ? -1 : 1
            let step = mods.contains(.option) ? rate.nominalFrames : (mods.contains(.shift) ? 10 : 1)
            if selection.isEmpty || recording != nil {
                park(at: playhead() + Double(sign * step) / Double(rate.nominalFrames))
            } else {
                history?.edit { $0.nudge(selection, frames: sign * step) }
            }
            return .handled
        case .delete, .deleteForward:
            guard recording == nil else { return .ignored }
            deleteSelection()
            return .handled
        case .space:
            togglePlay()
            return .handled
        case .return:
            if var pass = recording {
                pass.advance(at: playhead(), arranged: slides.map(\.slideID))
                recording = pass
            } else {
                addCue(at: playhead())
            }
            return .handled
        case .escape:
            if recording != nil || recordArmed {
                stopRecording(keep: false)
            } else {
                selection = []
            }
            return .handled
        default:
            if press.characters == "z", recording != nil, mods.isEmpty {
                var pass = recording
                pass?.undoLastTap()
                recording = pass
                return .handled
            }
            return .ignored
        }
    }

    // MARK: Fields

    private func commitStart() {
        guard let tc = Timecode(string: startField) else {
            startField = Self.absolute(current?.offset ?? 0, rate: rate)
            return
        }
        let seconds = tc.labelSeconds(rate: rate)
        history?.edit { $0.offset = seconds }
        startField = Self.absolute(seconds, rate: rate)
    }

    private func commitDuration() {
        let trimmed = durationField.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "auto" {
            history?.edit { $0.duration = nil }
            durationField = ""
            return
        }
        guard let seconds = Self.parseSongTime(trimmed, rate: rate), seconds > 0 else {
            durationField = current?.duration.map { Self.songTime($0, rate: rate, showFrames: false) } ?? ""
            return
        }
        history?.edit { $0.duration = seconds }
    }

    private func commitCueTime(_ id: UUID) {
        guard let draft = current else { return }
        let text = cueTimeField.trimmingCharacters(in: .whitespaces)
        var seconds: Double?
        if text.split(separator: ":").count == 4, let tc = Timecode(string: text) {
            seconds = tc.labelSeconds(rate: rate) - draft.offset
        } else {
            seconds = Self.parseSongTime(text, rate: rate)
        }
        guard let seconds, seconds >= 0 else { syncCueTimeField(); return }
        history?.edit { $0.setTime(id, to: seconds) }
    }

    private func syncCueTimeField() {
        guard let draft = current, selection.count == 1, let id = selection.first, let cue = draft.cue(id) else {
            cueTimeField = ""
            return
        }
        cueTimeField = Self.songTime(cue.time, rate: rate)
    }

    // MARK: Formatting

    /// "M:SS:FF" from song-relative seconds.
    static func songTime(_ seconds: Double, rate: TimecodeRate, showFrames: Bool = true) -> String {
        let fps = rate.nominalFrames
        let totalFrames = Int((max(0, seconds) * Double(fps)).rounded())
        let frames = totalFrames % fps
        let totalSeconds = totalFrames / fps
        let m = totalSeconds / 60, s = totalSeconds % 60
        let ss = s < 10 ? "0\(s)" : "\(s)"
        guard showFrames else { return "\(m):\(ss)" }
        let ff = frames < 10 ? "0\(frames)" : "\(frames)"
        return "\(m):\(ss):\(ff)"
    }

    /// "HH:MM:SS:FF" from a timecode label in seconds.
    static func absolute(_ label: Double, rate: TimecodeRate) -> String {
        let fps = rate.nominalFrames
        let totalFrames = Int((max(0, label) * Double(fps)).rounded())
        let tc = Timecode(
            hours: (totalFrames / fps / 3600) % 24, minutes: (totalFrames / fps / 60) % 60,
            seconds: (totalFrames / fps) % 60, frames: totalFrames % fps)
        return tc.description
    }

    /// Parses "M:SS:FF", "M:SS", or plain seconds.
    static func parseSongTime(_ text: String, rate: TimecodeRate) -> Double? {
        let parts = text.split(separator: ":").map { String($0) }
        let fps = Double(rate.nominalFrames)
        switch parts.count {
        case 1: return Double(parts[0])
        case 2:
            guard let m = Int(parts[0]), let s = Double(parts[1]), s < 60 else { return nil }
            return Double(m) * 60 + s
        case 3:
            guard let m = Int(parts[0]), let s = Int(parts[1]), let f = Int(parts[2]),
                  s < 60, Double(f) < fps else { return nil }
            return Double(m * 60 + s) + Double(f) / fps
        default: return nil
        }
    }

    static func slideLabel(_ slide: Slide, section: String?) -> String {
        var text: String?
        for object in slide.objects where object.objectKind == .text {
            let trimmed = object.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let line = trimmed.split(whereSeparator: \.isNewline).first {
                text = String(line)
            }
            break
        }
        let name = slide.name.isEmpty ? nil : slide.name
        let parts = [section, text ?? name].compactMap { $0 }
        return parts.isEmpty ? "Slide" : parts.joined(separator: " · ")
    }

    static func color(hex: String?) -> Color? {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count >= 6, let value = UInt64(hex.prefix(6), radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// A silent local clock for editing without timecode.
struct EditorClock: Equatable {
    private(set) var playing = false
    private var anchorPosition: Double = 0
    private var anchorHost: Double = 0

    func position(at now: Double) -> Double {
        playing ? anchorPosition + (now - anchorHost) : anchorPosition
    }

    mutating func play(now: Double = CACurrentMediaTime()) {
        guard !playing else { return }
        anchorHost = now
        playing = true
    }

    mutating func pause(now: Double = CACurrentMediaTime()) {
        guard playing else { return }
        anchorPosition = position(at: now)
        playing = false
    }

    mutating func park(at position: Double, now: Double = CACurrentMediaTime()) {
        anchorPosition = position
        anchorHost = now
    }
}
