import CoreGraphics
import Foundation
import RenderEngine

public struct ScreenCanvas: Sendable, Equatable {

    public var size: CGSize

    public var offset: CGPoint

    public var deck: CGSize

    public init(deck: CGSize, screen: CGSize) {
        self.deck = deck
        guard deck.width > 0, deck.height > 0, screen.width > 0, screen.height > 0 else {
            size = deck
            offset = .zero
            return
        }
        let deckAspect = deck.width / deck.height
        let screenAspect = screen.width / screen.height
        if abs(deckAspect - screenAspect) < 0.001 {
            size = deck
        } else if screenAspect > deckAspect {
            size = CGSize(width: (deck.height * screenAspect).rounded(), height: deck.height)
        } else {
            size = CGSize(width: deck.width, height: (deck.width / screenAspect).rounded())
        }
        offset = CGPoint(x: (size.width - deck.width) / 2, y: (size.height - deck.height) / 2)
    }

    public var isDeck: Bool { size == deck }

    public func fitted(_ scene: RenderScene) -> RenderScene {
        guard !isDeck, scene.canvasSize == deck else { return scene }
        var scene = scene
        scene.canvasSize = size
        let whole = CGRect(origin: .zero, size: deck)
        for layer in scene.layers.indices {
            let fillsScreen = scene.layers[layer].kind != .slide
                && scene.layers[layer].kind != .overlays && scene.layers[layer].kind != .alerts
            for item in scene.layers[layer].items.indices {
                let fills = scene.layers[layer].items[item].frame == whole
                    && (fillsScreen || scene.layers[layer].items[item].id.hasSuffix("-backdrop"))
                scene.layers[layer].items[item] = moved(scene.layers[layer].items[item], filling: fills)
            }
        }
        return scene
    }

    private func moved(_ item: RenderItem, filling: Bool) -> RenderItem {
        var item = item
        item.frame = filling
            ? CGRect(origin: .zero, size: size)
            : item.frame.offsetBy(dx: offset.x, dy: offset.y)
        for index in item.animationSteps.indices {
            if let to = item.animationSteps[index].toItem {
                item.animationSteps[index].toItem = moved(to, filling: filling)
            }
            if let from = item.animationSteps[index].fromItem {
                item.animationSteps[index].fromItem = moved(from, filling: filling)
            }
        }
        return item
    }
}

extension RenderScene {

    public func fitted(toScreen screen: CGSize?) -> RenderScene {
        guard let screen else { return self }
        return ScreenCanvas(deck: canvasSize, screen: screen).fitted(self)
    }
}
