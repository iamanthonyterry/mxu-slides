import OutputEngine
import PresenterCore
import RenderEngine
import SwiftUI

struct LayersPage: View {
    let outputs: OutputManager
    let presets: OutputPresetsController

    @State private var selectedLayerID: String?
    @State private var routingPresetID: String?

    private struct Target: Identifiable {
        let id: String
        let name: String
        let kind: OutputTargetKind
    }

    private enum Row: Identifiable {
        case fixed(LayerKind)
        case layer(ShowLayer)

        var id: String {
            switch self {
            case .fixed(let kind): kind.rawValue
            case .layer(let layer): layer.id
            }
        }

        var name: String {
            switch self {
            case .fixed(let kind): kind.displayName
            case .layer(let layer): layer.name
            }
        }
    }

    private static let nameColumnWidth: CGFloat = 176
    private static let cellWidth: CGFloat = 84
    private static let spanColumnWidth: CGFloat = 64
    private static let rowHeight: CGFloat = 30

    private var targets: [Target] {
        outputs.displays.map {
            Target(id: $0.uuid, name: $0.name, kind: .display)
        } + outputs.placeholderScreens
            .filter { outputs.role(forScreen: $0.id) != .confidence }
            .map {
                Target(id: $0.id.uuidString, name: $0.name, kind: .placeholderScreen)
            }
    }

    private var rows: [Row] {
        let stack = presets.layerStack
        return [.fixed(.alerts), .fixed(.overlays)]
            + stack.aboveSlide.reversed().map(Row.layer)
            + [.fixed(.slide)]
            + stack.belowSlide.reversed().map(Row.layer)
            + [.fixed(.videoInput)]
    }

