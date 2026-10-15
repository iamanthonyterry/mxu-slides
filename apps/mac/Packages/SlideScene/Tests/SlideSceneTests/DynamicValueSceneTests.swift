import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let fixedDate = Date(timeIntervalSince1970: 1_784_800_000)

private func info(values: [String: String]) -> ConfidenceInfo {
    ConfidenceInfo(
        current: .init(body: "Giving today: {Offering}"),
        values: values
    )
}

@Suite struct DynamicValueSceneTests {

    @Test func plainTextObjectsReadValues() {
        let object = SlideObject(
            id: "t", objectKind: .text, name: "Giving", text: "Offering: {offering}"
        )
        let resolved = LinkedText.resolvedObjects(
            [object], info: info(values: ["offering": "$900"]), at: fixedDate
        )
        #expect(resolved[0].text == "Offering: $900")
    }

    @Test func objectsWithoutTokensAreReturnedAsIs() {
        let object = SlideObject(id: "t", objectKind: .text, name: "Lyric", text: "Amazing {grace}")
        let resolved = LinkedText.resolvedObjects(
            [object], info: info(values: ["offering": "$900"]), at: fixedDate
        )
        #expect(resolved == [object])
    }

    @Test func linkedTextReadsValuesAfterTheLinkResolves() {
        var object = SlideObject(id: "c", objectKind: .text, name: "Now", text: "")
        object.textLink = TextLink(source: .currentSlide)
        let resolved = LinkedText.resolvedObjects(
            [object], info: info(values: ["offering": "$900"]), at: fixedDate
        )
        #expect(resolved[0].text == "Giving today: $900")
    }

    @Test func missingValuesLeaveTheTokenVisible() {
        let object = SlideObject(id: "t", objectKind: .text, name: "Giving", text: "Offering: {offering}")
        let resolved = LinkedText.resolvedObjects(
            [object], info: info(values: ["speaker": "Sam"]), at: fixedDate
        )
        #expect(resolved[0].text == "Offering: {offering}")
    }

    @Test func editorPreviewShowsCurrentValues() {
        let object = SlideObject(id: "t", objectKind: .text, name: "Speaker", text: "With {Speaker}")
        let shown = LinkedText.previewObjects([object], values: ["speaker": "Pastor Sam"])
        #expect(shown[0].text == "With Pastor Sam")
    }

    @Test func qrPayloadReadsValuesToo() {
        let object = SlideObject(
            id: "q", objectKind: .qrCode, name: "Give", text: "https://example.org/give?fund={Fund}"
        )
        let resolved = LinkedText.resolvedObjects(
            [object], info: info(values: ["fund": "missions"]), at: fixedDate
        )
        #expect(resolved[0].text == "https://example.org/give?fund=missions")
    }
}

@Suite struct QRObjectSceneTests {

    private func qr(_ text: String = "https://example.org", frame: CGRect? = nil) -> SlideObject {
        let frame = frame ?? CGRect(x: 100, y: 100, width: 400, height: 400)
        return SlideObject(
            id: "qr", objectKind: .qrCode, name: "QR Code", text: text,
            x: frame.minX, y: frame.minY, width: frame.width, height: frame.height
        )
    }

    @Test func drawsABackgroundAndTheModules() throws {
        let items = SlideSceneBuilder.renderItems(for: qr(), theme: nil)
        #expect(items.count == 2)
        #expect(items[0].id == "qr")
        #expect(items[1].id == "qr::qr")

        guard case .shape(let background) = items[0].content,
              case .solid(let backgroundColor) = background.fill
        else {
            Issue.record("background is not a solid shape")
            return
        }
        #expect(backgroundColor == .white)

        guard case .shape(let code) = items[1].content,
              case .path(let data) = code.kind,
              case .solid(let ink) = code.fill
        else {
            Issue.record("modules are not a path shape")
            return
        }
        #expect(!data.isEmpty)
        #expect(ink == SceneColor(red: 0, green: 0, blue: 0))
        #expect(items[0].frame.contains(items[1].frame))
    }

    @Test func staysSquareInAWideFrame() {
        let items = SlideSceneBuilder.renderItems(
            for: qr(frame: CGRect(x: 0, y: 0, width: 900, height: 300)), theme: nil
        )
        #expect(items[0].frame.width == items[0].frame.height)
        #expect(items[0].frame.width == 300)
        #expect(items[0].frame.midX == 450)
    }

    @Test func inkIsTheTextColorAndTheCardIsTheFill() {
        var object = qr()
        var style = TextStyle()
        style.colorHex = "#FF0000"
        object.textStyle = style
        object.fill = ObjectFill(fillKind: .solid, colorHex: "#0000FF")
        let items = SlideSceneBuilder.renderItems(for: object, theme: nil)
        guard case .shape(let background) = items[0].content,
              case .solid(let backgroundColor) = background.fill,
              case .shape(let code) = items[1].content,
              case .solid(let ink) = code.fill
        else {
            Issue.record("unexpected content")
            return
        }
        #expect(backgroundColor == SceneColor(red: 0, green: 0, blue: 1))
        #expect(ink == SceneColor(red: 1, green: 0, blue: 0))
    }

    @Test func aClearFillLeavesNoCardBehindTheCode() {
        var object = qr()
        object.fill = ObjectFill(fillKind: .none)
        let items = SlideSceneBuilder.renderItems(for: object, theme: nil)
        guard case .shape(let background) = items[0].content else {
            Issue.record("background is not a shape")
            return
        }
        #expect(background.fill == .none)
    }

    @Test func emptyPayloadDrawsOnlyTheBackground() {
        let items = SlideSceneBuilder.renderItems(for: qr(""), theme: nil)
        #expect(items.count == 1)
    }

    @Test func hiddenObjectsDrawNothing() {
        var object = qr()
        object.hidden = true
        #expect(SlideSceneBuilder.renderItems(for: object, theme: nil).isEmpty)
    }

    @Test func defaultFrameIsSquare() {
        let frame = SlideSceneBuilder.defaultFrame(for: .qrCode)
        #expect(frame.width == frame.height)
    }
}
