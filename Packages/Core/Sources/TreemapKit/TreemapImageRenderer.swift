import CoreGraphics
import Foundation
import ImageIO
import ScanKit
import UniformTypeIdentifiers

/// CPU cushion renderer. Used by the Phase 0 spike and as a reference for the Metal shader.
public enum TreemapImageRenderer {
    // Light direction and ambient/diffuse split from the original cushion treemap paper.
    static let light = (x: 0.09759, y: 0.19518, z: 0.9759)
    static let ambient = 0.2
    static let diffuse = 0.8

    public static func render(layout: [TreemapItem], tree: FileTree, size: TreemapRect) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        var pixels = [UInt32](repeating: 0xFF000000, count: width * height)

        for item in layout {
            let color = TreemapPalette.color(for: item.node, in: tree)
            let (r, g, b) = (color.r, color.g, color.b)
            let c = item.cushion
            let x0 = max(0, Int(item.rect.x.rounded())), x1 = min(width, Int((item.rect.x + item.rect.width).rounded()))
            let y0 = max(0, Int(item.rect.y.rounded())), y1 = min(height, Int((item.rect.y + item.rect.height).rounded()))
            guard x0 < x1, y0 < y1 else { continue }

            for y in y0 ..< y1 {
                let py = Double(y) + 0.5
                let ny = -(2 * c.s2y * py + c.s1y)
                for x in x0 ..< x1 {
                    let px = Double(x) + 0.5
                    let nx = -(2 * c.s2x * px + c.s1x)
                    let cosine = (nx * light.x + ny * light.y + light.z) / (nx * nx + ny * ny + 1).squareRoot()
                    let intensity = ambient + diffuse * max(0, cosine)
                    let R = UInt32(min(255, r * intensity * 255))
                    let G = UInt32(min(255, g * intensity * 255))
                    let B = UInt32(min(255, b * intensity * 255))
                    pixels[y * width + x] = 0xFF000000 | (R << 16) | (G << 8) | B
                }
            }
        }

        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    public static func writePNG(layout: [TreemapItem], tree: FileTree, size: TreemapRect, to path: String) throws {
        guard let image = render(layout: layout, tree: tree, size: size),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
