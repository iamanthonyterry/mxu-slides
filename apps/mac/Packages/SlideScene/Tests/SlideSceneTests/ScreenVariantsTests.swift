import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let center = "center-wall"
private let side = "side-wall"

private func photo(x: Double = 0, width: Double = 1920) -> SlideObject {
    var object = SlideObject(id: "photo", objectKind: .media, name: "Photo", text: "")
    object.mediaId = "shared-photo"
    object.x = x; object.y = 0; object.width = width; object.height = 1080
    return object
}

private func lyrics() -> SlideObject {
    var object = SlideObject(id: "lyrics", objectKind: .text, name: "Lyrics", text: "Amazing grace")
    object.x = 100; object.y = 100; object.width = 1720; object.height = 880
    return object
}

private func items(_ scene: RenderScene, on layer: LayerKind) -> [RenderItem] {
    scene.layers.first { $0.kind == layer }?.items ?? []
}

private func mediaIDs(_ scene: RenderScene, on layer: LayerKind) -> [String] {
    items(scene, on: layer).compactMap {
        if case .media(let id, _, _) = $0.content { id } else { nil }
    }
}

@Test func aSlideWithoutVariantsRendersTheSameOnEveryScreen() {
    var slide = Slide(id: "s1", name: "", objects: [photo(), lyrics()])
    slide.background = CueMedia(mediaId: "shared-bg", layer: .stillGraphics)
    let shared = SlideSceneBuilder.scene(for: slide, theme: nil)
    #expect(SlideSceneBuilder.scene(for: slide, theme: nil, screen: side) == shared)
}

@Test func aScreenVariantMovesAndHidesObjectsOnItsScreenOnly() {
    var slide = Slide(id: "s1", name: "", objects: [photo(), lyrics()])
    slide.screenVariants = [ScreenVariant(targetId: side, objectOverrides: [
        ScreenObjectOverride(objectId: "photo", x: 200, width: 600),
        ScreenObjectOverride(objectId: "lyrics", hidden: true),
    ])]
    func frame(_ scene: RenderScene, _ prefix: String) -> CGRect? {
        items(scene, on: .slide).first { $0.id.hasPrefix(prefix) }?.frame
    }
    let onSide = SlideSceneBuilder.scene(for: slide, theme: nil, screen: side)
    #expect(frame(onSide, "photo")?.minX == 200)
    #expect(frame(onSide, "photo")?.width == 600)
    #expect(frame(onSide, "photo")?.height == 1080, "fields the variant leaves alone stay shared")
    #expect(frame(onSide, "lyrics") == nil)

    let onCenter = SlideSceneBuilder.scene(for: slide, theme: nil, screen: center)
    #expect(frame(onCenter, "photo")?.minX == 0)
    #expect(frame(onCenter, "lyrics") != nil)
    #expect(onCenter == SlideSceneBuilder.scene(for: slide, theme: nil))
}

@Test func theWordsStaySharedAcrossScreens() {
    var slide = Slide(id: "s1", name: "", objects: [lyrics()])
    slide.screenVariants = [ScreenVariant(targetId: side, objectOverrides: [
        ScreenObjectOverride(objectId: "lyrics", y: 600, height: 300)
    ])]
    #expect(slide.rendered(onScreen: side).objects.map(\.text) == slide.objects.map(\.text))
}

@Test func aScreenCanCarryItsOwnBackgroundOrNone() {
    var slide = Slide(id: "s1", name: "", objects: [lyrics()])
    slide.background = CueMedia(mediaId: "shared-bg", layer: .stillGraphics)
    slide.screenVariants = [
        ScreenVariant(targetId: side, background: CueMedia(mediaId: "side-bg", layer: .stillGraphics)),
        ScreenVariant(targetId: "lobby", hidesBackground: true),
    ]
    #expect(mediaIDs(SlideSceneBuilder.scene(for: slide, theme: nil), on: .stillGraphics) == ["shared-bg"])
    #expect(mediaIDs(SlideSceneBuilder.scene(for: slide, theme: nil, screen: center), on: .stillGraphics) == ["shared-bg"])
    #expect(mediaIDs(SlideSceneBuilder.scene(for: slide, theme: nil, screen: side), on: .stillGraphics) == ["side-bg"])
    #expect(mediaIDs(SlideSceneBuilder.scene(for: slide, theme: nil, screen: "lobby"), on: .stillGraphics).isEmpty)
}

