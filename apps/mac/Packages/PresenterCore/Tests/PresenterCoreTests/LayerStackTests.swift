import Foundation
import Testing
@testable import PresenterCore

@Test func aCueWithNoLayerOfItsOwnLandsOnItsBuiltInLayer() {
    let stack = LayerStack.standard
    #expect(stack.resolvedLayerId(for: CueMedia(mediaId: "m", layer: .videos)) == "videos")
    #expect(stack.resolvedLayerId(for: CueMedia(mediaId: "m")) == "loopingVideos")
}

@Test func aCueNamingALayerThisLibraryLacksFallsBackToItsBuiltInLayer() {
    var stack = LayerStack.standard
    stack.layers.append(ShowLayer(id: "walls", name: "Side Walls", aboveSlide: true))
    #expect(stack.resolvedLayerId(for: CueMedia(mediaId: "m", layerId: "walls")) == "walls")
    #expect(stack.resolvedLayerId(for: CueMedia(mediaId: "m", layer: .stillGraphics, layerId: "gone")) == "stillGraphics")
    #expect(stack.aboveSlide.map(\.id) == ["walls"])
    #expect(stack.belowSlide.map(\.id) == ["loopingVideos", "stillGraphics", "videos"])
}

@Test func aSpanSplitsTheLayerEvenlyAcrossItsScreensUnlessAScreenSaysOtherwise() {
    let span = LayerSpan(layerId: "walls", targets: [
        LayerTarget(targetKind: .display, targetId: "left"),
        LayerTarget(targetKind: .display, targetId: "centre",
                    source: MediaSourceRect(x: 0.3, y: 0, width: 0.4, height: 1)),
        LayerTarget(targetKind: .placeholderScreen, targetId: "right"),
        LayerTarget(targetKind: .display, targetId: "far"),
    ])
    #expect(span.source(forTarget: "left") == MediaSourceRect(x: 0, y: 0, width: 0.25, height: 1))
    #expect(span.source(forTarget: "centre") == MediaSourceRect(x: 0.3, y: 0, width: 0.4, height: 1))
    #expect(span.source(forTarget: "far") == MediaSourceRect(x: 0.75, y: 0, width: 0.25, height: 1))
    #expect(span.source(forTarget: "elsewhere") == nil)

    let preset = OutputPreset(id: "p", name: "Sunday", assignments: [], layerSpans: [
        span, LayerSpan(layerId: "solo", targets: [LayerTarget(targetKind: .display, targetId: "left")]),
    ])
    #expect(preset.span(ofLayer: "walls") == span)
    #expect(preset.span(ofLayer: "solo") == nil, "one screen is not a span")
}

