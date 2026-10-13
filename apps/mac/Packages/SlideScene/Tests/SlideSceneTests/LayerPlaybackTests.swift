import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func wallStack() -> LayerStack {
    var stack = LayerStack.standard
    stack.addLayer(named: "Walls", id: "walls")
    stack.addLayer(named: "Bug", id: "bug")
    stack.move("bug", up: true)
    stack.move("bug", up: true)
    return stack
}

private func mediaIDs(_ scene: RenderScene, layer id: String) -> [String] {
    scene.layers.first { $0.id == id }?.items.compactMap(\.content.mediaID) ?? []
}

@Test func theSceneStacksLayersInTheirOrderAroundTheSlide() {
    var state = ShowState()
    #expect(state.scene().layers.map(\.id) == LayerKind.allCases.map(\.rawValue),
            "the standard stack composites exactly as it always has")

    state.layerStack = wallStack()
    #expect(state.scene().layers.map(\.id) == [
        "videoInput", "loopingVideos", "stillGraphics", "videos", "walls", "slide", "bug", "overlays", "alerts",
    ])
}

@Test func aSlideSendsItsMediaToLayersAndTheyPlayOnUntilReplacedOrCleared() {
    var state = ShowState()
    state.layerStack = wallStack()
    let opener = Slide(id: "a", name: "", objects: [], layerMedia: [
        CueMedia(mediaId: "wall-loop", layerId: "walls"),
        CueMedia(mediaId: "logo", layerId: "bug"),
        CueMedia(mediaId: "sky", layer: .loopingVideos),
    ])
    state.fire(slide: opener)
    #expect(mediaIDs(state.scene(), layer: "walls") == ["wall-loop"])
    #expect(mediaIDs(state.scene(), layer: "bug") == ["logo"])
    #expect(state.liveMedia[.loopingVideos]?.mediaId == "sky")
    #expect(state.wantedMedia().keys.contains("wall-loop"))

    state.fire(slide: Slide(id: "b", name: "", objects: []))
    #expect(mediaIDs(state.scene(), layer: "walls") == ["wall-loop"], "a slide with no media leaves the layers playing")

    state.fire(slide: Slide(id: "c", name: "", objects: [], layerMedia: [CueMedia(mediaId: "rain", layerId: "walls")]))
    #expect(mediaIDs(state.scene(), layer: "walls") == ["rain"])
    #expect(mediaIDs(state.scene(), layer: "bug") == ["logo"])

    state.clear(layerId: "bug")
    #expect(mediaIDs(state.scene(), layer: "bug").isEmpty)
    state.clear(function: .media)
    #expect(state.liveLayerMedia.isEmpty && state.liveMedia.isEmpty)
}

@Test func mediaForThisSlideOnlyLeavesWithTheSlide() {
    var state = ShowState()
    state.layerStack = wallStack()
    let sting = Slide(id: "a", name: "", objects: [], layerMedia: [
        CueMedia(mediaId: "sting", mode: .slideOnly, layerId: "walls"),
    ])
    state.fire(slide: sting)
    state.fire(slide: sting)
    #expect(state.liveLayerMedia["walls"]?.mediaId == "sting", "firing the same slide again keeps it")

    state.fire(slide: Slide(id: "b", name: "", objects: []))
    #expect(state.liveLayerMedia["walls"] == nil)

    state.fire(slide: sting)
    state.fire(media: CueMedia(mediaId: "loop"), onLayer: "walls")
    state.fire(slide: Slide(id: "b", name: "", objects: []))
    #expect(state.liveLayerMedia["walls"]?.mediaId == "loop", "media fired over it stays")
}

