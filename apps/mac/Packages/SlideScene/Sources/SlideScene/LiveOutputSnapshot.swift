import Foundation
import PresenterCore
import RenderEngine

extension ShowState {

    /// Actions that put the outputs back the way they are now: the output
    /// preset first (it decides which screens show which layers), then each
    /// media layer's cue sent to that layer by name, then the live overlays.
    ///
    /// Media is named by layer so replaying it lands where it sits now even
    /// when the media's own default layer is a different one. Live inputs are
    /// not included: they follow their own cue.
    public func restoringActions(
        stack: LayerStack, presetID: String?,
        makeID: () -> String = { UUID().uuidString }
    ) -> [SlideAction] {
        var actions: [SlideAction] = []

        if let presetID, !presetID.isEmpty {
            actions.append(SlideAction(id: makeID(), kind: .switchOutputPreset, presetId: presetID))
        }

        let reserved = Set(LayerKind.allCases.map(\.rawValue))
            .subtracting(SlideSceneBuilder.mediaLayerKinds.map(\.rawValue))
        var layerIDs = SlideSceneBuilder.mediaLayerKinds.map(\.rawValue)
        for layer in stack.belowSlide + stack.aboveSlide
        where !reserved.contains(layer.id) && !layerIDs.contains(layer.id) {
            layerIDs.append(layer.id)
        }
        for id in layerIDs {
            guard let cue = liveCue(onLayer: id), !cue.mediaId.isEmpty else { continue }
            var fire = SlideAction(id: makeID(), kind: .fireMedia, layer: id, mediaId: cue.mediaId)
            fire.screenIds = cue.screenIds
            actions.append(fire)
        }

        for overlay in liveOverlays {
            actions.append(SlideAction(id: makeID(), kind: .fireOverlay, overlayId: overlay.id))
        }
        return actions
    }
}
