import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let deck = CGSize(width: 1920, height: 1080)

@Test func aScreenOfTheSameShapeKeepsTheDeckCanvas() {
    let canvas = ScreenCanvas(deck: deck, screen: CGSize(width: 3840, height: 2160))
    #expect(canvas.isDeck)
    #expect(canvas.offset == .zero)
}

@Test func aTallWallGrowsTheCanvasAroundTheSharedSlide() {
    let canvas = ScreenCanvas(deck: deck, screen: CGSize(width: 1080, height: 1920))
    #expect(canvas.size.width == 1920)
    #expect(abs(canvas.size.width / canvas.size.height - 1080.0 / 1920.0) < 0.001, "the wall's shape")
    #expect(canvas.offset.x == 0)
    #expect(canvas.offset.y == (canvas.size.height - 1080) / 2, "the shared slide sits centred, at its own size")
}

@Test func aWideWallGrowsSideways() {
    let canvas = ScreenCanvas(deck: deck, screen: CGSize(width: 3840, height: 1080))
    #expect(canvas.size == CGSize(width: 3840, height: 1080))
    #expect(canvas.offset == CGPoint(x: 960, y: 0))
}

@Test func fittingKeepsSlideObjectsInPlaceAndFillsTheWallWithTheBackground() {
    var photo = SlideObject(id: "photo", objectKind: .media, name: "", text: "")
    photo.mediaId = "m"; photo.x = 100; photo.y = 50; photo.width = 400; photo.height = 300
    var slide = Slide(id: "s", name: "", objects: [photo])
    slide.background = CueMedia(mediaId: "bg", layer: .stillGraphics)
    let scene = SlideSceneBuilder.scene(for: slide, theme: nil)

    let canvas = ScreenCanvas(deck: deck, screen: CGSize(width: 3840, height: 1080))
    let fitted = canvas.fitted(scene)
    #expect(fitted.canvasSize == CGSize(width: 3840, height: 1080))
    let object = fitted.layers.first { $0.kind == .slide }?.items.first { $0.id.hasPrefix("photo") }
    #expect(object?.frame == CGRect(x: 1060, y: 50, width: 400, height: 300))
    let background = fitted.layers.first { $0.kind == .stillGraphics }?.items.first
    #expect(background?.frame == CGRect(x: 0, y: 0, width: 3840, height: 1080))

    #expect(ScreenCanvas(deck: deck, screen: deck).fitted(scene) == scene)
}