@Test func aLayersOwnLookAndALayerADeckNamesButThisLibraryLacks() {
    var state = ShowState()
    var stack = wallStack()
    stack.layers[stack.layers.firstIndex { $0.id == "walls" }!].opacity = 0.5
    stack.layers[stack.layers.firstIndex { $0.id == "walls" }!].blendMode = .screen
    stack.layers[stack.layers.firstIndex { $0.id == "walls" }!].scaleMode = .fit
    state.layerStack = stack
    state.fire(slide: Slide(id: "a", name: "", objects: [], layerMedia: [
        CueMedia(mediaId: "wall-loop", layerId: "walls"),
        CueMedia(mediaId: "elsewhere", layer: .stillGraphics, layerId: "another-campus-layer"),
    ]))
    let item = state.scene().layers.first { $0.id == "walls" }?.items.first
    #expect(item?.opacity == 0.5 && item?.blendMode == .screen)
    #expect(item?.content == .media(id: "wall-loop", scaleMode: .fit))
    #expect(state.liveMedia[.stillGraphics]?.mediaId == "elsewhere")
}

@Test func aSpanPlacesOneMediaAcrossItsScreens() {
    let screen = CGSize(width: 1920, height: 1080)
    let left = MediaSourceRect(x: 0, y: 0, width: 0.5, height: 1)
    let right = MediaSourceRect(x: 0.5, y: 0, width: 0.5, height: 1)
    let wide = CGSize(width: 3840, height: 1080)

    #expect(LayerSpans.frame(ofMedia: wide, scaleMode: .fill, slice: left, screen: screen)
        == CGRect(x: 0, y: 0, width: 3840, height: 1080))
    #expect(LayerSpans.frame(ofMedia: wide, scaleMode: .fill, slice: right, screen: screen)
        == CGRect(x: -1920, y: 0, width: 3840, height: 1080))

    let square = CGSize(width: 1080, height: 1080)
    #expect(LayerSpans.frame(ofMedia: square, scaleMode: .fit, slice: left, screen: screen)
        == CGRect(x: 1380, y: 0, width: 1080, height: 1080), "fitted media sits centred on the seam")
    #expect(LayerSpans.frame(ofMedia: square, scaleMode: .fill, slice: left, screen: screen)
        == CGRect(x: 0, y: -1380, width: 3840, height: 3840))
    #expect(LayerSpans.frame(ofMedia: nil, scaleMode: .fill, slice: right, screen: screen)
        == CGRect(x: -1920, y: 0, width: 3840, height: 1080), "media of unknown size stretches over the wall")
}

@Test func onlyTheSpannedLayerMovesAndOnlyOnItsScreens() {
    var state = ShowState()
    state.layerStack = wallStack()
    state.fire(slide: Slide(id: "a", name: "", objects: [], layerMedia: [
        CueMedia(mediaId: "wall-loop", layerId: "walls"),
        CueMedia(mediaId: "sky", layer: .loopingVideos),
    ]))
    let preset = OutputPreset(id: "p", name: "Sunday", assignments: [], layerSpans: [
        LayerSpan(layerId: "walls", targets: [
            LayerTarget(targetKind: .display, targetId: "left"),
            LayerTarget(targetKind: .display, targetId: "right"),
        ]),
        LayerSpan(layerId: "bug", targets: [LayerTarget(targetKind: .display, targetId: "left")]),
    ])
    let spans = LayerSpans.active(in: preset)
    #expect(Set(spans.keys) == ["walls"])
    #expect(LayerSpans.targets(of: spans) == ["left", "right"])

    let base = state.scene()
    let right = base.spanning(spans, onScreen: "right") { _ in CGSize(width: 3840, height: 1080) }
    let walls = right.layers.first { $0.id == "walls" }?.items.first
    #expect(walls?.frame == CGRect(x: -1920, y: 0, width: 3840, height: 1080))
    #expect(walls?.content == .media(id: "wall-loop", scaleMode: .stretch))
    #expect(right.layers.first { $0.id == "loopingVideos" } == base.layers.first { $0.id == "loopingVideos" })
    #expect(base.spanning(spans, onScreen: "lobby") { _ in nil } == base)
}
