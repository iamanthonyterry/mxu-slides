import Foundation
import PresenterCore
import Testing
@testable import SlideScene

private let side = "side-wall"
private let center = "center-wall"

private func object(_ id: String, x: Double = 0, text: String = "") -> SlideObject {
    var object = SlideObject(id: id, objectKind: text.isEmpty ? .media : .text, name: id, text: text)
    object.x = x; object.y = 0; object.width = 400; object.height = 300
    return object
}

private func edit(_ slide: Slide, on screen: String = side, _ mutate: (inout Slide) -> Void) -> Slide {
    let before = ScreenEditing.shown(slide, onScreen: screen)
    var after = before
    mutate(&after)
    return ScreenEditing.folded(base: slide, shownBefore: before, shownAfter: after, screen: screen)
}

@Test func movingAnObjectOnAScreenLeavesTheSharedSlideAlone() {
    let slide = Slide(id: "s", name: "", objects: [object("photo"), object("lyrics", x: 50, text: "Grace")])
    let edited = edit(slide) { $0.objects[0].x = 900 }

    #expect(edited.objects == slide.objects, "every other screen still sees the slide as it was")
    #expect(ScreenEditing.shown(edited, onScreen: side).objects[0].x == 900)
    #expect(ScreenEditing.shown(edited, onScreen: center).objects[0].x == 0)
    #expect(ScreenEditing.hasOverride("photo", onScreen: side, of: edited))
    #expect(!ScreenEditing.hasOverride("lyrics", onScreen: side, of: edited), "untouched objects carry no override")
}

@Test func wordsAndStyleEditedOnAScreenAreSharedWithEveryScreen() {
    let slide = Slide(id: "s", name: "", objects: [object("lyrics", text: "Grace")])
    let edited = edit(slide) {
        $0.objects[0].text = "Amazing grace"
        $0.objects[0].opacity = 0.5
        $0.objects[0].y = 700
    }
    #expect(edited.objects[0].text == "Amazing grace")
    #expect(edited.objects[0].opacity == 0.5)
    #expect(edited.objects[0].y == 0, "only the placement is this screen's own")
    #expect(ScreenEditing.shown(edited, onScreen: side).objects[0].y == 700)
}

@Test func laterEditsOnTheSameScreenKeepEarlierOnes() {
    let slide = Slide(id: "s", name: "", objects: [object("photo")])
    let moved = edit(slide) { $0.objects[0].x = 900 }
    let resized = edit(moved) { $0.objects[0].width = 120 }
    let shown = ScreenEditing.shown(resized, onScreen: side).objects[0]
    #expect(shown.x == 900)
    #expect(shown.width == 120)
}

@Test func anObjectAddedOnAScreenShowsOnlyThere() {
    let slide = Slide(id: "s", name: "", objects: [object("photo")])
    let edited = edit(slide) { $0.objects.append(object("side-logo", x: 10)) }

    #expect(edited.objects.map(\.id) == ["photo", "side-logo"])
    #expect(edited.objects[1].hidden == true, "hidden everywhere else")
    #expect(ScreenEditing.shown(edited, onScreen: side).objects[1].hidden == false)
    #expect(ScreenEditing.shown(edited, onScreen: center).objects[1].hidden == true)
    #expect(ScreenEditing.isOnly(edited.objects[1], onScreen: side, of: edited))

    var everywhere = edited
    ScreenEditing.showOnAllScreens(["side-logo"], in: &everywhere)
    #expect(everywhere.objects[1].hidden == nil)
    #expect(everywhere.screenVariants == nil, "nothing left that is this screen's own")
}

@Test func deletingOnAScreenHidesASharedObjectThereAndRemovesItsOwn() {
    let slide = Slide(id: "s", name: "", objects: [object("a"), object("photo"), object("b")])
    let hidden = edit(slide) { $0.objects.remove(at: 1) }
    #expect(hidden.objects.map(\.id) == ["a", "photo", "b"], "still on the slide, in its place, for other screens")
    #expect(ScreenEditing.shown(hidden, onScreen: side).objects[1].hidden == true)
    #expect(hidden.objects[1].hidden == nil)

    let withOwn = edit(slide) { $0.objects.append(object("side-logo")) }
    let removed = edit(withOwn) { $0.objects.removeAll { $0.id == "side-logo" } }
    #expect(removed.objects.map(\.id) == ["a", "photo", "b"])
    #expect(removed.screenVariants == nil)
}

@Test func resettingAnObjectReturnsItToTheSharedPlacement() {
    let slide = Slide(id: "s", name: "", objects: [object("photo"), object("logo")])
    var edited = edit(slide) { $0.objects[0].x = 900; $0.objects[1].x = 40 }
    ScreenEditing.resetToShared(["photo"], onScreen: side, in: &edited)
    let shown = ScreenEditing.shown(edited, onScreen: side).objects
    #expect(shown[0].x == 0)
    #expect(shown[1].x == 40)
}

@Test func reorderingOnAScreenReordersTheSharedStack() {
    let slide = Slide(id: "s", name: "", objects: [object("a"), object("b"), object("c")])
    let edited = edit(slide) { $0.objects.swapAt(0, 2) }
    #expect(edited.objects.map(\.id) == ["c", "b", "a"])
    #expect(edited.screenVariants == nil)
}

@Test func aScreensBackgroundSurvivesObjectEdits() {
    var slide = Slide(id: "s", name: "", objects: [object("photo")])
    ScreenEditing.updateVariant(forScreen: side, in: &slide) { $0.background = CueMedia(mediaId: "side-bg") }
    let edited = edit(slide) { $0.objects[0].x = 5 }
    #expect(ScreenVariants.variant(of: edited, forScreen: side)?.background?.mediaId == "side-bg")

    var cleared = edited
    ScreenEditing.updateVariant(forScreen: side, in: &cleared) { $0.background = nil }
    ScreenEditing.resetToShared(["photo"], onScreen: side, in: &cleared)
    #expect(cleared.screenVariants == nil)
}

@Test func aDuplicatedSlideKeepsItsScreensPlacements() {
    let slide = edit(Slide(id: "s", name: "", objects: [object("photo")])) { $0.objects[0].x = 900 }
    let copy = slide.freshIDCopy()
    #expect(copy.objects[0].id != "photo")
    #expect(ScreenEditing.shown(copy, onScreen: side).objects[0].x == 900)
}