@Test func aFollowingSlideInheritsTheScreensBackgroundWithTheSharedOne() {
    var first = Slide(id: "s1", name: "", objects: [])
    first.background = CueMedia(mediaId: "shared-bg", mode: .untilReplaced, layer: .loopingVideos)
    first.screenVariants = [ScreenVariant(targetId: side, background: CueMedia(mediaId: "side-bg"))]
    let second = Slide(id: "s2", name: "", objects: [lyrics()])
    let deck = Presentation(id: "p", name: "Deck", presentationKind: .song, themeId: "", slides: [first, second])

    #expect(ScreenVariants.effectiveBackground(for: second, presentation: deck, screen: side)?.mediaId == "side-bg")
    #expect(ScreenVariants.effectiveBackground(for: second, presentation: deck, screen: center)?.mediaId == "shared-bg")
}

@Test func liveScreensShowTheirOwnBackgroundUntilTheLayerIsReplacedOrCleared() {
    var slide = Slide(id: "s1", name: "", objects: [photo(), lyrics()])
    slide.background = CueMedia(mediaId: "shared-bg", layer: .stillGraphics)
    slide.screenVariants = [ScreenVariant(
        targetId: side,
        background: CueMedia(mediaId: "side-bg", layer: .stillGraphics),
        objectOverrides: [ScreenObjectOverride(objectId: "photo", hidden: true)]
    )]
    var show = ShowState()
    show.fire(slide: slide, atHostTime: 1)

    #expect(mediaIDs(show.scene(), on: .stillGraphics) == ["shared-bg"])
    #expect(mediaIDs(show.scene(screen: center), on: .stillGraphics) == ["shared-bg"])
    #expect(mediaIDs(show.scene(screen: side), on: .stillGraphics) == ["side-bg"])
    #expect(items(show.scene(screen: side), on: .slide).contains { $0.id.hasPrefix("photo") } == false)
    #expect(items(show.scene(screen: center), on: .slide).contains { $0.id.hasPrefix("photo") })
    #expect(show.wantedMedia().keys.contains("side-bg"), "the screen's own media loads with the shared one")

    show.fire(media: CueMedia(mediaId: "operator-pick"), on: .stillGraphics)
    #expect(mediaIDs(show.scene(screen: side), on: .stillGraphics) == ["operator-pick"])

    show.fire(slide: slide, atHostTime: 2)
    #expect(mediaIDs(show.scene(screen: side), on: .stillGraphics) == ["side-bg"])
    show.clear(layer: .stillGraphics)
    #expect(mediaIDs(show.scene(screen: side), on: .stillGraphics).isEmpty)
    #expect(show.liveScreenMedia.isEmpty)
}

@Test func aSlideDeclaringASharedBackgroundTakesTheScreenBackToIt() {
    var first = Slide(id: "s1", name: "", objects: [])
    first.background = CueMedia(mediaId: "shared-bg", layer: .stillGraphics)
    first.screenVariants = [ScreenVariant(targetId: side, hidesBackground: true)]
    var second = Slide(id: "s2", name: "", objects: [])
    second.background = CueMedia(mediaId: "shared-bg", layer: .stillGraphics)

    var show = ShowState()
    show.fire(slide: first, atHostTime: 1)
    #expect(mediaIDs(show.scene(screen: side), on: .stillGraphics).isEmpty)
    show.fire(slide: second, atHostTime: 2)
    #expect(mediaIDs(show.scene(screen: side), on: .stillGraphics) == ["shared-bg"])
}

@Test func olderSlidesDecodeWithoutVariantsAndVariantsRoundTrip() throws {
    let legacy = Data(#"{"id":"s1","name":"","objects":[]}"#.utf8)
    #expect(try JSONDecoder().decode(Slide.self, from: legacy).screenVariants == nil)

    var slide = Slide(id: "s1", name: "", objects: [photo()])
    slide.screenVariants = [ScreenVariant(
        targetId: side, background: CueMedia(mediaId: "side-bg"),
        objectOverrides: [ScreenObjectOverride(objectId: "photo", x: 12)]
    )]
    let decoded = try JSONDecoder().decode(Slide.self, from: JSONEncoder().encode(slide))
    #expect(decoded == slide)
}