@Test func documentsSavedBeforeLayersStillDecode() throws {
    let slide = try JSONDecoder().decode(Slide.self, from: Data(#"{"id":"s","name":"","objects":[]}"#.utf8))
    #expect(slide.layerMedia == nil)
    let preset = try JSONDecoder().decode(
        OutputPreset.self, from: Data(#"{"id":"p","name":"n","assignments":[]}"#.utf8))
    #expect(preset.layerSpans == nil)
    #expect(DocumentKind.layerStack.directoryName == "layer-stack")
    #expect(SyncScope.scope(for: .layerStack) == .team)
}

@Test func aLayerMovesThroughTheStackAndAcrossTheSlide() {
    var stack = LayerStack.standard
    stack.addLayer(named: "Walls", id: "walls")
    #expect(stack.topDown.map(\.id) == ["walls", "videos", "stillGraphics", "loopingVideos"])
    #expect(stack.canMove("walls", up: true), "the top layer under the slide can rise above it")

    stack.move("walls", up: true)
    #expect(stack.aboveSlide.map(\.id) == ["walls"])
    #expect(!stack.canMove("walls", up: true))
    #expect(stack.topDown.map(\.id) == ["walls", "videos", "stillGraphics", "loopingVideos"])

    stack.move("walls", up: false)
    #expect(stack.aboveSlide.isEmpty)
    stack.move("walls", up: false)
    #expect(stack.topDown.map(\.id) == ["videos", "walls", "stillGraphics", "loopingVideos"])

    #expect(!stack.canMove("loopingVideos", up: false))
    stack.move("loopingVideos", up: false)
    #expect(stack.topDown.last?.id == "loopingVideos")
}

@Test func newLayersGetTheirOwnNamesAndBuiltInLayersStay() {
    var stack = LayerStack.standard
    #expect(stack.addLayer().name == "Layer 4")
    #expect(stack.addLayer().name == "Layer 5")
    let added = stack.addLayer(named: "Stream Bug")
    stack.removeLayer(added.id)
    stack.removeLayer("videos")
    #expect(stack.layers.map(\.name).contains("Stream Bug") == false)
    #expect(stack.layer("videos") != nil, "the built-in layers hold media existing decks already send")
}

@Test func aSpanFollowsTheScreensItsLayerIsRoutedToInScreenOrder() {
    let screens = ["left", "centre", "right"].map { LayerTarget(targetKind: .display, targetId: $0) }
    var preset = OutputPreset(id: "p", name: "Sunday", assignments: [
        OutputAssignment(targetKind: .display, targetId: "centre", enabledLayers: ["slide"]),
    ])
    #expect(preset.shows(layer: "walls", onTarget: "left"), "a screen with no routing shows every layer")
    #expect(!preset.shows(layer: "walls", onTarget: "centre"))

    preset.setSpanning(true, layer: "walls", across: screens)
    #expect(preset.span(ofLayer: "walls")?.targets.map(\.targetId) == ["left", "right"])
    #expect(preset.spanningLayerIds == ["walls"])

    preset.layerSpans?[0].targets[1].source = MediaSourceRect(x: 0.6, y: 0, width: 0.4, height: 1)
    preset.respan(layer: "walls", across: screens)
    #expect(preset.layerSpans?[0].targets[1].source?.x == 0.6, "a screen keeps the slice it was given")

    preset.assignments[0].enabledLayers.append("walls")
    preset.respan(layer: "walls", across: screens)
    #expect(preset.span(ofLayer: "walls")?.targets.map(\.targetId) == ["left", "centre", "right"])
    #expect(preset.layerSpans?[0].targets.allSatisfy { $0.source == nil } == true,
            "a different set of screens splits the layer evenly again")

    preset.setSpanning(false, layer: "walls", across: screens)
    #expect(preset.layerSpans == nil)
}

@Test func mediaAddedToASlideTakesTheNextOpenLayerAndCanBeMoved() {
    var stack = LayerStack.standard
    stack.addLayer(named: "Walls", id: "walls")
    let clip = MediaItem(
        id: "clip", name: "Clip", mediaKind: .video, classification: .background, fileHash: "", fileName: "",
        fileStatus: .ready, statusDetail: "", tags: [], favorite: false, collections: [], loops: true)
    var slide = Slide(id: "s", name: "", objects: [])
    #expect(slide.openLayer(in: stack) == "walls", "a layer the user added is offered first")

    var cue = CueMedia.onLayer(slide.openLayer(in: stack), for: clip)
    #expect(cue.layerId == "walls" && cue.loops == true)
    slide.layerMedia = [cue]
    #expect(slide.openLayer(in: stack) == "videos")

    cue.setLayer("stillGraphics")
    #expect(cue.layer == .stillGraphics && cue.layerId == nil)
    #expect(stack.resolvedLayerId(for: cue) == "stillGraphics")
}

@Test func aSpanLeavesRoomForTheGapBetweenScreens() {
    var span = LayerSpan(layerId: "walls", targets: ["a", "b", "c"].map {
        LayerTarget(targetKind: .display, targetId: $0)
    })
    #expect(span.gap == 0)

    span.space(gap: 0.5)
    let slices = span.targets.compactMap(\.source)
    #expect(abs(slices[0].width - 0.25) < 0.0001, "three screens and two half-screen gaps make four widths")
    #expect(abs(slices[1].x - 0.375) < 0.0001 && abs(slices[2].x - 0.75) < 0.0001)
    #expect(abs(slices[2].x + slices[2].width - 1) < 0.0001)
    #expect(span.gap == 0.5)

    span.setSlice(ofTarget: "b", start: 0.9, width: 0.3)
    #expect(span.targets[1].source == MediaSourceRect(x: 0.7, y: 0, width: 0.3, height: 1), "a slice stays on the wall")
    #expect(span.gap == nil, "uneven slices have no single gap")

    span.space(gap: 0)
    #expect(span.targets.allSatisfy { $0.source == nil })

    var preset = OutputPreset(id: "p", name: "n", assignments: [], layerSpans: [span])
    preset.updateSpan(ofLayer: "walls") { $0.space(gap: 1) }
    #expect(preset.span(ofLayer: "walls")?.gap == 1)
}

@Test func aSlidesLayerMediaSortsBelowAndAboveTheSlide() {
    var stack = LayerStack.standard
    stack.addLayer(named: "Bug", id: "bug")
    stack.move("bug", up: true)
    let slide = Slide(id: "s", name: "", objects: [], layerMedia: [
        CueMedia(mediaId: "logo", layerId: "bug"),
        CueMedia(mediaId: "clip", layer: .videos),
        CueMedia(mediaId: "sky", layer: .loopingVideos),
    ])
    let ids = stack.layerMediaIDs(of: slide)
    #expect(ids.below == ["sky", "clip"] && ids.above == ["logo"])
}

@Test func everyLayerHasAColorAndASlidesMediaListsTopLayerFirst() {
    var stack = LayerStack.standard
    stack.addLayer(named: "Walls", id: "walls")
    stack.layers[stack.layers.firstIndex { $0.id == "walls" }!].colorHex = "#123456"
    #expect(stack.tintHex(ofLayer: "walls") == "#123456")
    #expect(stack.tintHex(ofLayer: "loopingVideos") == LayerStack.palette[0])
    #expect(stack.tintHex(ofLayer: "stillGraphics") != stack.tintHex(ofLayer: "videos"))

    let slide = Slide(id: "s", name: "", objects: [], layerMedia: [
        CueMedia(mediaId: "sky", layer: .loopingVideos),
        CueMedia(mediaId: "", layerId: "walls"),
        CueMedia(mediaId: "loop", layerId: "walls"),
    ])
    #expect(stack.layerCues(of: slide).map(\.cue.mediaId) == ["loop", "sky"])
    #expect(stack.layerCues(of: slide).map(\.layer.id) == ["walls", "loopingVideos"])
}

@Test func aSlidesLayerMediaReadsInTheOrderOfTheScreensItPlaysOn() {
    var stack = LayerStack.standard
    stack.addLayer(named: "Left Wall", id: "left-wall")
    stack.addLayer(named: "Right Wall", id: "right-wall")
    stack.addLayer(named: "Nowhere", id: "nowhere")
    let slide = Slide(id: "s", name: "", objects: [], layerMedia: [
        CueMedia(mediaId: "lost", layerId: "nowhere"),
        CueMedia(mediaId: "right", layerId: "right-wall"),
        CueMedia(mediaId: "left", layerId: "left-wall"),
        CueMedia(mediaId: "sky", layer: .loopingVideos),
    ])
    #expect(stack.layerCues(of: slide).map(\.cue.mediaId) == ["lost", "right", "left", "sky"])

    let preset = OutputPreset(id: "p", name: "Sunday", assignments: [
        OutputAssignment(targetKind: .display, targetId: "a", enabledLayers: ["left-wall", "loopingVideos"]),
        OutputAssignment(targetKind: .display, targetId: "b", enabledLayers: ["right-wall", "loopingVideos"]),
    ])
    #expect(stack.layerCues(of: slide, routedBy: preset, screens: ["a", "b"]).map(\.cue.mediaId)
        == ["left", "sky", "right", "lost"], "left screen first; layers on the same screen keep their stack order")
    #expect(stack.layerCues(of: slide, routedBy: nil, screens: ["a", "b"]).map(\.cue.mediaId)
        == ["lost", "right", "left", "sky"], "with no preset every layer is everywhere, so the stack decides")
}

@Test func aSlidesLayerMediaCanBeEditedMovedAndRemovedInPlace() {
    var stack = LayerStack.standard
    stack.addLayer(named: "Left", id: "left")
    stack.addLayer(named: "Right", id: "right")
    var slide = Slide(id: "s", name: "", objects: [], layerMedia: [
        CueMedia(mediaId: "a", layerId: "left"),
        CueMedia(mediaId: "b", layerId: "right"),
    ])

    slide.editLayerMedia("a", onLayer: "left", in: stack) { $0.mode = .slideOnly }
    #expect(slide.layerMedia?[0].mode == .slideOnly)
    slide.editLayerMedia("a", onLayer: "right", in: stack) { $0.loops = false }
    #expect(slide.layerMedia?[0].loops == nil && slide.layerMedia?[1].loops == nil, "the wrong layer edits nothing")

    slide.moveLayerMedia("a", fromLayer: "left", toLayer: "right", in: stack)
    #expect(slide.layerMedia?.map(\.mediaId) == ["a"], "moving onto a layer in use replaces what was there")
    #expect(slide.layerMedia?[0].layerId == "right" && slide.layerMedia?[0].mode == .slideOnly)

    slide.moveLayerMedia("a", fromLayer: "right", toLayer: "stillGraphics", in: stack)
    #expect(slide.layerMedia?[0].layer == .stillGraphics && slide.layerMedia?[0].layerId == nil)

    slide.removeLayerMedia("a", onLayer: "stillGraphics", in: stack)
    #expect(slide.layerMedia == nil)
}

@Test func aSlidePreviewSplitsIntoOneColumnPerLayerIncludingTheBackgroundItCarries() {
    var stack = LayerStack.standard
    stack.layers.append(ShowLayer(id: "walls", name: "Side Walls", aboveSlide: true))
    var slide = Slide(id: "s", name: "", objects: [])
    slide.layerMedia = [CueMedia(mediaId: "wall", layerId: "walls"), CueMedia(mediaId: "still", layer: .stillGraphics)]
    let carried = [(layerId: "loopingVideos", mediaId: "loop"), (layerId: "stillGraphics", mediaId: "carried-still")]
    let columns = stack.previewColumns(of: slide, carried: carried, routedBy: nil, screens: [])
    #expect(columns.map { $0.mediaId } == ["wall", "still", "loop"], "top layer first; the slide's own cue wins its layer")
    #expect(columns.map { $0.layer.id } == ["walls", "stillGraphics", "loopingVideos"])
}
