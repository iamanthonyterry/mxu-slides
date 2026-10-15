import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func mediaIDs(_ scene: RenderScene, layer id: String) -> [String] {
    scene.layers.first { $0.id == id }?.items.compactMap(\.content.mediaID) ?? []
}

@Suite struct ScreenTargetingTests {

    @Test func anEmptyChoiceMeansEveryScreen() {
        #expect(ScreenTargeting.normalized(nil) == nil)
        #expect(ScreenTargeting.normalized([]) == nil)
        #expect(ScreenTargeting.normalized([""]) == nil)
        #expect(ScreenTargeting.normalized(["a", ""]) == ["a"])
    }

    @Test func togglingAddsAndRemovesInAStableOrder() {
        var selected = ScreenTargeting.toggling("b", in: nil)
        #expect(selected == ["b"])
        selected = ScreenTargeting.toggling("a", in: selected)
        #expect(selected == ["a", "b"])
        selected = ScreenTargeting.toggling("b", in: selected)
        #expect(selected == ["a"])
        selected = ScreenTargeting.toggling("a", in: selected)
        #expect(selected == nil, "nothing left means every screen again")
    }

    @Test func summaryNamesOneScreenAndCountsSeveral() {
        let names = ["lobby": "Lobby", "stage": "Stage Wall"]
        #expect(ScreenTargeting.summary(nil) { names[$0] } == "All Screens")
        #expect(ScreenTargeting.summary(["lobby"]) { names[$0] } == "Lobby")
        #expect(ScreenTargeting.summary(["lobby", "stage"]) { names[$0] } == "2 Screens")
        #expect(ScreenTargeting.summary(["gone"]) { names[$0] } == "1 Screen")
    }

    @Test func aCueWithoutScreensShowsEverywhere() {
        let cue = CueMedia(mediaId: "m")
        #expect(!cue.isScreenTargeted)
        #expect(cue.shows(onScreen: "lobby"))
        #expect(cue.shows(onScreen: nil))
    }

    @Test func aTargetedCueShowsOnlyOnItsScreensAndOnTheProgramFeed() {
        let cue = CueMedia(mediaId: "m", screenIds: ["lobby"])
        #expect(cue.isScreenTargeted)
        #expect(cue.shows(onScreen: "lobby"))
        #expect(!cue.shows(onScreen: "sanctuary"))
        #expect(cue.shows(onScreen: nil), "the program feed and previews show everything")
    }
}

@Suite struct ScreenTargetedSceneTests {

    @Test func eachScreensSceneLeavesOutMediaMeantForOthers() {
        var state = ShowState()
        state.fire(media: CueMedia(mediaId: "everyone"), on: .loopingVideos)
        state.fire(media: CueMedia(mediaId: "lobby-only", screenIds: ["lobby"]), on: .videos)

        #expect(mediaIDs(state.scene(screenTarget: "lobby"), layer: "videos") == ["lobby-only"])
        #expect(mediaIDs(state.scene(screenTarget: "sanctuary"), layer: "videos").isEmpty)
        #expect(mediaIDs(state.scene(screenTarget: "sanctuary"), layer: "loopingVideos") == ["everyone"])
        #expect(mediaIDs(state.scene(), layer: "videos") == ["lobby-only"])
    }

    @Test func libraryLayersAreFilteredToo() {
        var state = ShowState()
        var stack = LayerStack.standard
        stack.addLayer(named: "Walls", id: "walls")
        state.layerStack = stack
        state.fire(media: CueMedia(mediaId: "wall", screenIds: ["a", "b"]), onLayer: "walls")

        #expect(mediaIDs(state.scene(screenTarget: "a"), layer: "walls") == ["wall"])
        #expect(mediaIDs(state.scene(screenTarget: "c"), layer: "walls").isEmpty)
    }

    @Test func refiringTheSameMediaForOtherScreensMovesIt() {
        var state = ShowState()
        state.fire(media: CueMedia(mediaId: "clip", screenIds: ["a"]), on: .videos)
        state.fire(media: CueMedia(mediaId: "clip", screenIds: ["b"]), on: .videos)
        #expect(state.liveMedia[.videos]?.screenIds == ["b"])
        #expect(mediaIDs(state.scene(screenTarget: "a"), layer: "videos").isEmpty)
        #expect(mediaIDs(state.scene(screenTarget: "b"), layer: "videos") == ["clip"])
    }

    @Test func firingAgainWithNoScreensBringsItBackEverywhere() {
        var state = ShowState()
        state.fire(media: CueMedia(mediaId: "clip", screenIds: ["a"]), on: .videos)
        state.fire(media: CueMedia(mediaId: "clip"), on: .videos)
        #expect(!state.hasScreenTargetedMedia)
        #expect(mediaIDs(state.scene(screenTarget: "z"), layer: "videos") == ["clip"])
    }

    @Test func clearingTheLayerClearsItsTargets() {
        var state = ShowState()
        state.fire(media: CueMedia(mediaId: "clip", screenIds: ["a"]), on: .videos)
        #expect(state.hasScreenTargetedMedia)
        state.clear(layer: .videos)
        #expect(!state.hasScreenTargetedMedia)
    }

    @Test func theSnapshotKeepsEachCuesScreens() {
        var state = ShowState()
        state.fire(media: CueMedia(mediaId: "clip", screenIds: ["lobby"]), on: .videos)
        state.fire(media: CueMedia(mediaId: "loop"), on: .loopingVideos)
        let actions = state.restoringActions(stack: .standard, presetID: nil)
        let clip = actions.first { $0.mediaId == "clip" }
        let loop = actions.first { $0.mediaId == "loop" }
        #expect(clip?.screenIds == ["lobby"])
        #expect(loop?.screenIds == nil)
    }
}
