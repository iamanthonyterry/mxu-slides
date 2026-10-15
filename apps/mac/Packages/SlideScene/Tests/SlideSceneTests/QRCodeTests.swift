import CoreImage
import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

@Suite struct QRCodeTests {

    @Test func matrixSizeIsAValidQRVersion() throws {
        let matrix = try #require(QRCode.matrix(for: "https://example.com/give"))
        #expect(matrix.size >= 21)
        #expect((matrix.size - 21) % 4 == 0)
        #expect(matrix.modules.count == matrix.size * matrix.size)
    }

    @Test func finderPatternsSitInThreeCorners() throws {
        let matrix = try #require(QRCode.matrix(for: "MxU Slides"))
        let last = matrix.size - 7
        for (originX, originY) in [(0, 0), (last, 0), (0, last)] {
            for y in 0 ..< 7 {
                for x in 0 ..< 7 {
                    let ring = x == 0 || x == 6 || y == 0 || y == 6
                    let core = (2 ... 4).contains(x) && (2 ... 4).contains(y)
                    #expect(
                        matrix.isDark(x: originX + x, y: originY + y) == (ring || core),
                        "finder at (\(originX), \(originY)) module (\(x), \(y))"
                    )
                }
            }
        }
        // The fourth corner has no finder; the light separator beside each one
        // is what tells a scanner where the code starts.
        #expect(!matrix.isDark(x: 7, y: 0))
        #expect(!matrix.isDark(x: 0, y: 7))
    }

    @Test func higherCorrectionNeedsAtLeastAsManyModules() throws {
        let payload = "https://example.com/connect?card=welcome"
        let low = try #require(QRCode.matrix(for: payload, correction: .low))
        let high = try #require(QRCode.matrix(for: payload, correction: .high))
        #expect(high.size >= low.size)
    }

    @Test func emptyAndOversizedPayloadsMakeNoCode() {
        #expect(QRCode.matrix(for: "") == nil)
        #expect(QRCode.matrix(for: String(repeating: "a", count: QRCode.maxPayloadBytes + 1)) == nil)
    }

    @Test func samePayloadGivesSameMatrix() throws {
        let first = try #require(QRCode.matrix(for: "same"))
        let second = try #require(QRCode.matrix(for: "same"))
        #expect(first == second)
    }

    @Test func pathCoversExactlyTheDarkModules() throws {
        let matrix = QRMatrix(size: 3, modules: [
            true, true, false,
            false, false, false,
            true, false, true,
        ])
        let path = QRCode.pathData(for: matrix)
        // Three runs: a pair on the top row, then one module twice on the last.
        #expect(path.components(separatedBy: "M").count - 1 == 3)
        #expect(path.components(separatedBy: "Z").count - 1 == 3)
    }

    @Test func pathStaysInsideTheUnitSquare() throws {
        let matrix = try #require(QRCode.matrix(for: "bounds"))
        let numbers = QRCode.pathData(for: matrix)
            .split(whereSeparator: { "MLZ ".contains($0) })
            .compactMap { Double($0) }
        #expect(!numbers.isEmpty)
        #expect(numbers.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func scannerReadsBackWhatTheMatrixWasBuiltFrom() throws {
        let payload = "https://example.org/give?fund=missions&amount=25"
        let matrix = try #require(QRCode.matrix(for: payload, correction: .quartile))

        // Draw the matrix the way the output does: modules on a quiet zone.
        let scale = 8
        let margin = QRCode.quietZoneModules
        let side = (matrix.size + 2 * margin) * scale
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 0, alpha: 1)
        for y in 0 ..< matrix.size {
            for x in 0 ..< matrix.size where matrix.isDark(x: x, y: y) {
                // CGContext's origin is bottom-left; row 0 is the top row.
                context.fill(CGRect(
                    x: (x + margin) * scale,
                    y: side - (y + margin + 1) * scale,
                    width: scale, height: scale
                ))
            }
        }
        let image = try #require(context.makeImage())
        let detector = try #require(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let found = detector.features(in: CIImage(cgImage: image))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [payload])
    }

    @Test func squareIsCentredAndNeverStretches() {
        let square = QRCode.square(in: CGRect(x: 100, y: 50, width: 600, height: 300))
        #expect(square.width == 300)
        #expect(square.height == 300)
        #expect(square.midX == 400)
        #expect(square.midY == 200)
    }

    @Test func codeFrameLeavesTheQuietZone() {
        let matrix = QRMatrix(size: 21, modules: [Bool](repeating: false, count: 21 * 21))
        let square = CGRect(x: 0, y: 0, width: 290, height: 290)
        let code = QRCode.codeFrame(inSquare: square, matrix: matrix)
        // 21 modules plus a 4 module margin each side is 29 modules across.
        #expect(abs(code.width - 210) < 0.001)
        #expect(abs(code.minX - 40) < 0.001)
    }
}
