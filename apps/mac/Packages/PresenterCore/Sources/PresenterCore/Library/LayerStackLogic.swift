import Foundation

public extension LayerStack {

    static let wellKnownID = "layer-stack"

    static let standard = LayerStack(id: wellKnownID, layers: [
        ShowLayer(id: CueMediaLayer.loopingVideos.rawValue, name: "Background Media"),
        ShowLayer(id: CueMediaLayer.stillGraphics.rawValue, name: "Still Graphics"),
        ShowLayer(id: CueMediaLayer.videos.rawValue, name: "Foreground Videos"),
    ])

    func layer(_ id: String) -> ShowLayer? {
        layers.first { $0.id == id }
    }

    var belowSlide: [ShowLayer] { layers.filter { $0.aboveSlide != true } }

    var aboveSlide: [ShowLayer] { layers.filter { $0.aboveSlide == true } }

    var topDown: [ShowLayer] { Array(aboveSlide.reversed()) + Array(belowSlide.reversed()) }

    func canMove(_ id: String, up: Bool) -> Bool {
        guard let layer = layer(id) else { return false }
        let above = layer.aboveSlide == true
        let peers = (above ? aboveSlide : belowSlide).reversed().map(\.id)
        if up { return !above || peers.first != id }
        return above || peers.last != id
    }

    mutating func move(_ id: String, up: Bool) {
        guard canMove(id, up: up) else { return }
        var order: [String?] = aboveSlide.reversed().map(\.id) + [nil] + belowSlide.reversed().map(\.id)
        guard let index = order.firstIndex(of: id) else { return }
        order.swapAt(index, up ? index - 1 : index + 1)
        let slide = order.firstIndex(of: nil) ?? 0
        var reordered: [ShowLayer] = []
        for (position, entry) in order.enumerated().reversed() {
            guard let entry, var moved = layer(entry) else { continue }
            moved.aboveSlide = position < slide ? true : nil
            reordered.append(moved)
        }
        layers = reordered
    }

    @discardableResult
    mutating func addLayer(named name: String? = nil, id: String = UUID().uuidString) -> ShowLayer {
        var number = layers.count + 1
        while name == nil, layers.contains(where: { $0.name == "Layer \(number)" }) { number += 1 }
        let layer = ShowLayer(id: id, name: name ?? "Layer \(number)")
        layers.insert(layer, at: belowSlide.count)
        return layer
    }

    mutating func removeLayer(_ id: String) {
        layers.removeAll { $0.id == id && !$0.isBuiltIn }
    }

    func resolvedLayerId(for media: CueMedia) -> String {
        if let id = media.layerId, layer(id) != nil { return id }
        return (media.layer ?? .loopingVideos).rawValue
    }
}

public extension ShowLayer {

    var isBuiltIn: Bool { CueMediaLayer(rawValue: id) != nil }
}

public extension OutputPreset {

    func shows(layer layerId: String, onTarget targetId: String) -> Bool {
        guard let assignment = assignments.first(where: { $0.targetId == targetId }) else { return true }
        return assignment.enabledLayers.contains(layerId)
    }

    mutating func respan(layer layerId: String, across ordered: [LayerTarget]) {
        guard let index = layerSpans?.firstIndex(where: { $0.layerId == layerId }) else { return }
        let before = layerSpans?[index].targets ?? []
        let kept = Dictionary(before.map { ($0.targetId, $0) }, uniquingKeysWith: { first, _ in first })
        let routed = ordered.filter { shows(layer: layerId, onTarget: $0.targetId) }
        let sameScreens = Set(routed.map(\.targetId)) == Set(before.map(\.targetId))
        layerSpans?[index].targets = routed.map { target in
            var target = target
            target.source = sameScreens ? kept[target.targetId]?.source : nil
            return target
        }
    }

    mutating func setSpanning(_ spanning: Bool, layer layerId: String, across ordered: [LayerTarget]) {
        layerSpans?.removeAll { $0.layerId == layerId }
        if spanning {
            layerSpans = (layerSpans ?? []) + [LayerSpan(layerId: layerId, targets: [])]
            respan(layer: layerId, across: ordered)
        } else if layerSpans?.isEmpty == true {
            layerSpans = nil
        }
    }

