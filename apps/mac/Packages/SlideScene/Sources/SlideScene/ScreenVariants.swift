import Foundation
import PresenterCore
import RenderEngine

public enum ScreenVariants {

    public static func variant(of slide: Slide, forScreen targetId: String?) -> ScreenVariant? {
        guard let targetId, !targetId.isEmpty else { return nil }
        return slide.screenVariants?.first { $0.targetId == targetId }
    }

    public static func objects(_ objects: [SlideObject], through variant: ScreenVariant?) -> [SlideObject] {
        guard let overrides = variant?.objectOverrides, !overrides.isEmpty else { return objects }
        return objects.map { object in
            guard let override = overrides.first(where: { $0.objectId == object.id }) else { return object }
            var object = object
            if let x = override.x { object.x = x }
            if let y = override.y { object.y = y }
            if let width = override.width { object.width = width }
            if let height = override.height { object.height = height }
            if let rotation = override.rotationDegrees { object.rotationDegrees = rotation }
            if let hidden = override.hidden { object.hidden = hidden }
            return object
        }
    }

    public enum Background: Sendable, Equatable {
        case shared
        case hidden
        case own(CueMedia)
    }

    public static func background(of variant: ScreenVariant?) -> Background {
        guard let variant else { return .shared }
        if let own = variant.background, !own.mediaId.isEmpty { return .own(own) }
        return variant.hidesBackground == true ? .hidden : .shared
    }

    public static func background(
        for slide: Slide,
        presentation: Presentation?,
        arrangementId: String? = nil,
        screen targetId: String?
    ) -> (shared: CueMedia?, choice: Background) {
        let source = SlideSceneBuilder.backgroundSource(
            slide: slide, presentation: presentation, arrangementId: arrangementId
        )
        var choice = background(of: variant(of: slide, forScreen: targetId))

        if choice == .shared, case .slide(let id) = source?.source, id != slide.id,
           let declarer = presentation?.slides.first(where: { $0.id == id }) {
            choice = background(of: variant(of: declarer, forScreen: targetId))
        }
        return (source?.media, choice)
    }

    public static func effectiveBackground(
        for slide: Slide,
        presentation: Presentation?,
        arrangementId: String? = nil,
        screen targetId: String?
    ) -> CueMedia? {
        let resolved = background(
            for: slide, presentation: presentation, arrangementId: arrangementId, screen: targetId
        )
        switch resolved.choice {
        case .shared: return resolved.shared
        case .hidden: return nil
        case .own(let media): return media
        }
    }
}

extension Slide {

    public func rendered(onScreen targetId: String?) -> Slide {
        guard let variant = ScreenVariants.variant(of: self, forScreen: targetId) else { return self }
        var slide = self
        slide.objects = ScreenVariants.objects(objects, through: variant)
        return slide
    }
}
