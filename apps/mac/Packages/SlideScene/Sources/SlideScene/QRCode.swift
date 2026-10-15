import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PresenterCore
import RenderEngine

/// The dark and light modules of a QR code, without a quiet zone.
public struct QRMatrix: Equatable, Sendable {
    public let size: Int

    /// Row-major, top row first. True is a dark module.
    public let modules: [Bool]

    public init(size: Int, modules: [Bool]) {
        precondition(modules.count == size * size)
        self.size = size
        self.modules = modules
    }

    public func isDark(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        return modules[y * size + x]
    }
}

public enum QRCode {

    /// How much of a code can be damaged or hidden and still scan.
    public enum Correction: Sendable, Hashable {
        case low, medium, quartile, high
    }

    /// Light modules around the code that scanners need to find its edge.
    public static let quietZoneModules = 4

    /// Payloads past this many bytes do not fit the largest QR version.
    public static let maxPayloadBytes = 2_900

    public static func matrix(
        for payload: String, correction: Correction = .medium
    ) -> QRMatrix? {
        guard !payload.isEmpty else { return nil }
        let key = Key(payload: payload, correction: correction)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        guard let built = build(payload: payload, correction: correction) else { return nil }
        cache.withLock { cache in
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = built
        }
        return built
    }

    /// One closed subpath per horizontal run of dark modules, in the
    /// 0...1 unit square the shape renderer scales to the item's frame. Each
    /// run reaches a hair past its edges so neighbours do not show a seam
    /// where anti-aliasing meets.
    public static func pathData(for matrix: QRMatrix) -> String {
        let n = Double(matrix.size)
        guard matrix.size > 0 else { return "" }
        let overlap = 0.02
        var path = ""
        for y in 0 ..< matrix.size {
            var x = 0
            while x < matrix.size {
                guard matrix.isDark(x: x, y: y) else { x += 1; continue }
                let start = x
                while x < matrix.size, matrix.isDark(x: x, y: y) { x += 1 }
                let left = Double(start) / n
                let right = min(1, (Double(x) + (x < matrix.size ? overlap : 0)) / n)
                let top = Double(y) / n
                let bottom = min(1, (Double(y + 1) + (y + 1 < matrix.size ? overlap : 0)) / n)
                path += "M\(fmt(left)) \(fmt(top))L\(fmt(right)) \(fmt(top))"
                path += "L\(fmt(right)) \(fmt(bottom))L\(fmt(left)) \(fmt(bottom))Z"
            }
        }
        return path
    }

    /// The square a QR object draws in: the largest centred square in its
    /// frame, so the code never stretches.
    public static func square(in frame: CGRect) -> CGRect {
        let side = min(frame.width, frame.height)
        return CGRect(
            x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side
        )
    }

    /// The code's own area inside ``square(in:)``, leaving the quiet zone.
    public static func codeFrame(inSquare square: CGRect, matrix: QRMatrix) -> CGRect {
        let modules = Double(matrix.size + 2 * quietZoneModules)
        let inset = square.width * Double(quietZoneModules) / modules
        return square.insetBy(dx: inset, dy: inset)
    }

    // MARK: -

    private struct Key: Hashable {
        var payload: String
        var correction: Correction
    }

    private static let cacheLimit = 48
    private static let cache = Locked<[Key: QRMatrix]>([:])

    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    private static func build(payload: String, correction: Correction) -> QRMatrix? {
        guard let data = payload.data(using: .utf8), data.count <= maxPayloadBytes else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = switch correction {
        case .low: "L"
        case .medium: "M"
        case .quartile: "Q"
        case .high: "H"
        }
        guard let image = filter.outputImage else { return nil }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, width == height else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &pixels, rowBytes: width * 4, bounds: extent,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        // The bitmap is top row first. CoreImage pads the code with a one
        // module margin, so crop to the dark modules: the finder patterns sit
        // in three corners, which makes their bounds exactly the code.
        func dark(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4] < 128 }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where dark(x, y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let size = maxX - minX + 1
        guard maxX >= 0, size == maxY - minY + 1 else { return nil }
        var modules = [Bool](repeating: false, count: size * size)
        for y in 0 ..< size {
            for x in 0 ..< size {
                modules[y * size + x] = dark(minX + x, minY + y)
            }
        }
        return QRMatrix(size: size, modules: modules)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.5f", value)
    }
}