    private var presetID: String? {
        if let routingPresetID, presets.preset(routingPresetID) != nil { return routingPresetID }
        if let active = presets.activePresetID, presets.preset(active) != nil { return active }
        return presets.presets.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Layers")
                    .font(.headline)
                Spacer()
                Button {
                    selectedLayerID = presets.addLayer()
                } label: {
                    Label("Add Layer", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Add a media layer. It starts directly under the slide; move it to restack it")
            }
            Text("Layers stack top to bottom as they composite. Media sent to a layer keeps playing there until something replaces or clears it. The layers and their names travel with your presentations; which screens show each layer is set here, per output preset, for this location.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            presetBar
            matrix
            if let layer = selectedLayerID.flatMap({ presets.layerStack.layer($0) }) {
                Divider()
                LayerSettings(presets: presets, layer: layer) { selectedLayerID = nil }
                    .id(layer.id)
                if let presetID, let span = presets.span(presetID: presetID, layer: layer.id) {
                    Divider()
                    SpanSettings(
                        presets: presets, presetID: presetID, layer: layer, span: span,
                        names: Dictionary(targets.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var presetBar: some View {
        HStack(spacing: 8) {
            if let presetID {
                Picker("Routing in", selection: Binding(
                    get: { presetID },
                    set: { routingPresetID = $0 }
                )) {
                    ForEach(presets.presets, id: \.id) { entry in
                        Text(entry.id == presets.activePresetID ? "\(entry.name) (active)" : entry.name)
                            .tag(entry.id)
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .help("The output preset whose screen routing and spans this grid edits")
                if presetID != presets.activePresetID {
                    Button("Make Active") { presets.activate(presetID) }
                        .controlSize(.small)
                        .help("Apply this preset's routing to the outputs now")
                }
            } else {
                Text("With no output preset, every layer shows on every screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("New Preset to Route Layers") {
                    if let id = presets.createPreset(fromBroadcastTemplate: false) {
                        presets.activate(id)
                        routingPresetID = id
                    }
                }
                .controlSize(.small)
            }
            Spacer()
        }
    }

    private var matrix: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(rows) { row in
                    Divider()
                    layerRow(row)
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Self.nameColumnWidth, height: 1)
            ForEach(targets) { target in
                Text(target.name.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 3)
                    .frame(width: Self.cellWidth)
                    .help(target.name)
            }
            Text("SPAN")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.3)
                .frame(width: Self.spanColumnWidth)
                .help("Stretch one layer across the screens it is routed to, left to right in the order shown, instead of repeating it on each")
        }
        .padding(.bottom, 4)
    }

    private func layerRow(_ row: Row) -> some View {
        let selected = selectedLayerID == row.id
        return HStack(spacing: 0) {
            nameCell(row, selected: selected)
            ForEach(targets) { target in
                routeCell(row, target: target)
            }
            spanCell(row)
        }
        .frame(height: Self.rowHeight)
        .background(selected ? Color.primary.opacity(0.06) : .clear)
    }

    @ViewBuilder
    private func nameCell(_ row: Row, selected: Bool) -> some View {
        switch row {
        case .fixed(let kind):
            HStack(spacing: 6) {
                Image(systemName: kind == .slide ? "rectangle.inset.filled" : "lock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Text(row.name)
                    .font(.caption.weight(kind == .slide ? .semibold : .regular))
                    .foregroundStyle(kind == .slide ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .frame(width: Self.nameColumnWidth)
            .help(kind == .slide
                  ? "The slide. Layers above this line composite over the words"
                  : "\(row.name) keeps its place in the stack")
        case .layer(let layer):
            Button {
                selectedLayerID = selected ? nil : layer.id
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(LayerTint.color(presets.layerStack.tintHex(ofLayer: layer.id)) ?? .gray)
                        .frame(width: 8, height: 8)
                        .frame(width: 14)
                    Text(layer.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                }
                .frame(width: Self.nameColumnWidth, height: Self.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show \(layer.name)'s settings")
            .contextMenu {
                Button("Move Up") { presets.moveLayer(layer.id, up: true) }
                    .disabled(!presets.layerStack.canMove(layer.id, up: true))
                Button("Move Down") { presets.moveLayer(layer.id, up: false) }
                    .disabled(!presets.layerStack.canMove(layer.id, up: false))
                if !layer.isBuiltIn {
                    Divider()
                    Button("Delete Layer", role: .destructive) { delete(layer) }
                }
            }
        }
    }

    @ViewBuilder
    private func routeCell(_ row: Row, target: Target) -> some View {
        if let presetID {
            let routed = presets.preset(presetID)?.shows(layer: row.id, onTarget: target.id) ?? true
            let slice = presets.spanSlice(presetID: presetID, layer: row.id, targetId: target.id)
            Button {
                presets.toggleLayer(
                    presetID: presetID, targetKind: target.kind, targetId: target.id, layer: row.id)
            } label: {
                Group {
                    if let slice, routed {
                        Text("\(slice.position) of \(slice.count)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.green)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Color.green.opacity(0.14), in: Capsule())
                    } else if routed {
                        Circle().fill(Color.green.opacity(0.9))
                            .frame(width: 9, height: 9)
                    } else {
                        Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                            .frame(width: 9, height: 9)
                    }
                }
                .frame(width: Self.cellWidth, height: Self.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(slice.map { "\(target.name) shows part \($0.position) of \($0.count) of \(row.name)" }
                  ?? "\(row.name) → \(target.name)")
        } else {
            Circle().fill(Color.green.opacity(0.35))
                .frame(width: 9, height: 9)
                .frame(width: Self.cellWidth, height: Self.rowHeight)
                .help("Every layer shows on every screen until an output preset routes them")
        }
    }

    @ViewBuilder
    private func spanCell(_ row: Row) -> some View {
        if case .layer(let layer) = row, let presetID {
            let spanning = presets.isSpanning(presetID: presetID, layer: layer.id)
            Button {
                presets.setSpanning(!spanning, presetID: presetID, layer: layer.id)
            } label: {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(spanning ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    .frame(width: 30, height: 20)
                    .background(
                        spanning ? Color.green.opacity(0.14) : Color.primary.opacity(0.04),
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
                    .frame(width: Self.spanColumnWidth, height: Self.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(spanning
                  ? "\(layer.name) stretches across its screens. Click to repeat it on each screen instead"
                  : "Stretch \(layer.name) across the screens it is routed to")
        } else {
            Color.clear
                .frame(width: Self.spanColumnWidth, height: Self.rowHeight)
        }
    }

    private func delete(_ layer: ShowLayer) {
        if selectedLayerID == layer.id { selectedLayerID = nil }
        presets.removeLayer(layer.id)
    }
}

private struct LayerSettings: View {
    let presets: OutputPresetsController
    let layer: ShowLayer
    let deselect: () -> Void

    @State private var name = ""
    @State private var opacity = 1.0
    @State private var confirmingDelete = false

    var body: some View {
        let stack = presets.layerStack
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                    .onSubmit(rename)
                Button {
                    presets.moveLayer(layer.id, up: true)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!stack.canMove(layer.id, up: true))
                .help("Move this layer up the stack. Past the slide, it composites over the words")
                Button {
                    presets.moveLayer(layer.id, up: false)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(!stack.canMove(layer.id, up: false))
                .help("Move this layer down the stack")
                Spacer()
                if !layer.isBuiltIn {
                    Button("Delete Layer", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .controlSize(.small)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("Color")
                    HStack(spacing: 6) {
                        ForEach(LayerTint.palette, id: \.self) { hex in
                            Button {
                                presets.updateLayer(layer.id) { $0.colorHex = hex }
                            } label: {
                                Circle().fill(LayerTint.color(hex) ?? .gray)
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        Circle().strokeBorder(
                                            Color.primary.opacity(stack.tintHex(ofLayer: layer.id) == hex ? 0.9 : 0),
                                            lineWidth: 2)
                                    )
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .help("This layer's color. Media sent to it carries a line of this color on slides")
                }
                GridRow {
                    label("Opacity")
                    HStack(spacing: 8) {
                        Slider(value: $opacity, in: 0...1) { editing in
                            if !editing { setOpacity() }
                        }
                        .frame(width: 180)
                        Text("\(Int((opacity * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                GridRow {
                    label("Blend")
                    Picker("Blend", selection: Binding(
                        get: { layer.blendMode ?? .normal },
                        set: { mode in presets.updateLayer(layer.id) { $0.blendMode = mode == .normal ? nil : mode } }
                    )) {
                        ForEach(BlendMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    label("Scaling")
                    Picker("Scaling", selection: Binding(
                        get: { layer.scaleMode ?? .fill },
                        set: { mode in presets.updateLayer(layer.id) { $0.scaleMode = mode == .fill ? nil : mode } }
                    )) {
                        Text("Fill").tag(MediaScaleMode.fill)
                        Text("Fit").tag(MediaScaleMode.fit)
                        Text("Stretch").tag(MediaScaleMode.stretch)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("How media sits in this layer when its shape differs from the screens it plays on")
                }
                GridRow {
                    label("Transition")
                    HStack(spacing: 8) {
                        Picker("Transition", selection: Binding(
                            get: { layer.transition?.transitionKind.rawValue ?? "" },
                            set: { raw in setTransition(TransitionKind(rawValue: raw)) }
                        )) {
                            Text("App Default").tag("")
                            Divider()
                            Text("Cut").tag(TransitionKind.cut.rawValue)
                            Text("Dissolve").tag(TransitionKind.dissolve.rawValue)
                            Text("Fade Black").tag(TransitionKind.fadeBlack.rawValue)
                            Text("Fade White").tag(TransitionKind.fadeWhite.rawValue)
                            Text("Blur Dissolve").tag(TransitionKind.blurDissolve.rawValue)
                            Text("Film Burn").tag(TransitionKind.filmBurn.rawValue)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if let transition = layer.transition, transition.transitionKind != .cut {
                            Stepper(
                                value: Binding(
                                    get: { transition.durationSeconds ?? 0.5 },
                                    set: { seconds in
                                        presets.updateLayer(layer.id) { $0.transition?.durationSeconds = seconds }
                                    }
                                ),
                                in: 0.1...10, step: 0.1
                            ) {
                                Text(String(format: "%.1f s", transition.durationSeconds ?? 0.5))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .help("How media arriving on this layer replaces what was playing there")
                }
            }
            .controlSize(.small)
        }
        .task(id: "\(layer.name)|\(layer.opacity ?? 1)") {
            name = layer.name
            opacity = layer.opacity ?? 1
        }
        .confirmationDialog(
            "Delete “\(layer.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Layer", role: .destructive) {
                deselect()
                presets.removeLayer(layer.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Media that presentations send to this layer will play on its built-in layer instead.")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != layer.name else {
            name = layer.name
            return
        }
        presets.updateLayer(layer.id) { $0.name = trimmed }
    }

    private func setOpacity() {
        let value = (opacity * 100).rounded() / 100
        guard value != (layer.opacity ?? 1) else { return }
        presets.updateLayer(layer.id) { $0.opacity = value >= 1 ? nil : value }
    }

    private func setTransition(_ kind: TransitionKind?) {
        let seconds = layer.transition?.durationSeconds ?? 0.5
        presets.updateLayer(layer.id) { layer in
            layer.transition = kind.map {
                Transition(transitionKind: $0, durationSeconds: $0 == .cut ? nil : seconds)
            }
        }
    }
}

enum LayerTint {
    static let palette = LayerStack.palette

    static func color(_ hex: String?) -> Color? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16)
        else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private struct SpanSettings: View {
    let presets: OutputPresetsController
    let presetID: String
    let layer: ShowLayer
    let span: LayerSpan
    let names: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Span")
                    .font(.caption.weight(.semibold))
                Text("\(layer.name) across \(span.targets.count) screens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Split Evenly") {
                    presets.updateSpan(presetID: presetID, layer: layer.id) { $0.space(gap: 0) }
                }
                .controlSize(.small)
                .disabled(span.targets.allSatisfy { $0.source == nil })
                .help("Give every screen an equal slice with no gap between them")
            }
            HStack(spacing: 8) {
                Text("Gap between screens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    value: Binding(
                        get: { ((span.gap ?? 0) * 100).rounded() },
                        set: { percent in
                            presets.updateSpan(presetID: presetID, layer: layer.id) { $0.space(gap: percent / 100) }
                        }
                    ),
                    in: 0...(LayerSpan.greatestGap * 100), step: 1
                ) {
                    Text(span.gap.map { "\(Int(($0 * 100).rounded()))% of a screen" } ?? "Uneven")
                        .font(.caption.monospacedDigit())
                        .frame(width: 104, alignment: .leading)
                }
                .controlSize(.small)
                .help("The space between screens, as a share of one screen's width. The picture skips that much so it lines up across the gap")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("SCREEN")
                    Text("STARTS AT")
                    Text("WIDTH")
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.3)
                ForEach(span.targets, id: \.targetId) { target in
                    if let slice = span.source(forTarget: target.targetId) {
                        GridRow {
                            Text(names[target.targetId] ?? "Missing Screen")
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            PercentField(value: slice.x) { start in
                                presets.updateSpan(presetID: presetID, layer: layer.id) {
                                    $0.setSlice(ofTarget: target.targetId, start: start, width: slice.width)
                                }
                            }
                            PercentField(value: slice.width) { width in
                                presets.updateSpan(presetID: presetID, layer: layer.id) {
                                    $0.setSlice(ofTarget: target.targetId, start: slice.x, width: width)
                                }
                            }
                        }
                    }
                }
            }
            Text("Each screen shows its slice of the layer, measured across the whole wall. Change a slice for screens of different sizes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PercentField: View {
    let value: Double
    let commit: (Double) -> Void

    @State private var text = ""

    var body: some View {
        HStack(spacing: 3) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
                .onSubmit(submit)
            Text("%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: value) { text = Self.format(value) }
    }

    private static func format(_ value: Double) -> String {
        let percent = (value * 1000).rounded() / 10
        return percent == percent.rounded() ? String(Int(percent)) : String(format: "%.1f", percent)
    }

    private func submit() {
        guard let percent = Double(text.replacingOccurrences(of: ",", with: ".")), percent >= 0, percent <= 100 else {
            text = Self.format(value)
            return
        }
        commit(percent / 100)
    }
}

struct LayerMediaChip: View {
    let model: AppModel
    let cue: CueMedia
    let layer: ShowLayer
    var width: CGFloat = 30

    var body: some View {
        let tint = LayerTint.color(model.layerStack.tintHex(ofLayer: layer.id)) ?? .gray
        VStack(spacing: 0) {
            Rectangle().fill(tint)
                .frame(height: max(3, width / 10))
            Color.black
                .overlay { PosterImage(model: model, mediaId: cue.mediaId) }
                .clipped()
                .frame(height: (width * 9 / 16).rounded())
        }
        .frame(width: width)
        .clipShape(RoundedRectangle.standard(3))
        .overlay(RoundedRectangle.standard(3).strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
        .help("\(model.media(cue.mediaId)?.name ?? "Missing media") plays on \(layer.name)")
    }
}

struct LayerMediaColumns: View {
    let model: AppModel
    let columns: [(mediaId: String, layer: ShowLayer)]

    static func columns(
        model: AppModel, render: RenderContext?, slide: Slide, carried: [(layerId: String, mediaId: String)] = []
    ) -> [(mediaId: String, layer: ShowLayer)] {
        var screens: [String] = []
        if let outputs = render?.outputs {
            screens = outputs.displays.map(\.uuid)
                + outputs.placeholderScreens
                .filter { outputs.role(forScreen: $0.id) != .confidence }
                .map(\.id.uuidString)
        }
        _ = model.version(of: .outputPreset)
        let preset = UserDefaults.standard.string(forKey: OutputPresetsController.activeKey)
            .flatMap { model.resident.outputPresets.value($0) }
        return model.layerStack.previewColumns(of: slide, carried: carried, routedBy: preset, screens: screens)
    }

    var body: some View {
        let stack = model.layerStack
        if !columns.isEmpty {
            GeometryReader { proxy in
                let line = max(3, (proxy.size.height * 0.045).rounded())
                HStack(spacing: 1) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, entry in
                        Color.black
                            .overlay { PosterImage(model: model, mediaId: entry.mediaId) }
                            .clipped()
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(LayerTint.color(stack.tintHex(ofLayer: entry.layer.id)) ?? .gray)
                                    .frame(height: line)
                            }
                            .help("\(model.media(entry.mediaId)?.name ?? "Missing media") plays on \(entry.layer.name)")
                    }
                }
            }
        }
    }
}
