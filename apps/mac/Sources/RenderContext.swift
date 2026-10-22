import Foundation
import MediaEngine
import Observation
import OutputEngine
import PresenterCore
import RenderEngine
import SlideScene

@MainActor
@Observable
final class RenderContext {
    let compositor: Compositor
    let media: MediaEngine
    let outputs: OutputManager
    let soak = MediaSoak()
    let sceneBox: Locked<RenderScene>

    let liveBox: Locked<RenderScene>

    let transitions = SceneTransitionEngine()

    private let variantEngines = Locked<[String: SceneTransitionEngine]>([:])

    private let screenEngines = Locked<[String: SceneTransitionEngine]>([:])

    private var lastVariantScenes: [String: RenderScene] = [:]

    private var lastScreenScenes: [String: RenderScene] = [:]

    var liveScreenTargets: Set<String> { Set(screenEngines.value.keys) }

    /// Every screen that shows the audience: displays assigned to the show
    /// and the audience screens of the layout.
    var audienceScreenTargets: Set<String> {
        var targets = Set<String>()
        for screen in outputs.placeholderScreens where outputs.role(forScreen: screen.id) == .audience {
            targets.insert(screen.id.uuidString)
        }
        for display in outputs.displays where outputs.assignedDisplays.contains(display.uuid) {
            targets.insert(display.uuid)
        }
        return targets
    }

    func screenTargets(shapedUnlike deck: CGSize) -> Set<String> {
        var targets = Set<String>()
        for screen in outputs.placeholderScreens where outputs.role(forScreen: screen.id) == .audience {
            let size = CGSize(width: screen.width, height: screen.height)
            if !ScreenCanvas(deck: deck, screen: size).isDeck { targets.insert(screen.id.uuidString) }
        }
        for display in outputs.displays where outputs.assignedDisplays.contains(display.uuid) {
            if !ScreenCanvas(deck: deck, screen: display.frame.size).isDeck { targets.insert(display.uuid) }
        }
        return targets
    }

    func screenSize(_ target: String) -> CGSize? {
        if let id = UUID(uuidString: target), let screen = outputs.placeholderScreens.first(where: { $0.id == id }) {
            return CGSize(width: screen.width, height: screen.height)
        }
        return outputs.displays.first { $0.uuid == target }?.frame.size
    }

    let confidenceBox: Locked<ConfidenceInfo>

    let confidenceLayoutsBox: Locked<[UUID: ConfidenceLayout]>

    let previewLayoutsBox: Locked<[String: ConfidenceLayout]>

    @ObservationIgnored weak var canvasView: MetalSceneView?

    var scene: RenderScene {
        didSet { sceneBox.value = scene }
    }

    var nextLiveTransitions: [LayerKind: SceneTransition] = [:]

    var nextLayerTransitions: [String: SceneTransition] = [:]

    var layerTransitions: [String: SceneTransition] = [:]

    private func transitionPicker() -> (RenderLayer) -> SceneTransition? {
        let stash = nextLiveTransitions
        let layerStash = nextLayerTransitions
        let own = layerTransitions
        return { layer in
            (layer.isBuiltIn ? stash[layer.kind] : layerStash[layer.id])
                ?? own[layer.id] ?? Self.roomDefault(for: layer.kind)
        }
    }

    static func roomDefault(for layer: LayerKind) -> SceneTransition? {
        let defaults = UserDefaults.standard
        switch layer {
        case .slide:
            guard let raw = defaults.string(forKey: "transition.slide.kind"),
                  let kind = TransitionKind(rawValue: raw)
            else { return nil }
            var stored = MediaTransition(transitionKind: kind)
            stored.durationSeconds =
                defaults.object(forKey: "transition.slide.duration") as? Double ?? 0.5
            return sceneTransition(from: stored)
        case .loopingVideos, .stillGraphics, .videos:

            let kind: TransitionKind
            if let raw = defaults.string(forKey: "transition.media.kind") {
                kind = TransitionKind(rawValue: raw) ?? .cut
            } else {
                kind = .dissolve
            }
            guard kind != .cut else { return nil }
            var stored = MediaTransition(transitionKind: kind)
            stored.durationSeconds =
                defaults.object(forKey: "transition.media.duration") as? Double ?? 0.7
            return sceneTransition(from: stored)
        default:
            return nil
        }
    }

    static func sceneTransition(from transition: MediaTransition?) -> SceneTransition? {
        guard let transition else { return nil }
        let duration = transition.durationSeconds ?? 0.5

        guard duration >= 0.05 else { return .cut }
        switch transition.transitionKind {
        case .cut: return .cut
        case .dissolve: return SceneTransition(kind: .dissolve, duration: duration)
        case .fadeBlack: return SceneTransition(kind: .fade(.black), duration: duration)
        case .fadeWhite: return SceneTransition(kind: .fade(.white), duration: duration)
        case .fadeColor:
            let plate = transition.colorHex.flatMap { ColorHex.color($0) } ?? .black
            return SceneTransition(kind: .fade(plate), duration: duration)
        case .blurDissolve: return SceneTransition(kind: .blurDissolve, duration: duration)
        case .filmBurn: return SceneTransition(kind: .filmBurn, duration: duration)
        }
    }

