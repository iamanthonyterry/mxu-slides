import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func fireMedia(_ id: String, layer: String? = nil) -> SlideAction {
    SlideAction(id: UUID().uuidString, kind: .fireMedia, layer: layer, mediaId: id)
}

@Suite struct MediaLayerOverrideTests {

    @Test func aMediaLayerOrALibraryLayerCanBeNamed() {
        #expect(SlideSceneBuilder.mediaLayerOverride(of: fireMedia("m", layer: "videos")) == "videos")
        #expect(SlideSceneBuilder.mediaLayerOverride(of: fireMedia("m", layer: "stillGraphics")) == "stillGraphics")
        #expect(SlideSceneBuilder.mediaLayerOverride(of: fireMedia("m", layer: "walls")) == "walls")
    }

    @Test func noLayerOrANonMediaLayerLeavesItToTheMedia() {
        #expect(SlideSceneBuilder.mediaLayerOverride(of: fireMedia("m")) == nil)
        #expect(SlideSceneBuilder.mediaLayerOverride(of: fireMedia("m", layer: "")) == nil)
        for reserved in ["slide", "overlays", "alerts", "videoInput"] {
            #expect(SlideSceneBuilder.mediaLayerOverride(of: fireMedia("m", layer: reserved)) == nil, "\(reserved)")
        }
    }

    @Test func otherActionsNeverCarryAMediaLayer() {
        let clear = SlideAction(id: "c", kind: .clearLayer, layer: "videos")
        #expect(SlideSceneBuilder.mediaLayerOverride(of: clear) == nil)
    }

    @Test func aSlideProtectsTheLayerItsCueIsSentTo() {
        var slide = Slide(id: "s", name: "", objects: [])
        slide.actions = [fireMedia("m", layer: "videos")]
        // The media would normally sit on the still-graphics layer.
        let protected = SlideSceneBuilder.protectedLayers(for: slide) { _ in .stillGraphics }
        #expect(protected.contains(.videos))
        #expect(!protected.contains(.stillGraphics))
    }

    @Test func aSlideWithoutAnOverrideStillProtectsTheMediasOwnLayer() {
        var slide = Slide(id: "s", name: "", objects: [])
        slide.actions = [fireMedia("m")]
        let protected = SlideSceneBuilder.protectedLayers(for: slide) { _ in .stillGraphics }
        #expect(protected.contains(.stillGraphics))
    }

    @Test func carriedMediaFollowsTheOverride() {
        var slide = Slide(id: "s", name: "", objects: [])
        slide.actions = [fireMedia("poster", layer: "videos")]
        let deck = Presentation(
            id: "p", name: "Deck", presentationKind: .deck, themeId: "", slides: [slide]
        )
        let carried = SlideSceneBuilder.carriedMedia(for: slide, presentation: deck) { _ in
            (.image, .foreground)
        }
        #expect(carried == [.videos: "poster"])
    }

    @Test func aLibraryLayerOverrideIsNotInTheCarriedMap() {
        var slide = Slide(id: "s", name: "", objects: [])
        slide.actions = [fireMedia("poster", layer: "walls")]
        let deck = Presentation(
            id: "p", name: "Deck", presentationKind: .deck, themeId: "", slides: [slide]
        )
        let carried = SlideSceneBuilder.carriedMedia(for: slide, presentation: deck) { _ in
            (.image, .foreground)
        }
        #expect(carried.isEmpty)
    }
}

@Suite struct LiveOutputSnapshotTests {

    private var ids: () -> String {
        var next = 0
        return {
            next += 1
            return "a\(next)"
        }
    }

    private func stack() -> LayerStack {
        var stack = LayerStack.standard
        stack.addLayer(named: "Walls", id: "walls")
        stack.addLayer(named: "Bug", id: "bug")
        stack.move("bug", up: true)
        stack.move("bug", up: true)
        return stack
    }

    @Test func nothingLiveGivesNoActions() {
        let state = ShowState()
        #expect(state.restoringActions(stack: .standard, presetID: nil).isEmpty)
    }

    @Test func aPresetAloneIsStillWorthRestoring() {
        let state = ShowState()
        let actions = state.restoringActions(stack: .standard, presetID: "sanctuary", makeID: ids)
        #expect(actions.map(\.kind) == [.switchOutputPreset])
        #expect(actions[0].presetId == "sanctuary")
    }

    @Test func presetComesFirstThenMediaByLayerThenOverlays() {
        var state = ShowState()
        state.layerStack = stack()
        state.fire(media: CueMedia(mediaId: "sky"), onLayer: "loopingVideos")
        state.fire(media: CueMedia(mediaId: "wall-loop"), onLayer: "walls")
        state.fire(media: CueMedia(mediaId: "logo"), onLayer: "bug")
        state.fire(overlay: Overlay(id: "lower-third", name: "Lower Third", objects: []))

        let actions = state.restoringActions(stack: stack(), presetID: "wide", makeID: ids)
        #expect(actions.map(\.kind) == [
            .switchOutputPreset, .fireMedia, .fireMedia, .fireMedia, .fireOverlay,
        ])
        let media = actions.filter { $0.kind == .fireMedia }
        #expect(Set(media.compactMap(\.layer)) == ["loopingVideos", "walls", "bug"])
        #expect(media.first { $0.layer == "walls" }?.mediaId == "wall-loop")
        #expect(media.first { $0.layer == "bug" }?.mediaId == "logo")
        #expect(actions.last?.overlayId == "lower-third")
    }

    @Test func everyMediaActionNamesItsLayerSoReplayLandsInTheSamePlace() {
        var state = ShowState()
        state.fire(media: CueMedia(mediaId: "clip"), onLayer: "videos")
        let actions = state.restoringActions(stack: .standard, presetID: nil, makeID: ids)
        #expect(actions.count == 1)
        #expect(actions[0].layer == "videos")
        #expect(SlideSceneBuilder.mediaLayerOverride(of: actions[0]) == "videos")
    }

    @Test func actionsGetDistinctIDs() {
        var state = ShowState()
        state.fire(media: CueMedia(mediaId: "a"), onLayer: "videos")
        state.fire(media: CueMedia(mediaId: "b"), onLayer: "stillGraphics")
        let actions = state.restoringActions(stack: .standard, presetID: "p")
        #expect(Set(actions.map(\.id)).count == actions.count)
    }
}
