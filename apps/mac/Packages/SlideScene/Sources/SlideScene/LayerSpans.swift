import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

public enum LayerSpans {

    public static func frame(
        ofMedia media: CGSize?, scaleMode: SceneMediaScaleMode,
        slice: MediaSourceRect, screen: CGSize
    ) -> CGRect {
        guard slice.width > 0, slice.height > 0, screen.width > 0, screen.height > 0 else {
            return CGRect(origin: .zero, size: screen)
        }
        let wall = (screen.width / screen.height) * slice.height / slice.width
        var placed = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let media, media.width > 0, media.height > 0, scaleMode != .stretch {
            let shape = media.width / media.height
            let widerThanWall = shape > wall
            if (scaleMode == .fill) == widerThanWall {
                placed.size.width = shape / wall
            } else {
                placed.size.height = wall / shape
            }
            placed.origin = CGPoint(x: (1 - placed.width) / 2, y: (1 - placed.height) / 2)
        }
        return CGRect(
            x: (placed.minX - slice.x) / slice.width * screen.width,
            y: (placed.minY - slice.y) / slice.height * screen.height,
            width: placed.width / slice.width * screen.width,
            height: placed.height / slice.height * screen.height
        )
    }

    public static func active(in preset: OutputPreset?) -> [String: LayerSpan] {
        var spans: [String: LayerSpan] = [:]
        for span in preset?.layerSpans ?? [] where span.targets.count > 1 {
            spans[span.layerId] = span
        }
        return spans
    }

    public static func targets(of spans: [String: LayerSpan]) -> Set<String> {
        Set(spans.values.flatMap { $0.targets.map(\.targetId) })
    }
}

extension RenderScene {

    public func spanning(
        _ spans: [String: LayerSpan], onScreen targetId: String, mediaSize: (String) -> CGSize?
    ) -> RenderScene {
        guard !spans.isEmpty else { return self }
        var scene = self
        for index in scene.layers.indices {
            guard let slice = spans[scene.layers[index].id]?.source(forTarget: targetId) else { continue }
            for item in scene.layers[index].items.indices {
                guard case .media(let id, let scaleMode, let sourceRect) = scene.layers[index].items[item].content
                else { continue }
                scene.layers[index].items[item].frame = LayerSpans.frame(
                    ofMedia: mediaSize(id), scaleMode: scaleMode, slice: slice, screen: canvasSize)
                scene.layers[index].items[item].content = .media(id: id, scaleMode: .stretch, sourceRect: sourceRect)
            }
        }
        return scene
    }
}