    var liveScene: RenderScene {
        didSet {
            liveBox.value = liveScene
            let transition = transitionPicker()
            nextLiveTransitions = [:]
            nextLayerTransitions = [:]
            transitions.push(liveScene, layerTransition: transition)
        }
    }

    func setLiveScenes(
        _ scene: RenderScene, variants: [String: RenderScene],
        screens: [String: RenderScene] = [:], screenLooks: [String: String] = [:]
    ) {
        let transition = transitionPicker()
        let previousBase = liveScene
        let previousVariants = lastVariantScenes
        let previousScreens = lastScreenScenes
        screenEngines.withLock { engines in
            for key in engines.keys where screens[key] == nil {
                engines.removeValue(forKey: key)
            }
            for (target, screenScene) in screens {
                let look = screenLooks[target]
                let shared = look.flatMap { variants[$0] } ?? scene
                let sharedBefore = look.flatMap { previousVariants[$0] } ?? previousBase
                guard let engine = engines[target] else {

                    guard screenScene != shared else { continue }
                    let engine = SceneTransitionEngine(initial: sharedBefore)
                    engines[target] = engine
                    engine.push(screenScene, layerTransition: transition)
                    continue
                }

                if screenScene == shared, previousScreens[target] == sharedBefore, engine.isSettled() {
                    engines.removeValue(forKey: target)
                    continue
                }
                engine.push(screenScene, layerTransition: transition)
            }
        }
        lastVariantScenes = variants
        lastScreenScenes = screens
        variantEngines.withLock { engines in
            for key in engines.keys where variants[key] == nil {
                engines.removeValue(forKey: key)
            }
            for (themeID, variant) in variants {
                let engine = engines[themeID] ?? SceneTransitionEngine(initial: variant)
                engines[themeID] = engine
                engine.push(variant, layerTransition: transition)
            }
        }
        liveScene = scene
    }

    func heldVariantMediaIDs(at date: Date = Date()) -> Set<String> {
        (Array(variantEngines.value.values) + Array(screenEngines.value.values)).reduce(into: Set<String>()) {
            $0.formUnion($1.heldMediaIDs(at: date))
        }
    }

    var confidenceInfo: ConfidenceInfo {
        get { confidenceBox.value }
        set { confidenceBox.value = newValue }
    }

    func previewProvider(for target: String) -> @Sendable () -> RenderScene {
        if let layoutID = PreviewTargetLogic.layoutID(for: target) {
            return { [confidenceBox, previewLayoutsBox] in
                previewLayoutsBox.value[layoutID].map {
                    ConfidenceSceneBuilder.scene(layout: $0, info: confidenceBox.value, at: Date())
                } ?? .empty
            }
        } else {
            return outputs.previewProvider(for: target)
        }
    }

    init?() {
        guard let compositor = try? Compositor(),
              let media = try? MediaEngine(device: compositor.device)
        else { return nil }
        self.compositor = compositor
        self.media = media
        self.outputs = OutputManager(compositor: compositor)
        let initialScene = RenderScene.sampleLyricScene()
        self.scene = initialScene
        self.sceneBox = Locked(initialScene)
        let initialLive = RenderScene(canvasSize: initialScene.canvasSize)
        self.liveScene = initialLive
        self.liveBox = Locked(initialLive)
        self.confidenceBox = Locked(ConfidenceInfo())
        self.confidenceLayoutsBox = Locked([:])
        self.previewLayoutsBox = Locked([:])
        compositor.mediaSource = media

        outputs.sceneProvider = { [transitions, confidenceBox] in
            let now = Date()
            return VisibilityRules.filteredScene(
                transitions.scene(at: now), info: confidenceBox.value, at: now
            )
        }

        outputs.variantSceneProvider = { [variantEngines, confidenceBox] themeID in
            guard let engine = variantEngines.value[themeID] else { return nil }
            let now = Date()
            return VisibilityRules.filteredScene(
                engine.scene(at: now), info: confidenceBox.value, at: now
            )
        }
        outputs.screenSceneProvider = { [screenEngines, confidenceBox] targetID in
            guard let engine = screenEngines.value[targetID] else { return nil }
            let now = Date()
            return VisibilityRules.filteredScene(
                engine.scene(at: now), info: confidenceBox.value, at: now
            )
        }

        SyncTestPlayback.install(outputs: outputs, media: media)
        outputs.confidenceSceneProvider = { [confidenceBox, confidenceLayoutsBox] screenID in
            let info = confidenceBox.value
            if let layout = confidenceLayoutsBox.value[screenID] {
                return ConfidenceSceneBuilder.scene(layout: layout, info: info, at: Date())
            }

            return ConfidenceSceneBuilder.scene(info: info, at: Date())
        }

        restorePlaceholderScreens()

        Task { @MainActor [media] in
            await LiveInputPlaceholder.register(into: media)
            ThumbnailStore.shared.markPlaceholdersReady()
        }

        outputs.placeholderConfigurationChanged = { [weak self] in
            self?.savePlaceholderScreens()
        }
    }