    mutating func updateSpan(ofLayer layerId: String, _ mutate: (inout LayerSpan) -> Void) {
        guard let index = layerSpans?.firstIndex(where: { $0.layerId == layerId }) else { return }
        mutate(&layerSpans![index])
    }

    var spanningLayerIds: Set<String> { Set((layerSpans ?? []).map(\.layerId)) }

    func span(ofLayer layerId: String) -> LayerSpan? {
        layerSpans?.first { $0.layerId == layerId && $0.targets.count > 1 }
    }
}

public extension LayerSpan {

    static let greatestGap = 1.0

    mutating func space(gap: Double) {
        let gap = min(max(gap, 0), Self.greatestGap)
        guard targets.count > 1 else { return }
        if gap == 0 {
            for index in targets.indices { targets[index].source = nil }
            return
        }
        let count = Double(targets.count)
        let width = 1 / (count + (count - 1) * gap)
        for index in targets.indices {
            targets[index].source = MediaSourceRect(
                x: Double(index) * width * (1 + gap), y: 0, width: width, height: 1)
        }
    }

    var gap: Double? {
        guard targets.count > 1 else { return nil }
        let slices = targets.compactMap { source(forTarget: $0.targetId) }
        guard let width = slices.first?.width, width > 0 else { return nil }
        let step = slices[1].x - slices[0].x
        for (index, slice) in slices.enumerated() {
            guard abs(slice.width - width) < 0.0005, abs(slice.x - Double(index) * step) < 0.0005,
                  slice.y == 0, slice.height == 1 else { return nil }
        }
        return max(0, (step / width - 1) * 1000).rounded() / 1000
    }

    mutating func setSlice(ofTarget targetId: String, start: Double, width: Double) {
        guard let index = targets.firstIndex(where: { $0.targetId == targetId }) else { return }
        let width = min(max(width, 0.01), 1)
        let start = min(max(start, 0), 1 - width)
        targets[index].source = MediaSourceRect(x: start, y: 0, width: width, height: 1)
    }

    func source(forTarget targetId: String) -> MediaSourceRect? {
        guard let index = targets.firstIndex(where: { $0.targetId == targetId }) else { return nil }
        if let source = targets[index].source { return source }
        let share = 1 / Double(targets.count)
        return MediaSourceRect(x: Double(index) * share, y: 0, width: share, height: 1)
    }
}

public extension CueMedia {

    static func onLayer(_ layerId: String, for item: MediaItem) -> CueMedia {
        var media = CueMedia(
            mediaId: item.id, loops: item.mediaKind == .video ? true : nil, classification: .background)
        media.setLayer(layerId)
        return media
    }

    mutating func setLayer(_ id: String) {
        if let builtIn = CueMediaLayer(rawValue: id) {
            layer = builtIn
            layerId = nil
        } else {
            layerId = id
        }
    }
}

public extension LayerStack {

    static let palette = ["#E5484D", "#F2994A", "#F2C94C", "#30A46C", "#3E9BE9", "#8E6FE0", "#D6409F"]

    func tintHex(ofLayer id: String) -> String {
        if let chosen = layer(id)?.colorHex, !chosen.isEmpty { return chosen }
        let index = layers.firstIndex { $0.id == id } ?? 0
        return Self.palette[index % Self.palette.count]
    }

    func layerCues(of slide: Slide) -> [(cue: CueMedia, layer: ShowLayer)] {
        let cues = (slide.layerMedia ?? []).filter { !$0.mediaId.isEmpty }
        return topDown.flatMap { layer in
            cues.filter { resolvedLayerId(for: $0) == layer.id }.map { ($0, layer) }
        }
    }

    func layerCues(
        of slide: Slide, routedBy preset: OutputPreset?, screens: [String]
    ) -> [(cue: CueMedia, layer: ShowLayer)] {
        routed(layerCues(of: slide), by: preset, screens: screens) { $0.layer }
    }

