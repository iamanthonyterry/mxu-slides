import Foundation
import PresenterCore

public enum ScreenEditing {

    public static func shown(_ slide: Slide, onScreen targetId: String) -> Slide {
        guard let index = slide.screenVariants?.firstIndex(where: { $0.targetId == targetId }) else { return slide }
        var slide = slide
        slide.objects = ScreenVariants.objects(slide.objects, through: slide.screenVariants?[index])
        slide.screenVariants?[index].objectOverrides = nil
        return slide
    }

    public static func folded(
        base: Slide, shownBefore: Slide, shownAfter: Slide, screen targetId: String
    ) -> Slide {
        var overrides = Dictionary(
            (ScreenVariants.variant(of: base, forScreen: targetId)?.objectOverrides ?? []).map { ($0.objectId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let baseObjects = Dictionary(base.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let before = Dictionary(shownBefore.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var objects: [SlideObject] = []
        for shown in shownAfter.objects {
            guard let shared = baseObjects[shown.id], let was = before[shown.id] else {

                var only = shown
                only.hidden = true
                objects.append(only)
                overrides[shown.id] = ScreenObjectOverride(objectId: shown.id, hidden: false)
                continue
            }
            var override = overrides[shown.id] ?? ScreenObjectOverride(objectId: shown.id)
            if shown.x != was.x { override.x = shown.x }
            if shown.y != was.y { override.y = shown.y }
            if shown.width != was.width { override.width = shown.width }
            if shown.height != was.height { override.height = shown.height }
            if shown.rotationDegrees != was.rotationDegrees { override.rotationDegrees = shown.rotationDegrees }
            if shown.hidden != was.hidden { override.hidden = shown.hidden ?? false }
            overrides[shown.id] = override

            var kept = shown
            kept.x = shared.x
            kept.y = shared.y
            kept.width = shared.width
            kept.height = shared.height
            kept.rotationDegrees = shared.rotationDegrees
            kept.hidden = shared.hidden
            objects.append(kept)
        }

        let remaining = Set(shownAfter.objects.map(\.id))
        for (index, shared) in base.objects.enumerated() where !remaining.contains(shared.id) {
            if isOnly(shared, onScreen: targetId, of: base) {
                overrides[shared.id] = nil
                continue
            }

            var override = overrides[shared.id] ?? ScreenObjectOverride(objectId: shared.id)
            override.hidden = true
            overrides[shared.id] = override
            let anchor = base.objects[..<index].last { earlier in objects.contains { $0.id == earlier.id } }
            let at = anchor.flatMap { anchor in objects.firstIndex { $0.id == anchor.id } }.map { $0 + 1 } ?? 0
            objects.insert(shared, at: at)
        }

        var slide = shownAfter
        slide.objects = objects
        let kept = objects.compactMap { overrides[$0.id] }.filter { !isEmpty($0) }
        write(kept, forScreen: targetId, to: &slide)
        return pruned(slide)
    }

    public static func isOnly(_ object: SlideObject, onScreen targetId: String, of slide: Slide) -> Bool {
        object.hidden == true && override(for: object.id, onScreen: targetId, of: slide)?.hidden == false
    }

    public static func override(for objectID: String, onScreen targetId: String, of slide: Slide) -> ScreenObjectOverride? {
        ScreenVariants.variant(of: slide, forScreen: targetId)?
            .objectOverrides?.first { $0.objectId == objectID }
    }

    public static func hasOverride(_ objectID: String, onScreen targetId: String, of slide: Slide) -> Bool {
        override(for: objectID, onScreen: targetId, of: slide) != nil
    }

    public static func resetToShared(_ ids: Set<String>, onScreen targetId: String, in slide: inout Slide) {
        guard let index = slide.screenVariants?.firstIndex(where: { $0.targetId == targetId }) else { return }
        slide.screenVariants?[index].objectOverrides?.removeAll { ids.contains($0.objectId) }
        slide = pruned(slide)
    }

    public static func showOnAllScreens(_ ids: Set<String>, in slide: inout Slide) {
        for index in slide.objects.indices where ids.contains(slide.objects[index].id) {
            slide.objects[index].hidden = nil
        }
        for variant in (slide.screenVariants ?? []).indices {
            for index in (slide.screenVariants?[variant].objectOverrides ?? []).indices
            where ids.contains(slide.screenVariants![variant].objectOverrides![index].objectId) {
                slide.screenVariants![variant].objectOverrides![index].hidden = nil
            }
        }
        slide = pruned(slide)
    }

    public static func showOnly(_ ids: Set<String>, onScreen targetId: String, in slide: inout Slide) {
        var overrides = ScreenVariants.variant(of: slide, forScreen: targetId)?.objectOverrides ?? []
        for index in slide.objects.indices where ids.contains(slide.objects[index].id) {
            let id = slide.objects[index].id
            slide.objects[index].hidden = true
            if let at = overrides.firstIndex(where: { $0.objectId == id }) {
                overrides[at].hidden = false
            } else {
                overrides.append(ScreenObjectOverride(objectId: id, hidden: false))
            }
        }
        write(overrides, forScreen: targetId, to: &slide)
        slide = pruned(slide)
    }

    public static func updateVariant(
        forScreen targetId: String, in slide: inout Slide, _ mutate: (inout ScreenVariant) -> Void
    ) {
        var variants = slide.screenVariants ?? []
        if let index = variants.firstIndex(where: { $0.targetId == targetId }) {
            mutate(&variants[index])
        } else {
            var variant = ScreenVariant(targetId: targetId)
            mutate(&variant)
            variants.append(variant)
        }
        slide.screenVariants = variants
        slide = pruned(slide)
    }

    public static func pruned(_ slide: Slide) -> Slide {
        guard var variants = slide.screenVariants else { return slide }
        let ids = Set(slide.objects.map(\.id))
        for index in variants.indices {
            let kept = variants[index].objectOverrides?.filter { ids.contains($0.objectId) && !isEmpty($0) }
            variants[index].objectOverrides = (kept?.isEmpty ?? true) ? nil : kept
            if variants[index].background?.mediaId.isEmpty == true { variants[index].background = nil }
            if variants[index].hidesBackground != true { variants[index].hidesBackground = nil }
        }
        variants.removeAll {
            $0.objectOverrides == nil && $0.background == nil && $0.hidesBackground == nil
        }
        var slide = slide
        slide.screenVariants = variants.isEmpty ? nil : variants
        return slide
    }

    public static func samePlacement(_ a: SlideObject, _ b: SlideObject) -> Bool {
        a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
            && a.rotationDegrees == b.rotationDegrees && a.hidden == b.hidden
    }

    public static func keepingPlacement(of shared: SlideObject, in shown: SlideObject) -> SlideObject {
        var kept = shown
        kept.x = shared.x
        kept.y = shared.y
        kept.width = shared.width
        kept.height = shared.height
        kept.rotationDegrees = shared.rotationDegrees
        kept.hidden = shared.hidden
        return kept
    }

    static func isEmpty(_ override: ScreenObjectOverride) -> Bool {
        override.x == nil && override.y == nil && override.width == nil && override.height == nil
            && override.rotationDegrees == nil && override.hidden == nil
    }

    private static func write(_ overrides: [ScreenObjectOverride], forScreen targetId: String, to slide: inout Slide) {
        var variants = slide.screenVariants ?? []
        if let index = variants.firstIndex(where: { $0.targetId == targetId }) {
            variants[index].objectOverrides = overrides
        } else if !overrides.isEmpty {
            variants.append(ScreenVariant(targetId: targetId, objectOverrides: overrides))
        }
        slide.screenVariants = variants
    }
}