    private struct PlaceholderScreenConfig: Codable {
        var id: UUID
        var name: String
        var width: Int
        var height: Int
        var framesPerSecond: Int
        var deviceDisplayUUID: String?
        var deviceDisplayName: String?

        var role: String?

        var scaleMode: String?

        var adjustments: OutputAdjustments?

        var videoDelayFrames: Int?

        var masks: [OutputMask]?

        var slices: [OutputSliceConfig]?

        var placement: OutputPlacement?
    }

    private struct OutputSliceConfig: Codable {
        var id: UUID
        var name: String?
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var deviceDisplayUUID: String?
        var deviceDisplayName: String?
        var adjustments: OutputAdjustments?
        var videoDelayFrames: Int?
        var placement: OutputPlacement?
    }

    private static let placeholdersKey = "outputs.placeholderScreens"

    private static let placeholdersBackupKey = "outputs.placeholderScreens.backup-m43"

    func savePlaceholderScreens() {
        let configs = outputs.placeholderScreens.map { screen in
            PlaceholderScreenConfig(
                id: screen.id, name: screen.name,
                width: screen.width, height: screen.height,
                framesPerSecond: screen.framesPerSecond,
                deviceDisplayUUID: outputs.placeholderDevices[screen.id],
                deviceDisplayName: outputs.placeholderDeviceNames[screen.id],
                role: outputs.screenRoles[screen.id]?.rawValue,
                scaleMode: outputs.scaleModes[screen.id]?.rawValue,
                adjustments: outputs.outputAdjustments[screen.id],
                videoDelayFrames: outputs.videoDelays[screen.id],
                masks: outputs.screenMasks[screen.id],
                slices: outputs.screenSlices[screen.id].map { extras in
                    extras.map { slice in
                        OutputSliceConfig(
                            id: slice.id, name: slice.name,
                            x: slice.sourceRect.minX, y: slice.sourceRect.minY,
                            width: slice.sourceRect.width, height: slice.sourceRect.height,
                            deviceDisplayUUID: outputs.placeholderDevices[slice.id],
                            deviceDisplayName: outputs.placeholderDeviceNames[slice.id],
                            adjustments: outputs.outputAdjustments[slice.id],
                            videoDelayFrames: outputs.videoDelays[slice.id],
                            placement: outputs.slicePlacements[slice.id]
                        )
                    }
                },
                placement: outputs.slicePlacements[screen.id]
            )
        }
        let defaults = UserDefaults.standard
        if defaults.data(forKey: Self.placeholdersBackupKey) == nil,
           let existing = defaults.data(forKey: Self.placeholdersKey) {
            defaults.set(existing, forKey: Self.placeholdersBackupKey)
        }
        if let data = try? JSONEncoder().encode(configs) {
            defaults.set(data, forKey: Self.placeholdersKey)
        }
    }

    private func restorePlaceholderScreens() {
        guard let data = UserDefaults.standard.data(forKey: Self.placeholdersKey),
              let configs = try? JSONDecoder().decode([PlaceholderScreenConfig].self, from: data)
        else { return }
        for config in configs {
            outputs.addPlaceholderScreen(
                id: config.id, name: config.name,
                width: config.width, height: config.height,
                framesPerSecond: config.framesPerSecond
            )
            if let role = config.role.flatMap(ScreenRole.init(rawValue:)) {
                outputs.setRole(role, forScreen: config.id)
            }
            if let mode = config.scaleMode.flatMap(OutputScaleMode.init(rawValue:)) {
                outputs.setScaleMode(mode, forScreen: config.id)
            }
            if let adjustments = config.adjustments {
                outputs.setAdjustments(adjustments, forScreen: config.id)
            }
            if let masks = config.masks {
                outputs.setMasks(masks, forScreen: config.id)
            }
            if let placement = config.placement {
                outputs.setPlacement(placement, forSlice: config.id)
            }
            if let delay = config.videoDelayFrames {
                outputs.setVideoDelay(delay, forScreen: config.id)
            }
            if let device = config.deviceDisplayUUID {
                outputs.assignPlaceholderDevice(
                    placeholderID: config.id, displayUUID: device,
                    displayName: config.deviceDisplayName
                )
            }
            for slice in config.slices ?? [] {
                outputs.addSlice(
                    toScreen: config.id, id: slice.id, name: slice.name,
                    sourceRect: CGRect(
                        x: slice.x, y: slice.y, width: slice.width, height: slice.height)
                )
                if let adjustments = slice.adjustments {
                    outputs.setAdjustments(adjustments, forScreen: slice.id)
                }
                if let delay = slice.videoDelayFrames {
                    outputs.setVideoDelay(delay, forScreen: slice.id)
                }
                if let device = slice.deviceDisplayUUID {
                    outputs.assignPlaceholderDevice(
                        placeholderID: slice.id, displayUUID: device,
                        displayName: slice.deviceDisplayName
                    )
                }
                if let placement = slice.placement {
                    outputs.setPlacement(placement, forSlice: slice.id)
                }
            }
        }
    }
}