    func previewColumns(
        of slide: Slide, carried: [(layerId: String, mediaId: String)],
        routedBy preset: OutputPreset?, screens: [String]
    ) -> [(mediaId: String, layer: ShowLayer)] {
        var columns = layerCues(of: slide).map { (mediaId: $0.cue.mediaId, layer: $0.layer) }
        for entry in carried where !entry.mediaId.isEmpty && !columns.contains(where: { $0.layer.id == entry.layerId }) {
            columns.append((entry.mediaId, layer(entry.layerId) ?? ShowLayer(id: entry.layerId, name: entry.layerId)))
        }
        let order = topDown.map(\.id)
        func depth(_ layer: ShowLayer) -> Int { order.firstIndex(of: layer.id) ?? order.count }
        let stacked = columns.enumerated()
            .sorted { (depth($0.element.layer), $0.offset) < (depth($1.element.layer), $1.offset) }
            .map(\.element)
        return routed(stacked, by: preset, screens: screens) { $0.layer }
    }

    private func routed<Entry>(
        _ entries: [Entry], by preset: OutputPreset?, screens: [String], layer: (Entry) -> ShowLayer
    ) -> [Entry] {
        guard let preset, !screens.isEmpty else { return entries }
        func firstScreen(_ entry: Entry) -> Int {
            screens.firstIndex { preset.shows(layer: layer(entry).id, onTarget: $0) } ?? screens.count
        }
        return entries.enumerated()
            .sorted { (firstScreen($0.element), $0.offset) < (firstScreen($1.element), $1.offset) }
            .map(\.element)
    }

    func layerMediaIDs(of slide: Slide) -> (below: [String], above: [String]) {
        var below: [String] = []
        var above: [String] = []
        let cues = (slide.layerMedia ?? []).filter { !$0.mediaId.isEmpty }
        for layer in layers {
            for cue in cues where resolvedLayerId(for: cue) == layer.id {
                if layer.aboveSlide == true { above.append(cue.mediaId) } else { below.append(cue.mediaId) }
            }
        }
        return (below, above)
    }
}

public extension Slide {

    private func layerMediaIndex(_ mediaId: String, onLayer layerId: String, in stack: LayerStack) -> Int? {
        layerMedia?.firstIndex { $0.mediaId == mediaId && stack.resolvedLayerId(for: $0) == layerId }
    }

    mutating func editLayerMedia(
        _ mediaId: String, onLayer layerId: String, in stack: LayerStack, _ mutate: (inout CueMedia) -> Void
    ) {
        guard let index = layerMediaIndex(mediaId, onLayer: layerId, in: stack) else { return }
        mutate(&layerMedia![index])
    }

    mutating func removeLayerMedia(_ mediaId: String, onLayer layerId: String, in stack: LayerStack) {
        guard let index = layerMediaIndex(mediaId, onLayer: layerId, in: stack) else { return }
        layerMedia?.remove(at: index)
        if layerMedia?.isEmpty == true { layerMedia = nil }
    }

    mutating func moveLayerMedia(
        _ mediaId: String, fromLayer layerId: String, toLayer destination: String, in stack: LayerStack
    ) {
        guard destination != layerId, let index = layerMediaIndex(mediaId, onLayer: layerId, in: stack),
              var cue = layerMedia?[index] else { return }
        cue.setLayer(destination)
        layerMedia = (layerMedia ?? []).enumerated()
            .filter { $0.offset != index && stack.resolvedLayerId(for: $0.element) != destination }
            .map(\.element) + [cue]
    }

    mutating func send(_ item: MediaItem, toLayer layerId: String, in stack: LayerStack) {
        let kept = (layerMedia ?? []).filter { stack.resolvedLayerId(for: $0) != layerId }
        layerMedia = kept + [CueMedia.onLayer(layerId, for: item)]
    }

    func openLayer(in stack: LayerStack) -> String {
        let taken = Set((layerMedia ?? []).map { stack.resolvedLayerId(for: $0) })
        let layers = stack.topDown
        return (layers.first { !$0.isBuiltIn && !taken.contains($0.id) }
            ?? layers.first { !taken.contains($0.id) }
            ?? layers.first)?.id ?? CueMediaLayer.loopingVideos.rawValue
    }
}
