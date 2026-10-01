import ScanKit

public struct RGB: Sendable, Equatable {
    public var r, g, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { (self.r, self.g, self.b) = (r, g, b) }
}

/// Treemap colors. The largest kinds get distinct colors, as in Disk Inventory X; smaller
/// kinds share `otherKinds`.
public enum TreemapPalette {
    public static let kinds: [RGB] = [
        RGB(0.25, 0.55, 0.95), RGB(0.95, 0.35, 0.30), RGB(0.35, 0.78, 0.40), RGB(0.95, 0.75, 0.25),
        RGB(0.70, 0.45, 0.90), RGB(0.20, 0.78, 0.80), RGB(0.95, 0.50, 0.75), RGB(0.60, 0.75, 0.30),
        RGB(0.95, 0.60, 0.20), RGB(0.45, 0.50, 0.95), RGB(0.80, 0.30, 0.50), RGB(0.55, 0.65, 0.75),
    ]
    public static let otherKinds = RGB(0.62, 0.62, 0.62)
    public static let directory = RGB(0.45, 0.45, 0.45)
    public static let freeSpace = RGB(0.92, 0.92, 0.90)
    public static let unaccounted = RGB(0.30, 0.30, 0.32)

    public static func color(forKind kind: Int) -> RGB {
        kind < kinds.count ? kinds[kind] : otherKinds
    }

    /// Color for a layout item. `extraColors` maps extra block indices to colors.
    public static func color(for node: FileTree.NodeID, in tree: FileTree, extraColors: [RGB] = []) -> RGB {
        if node < 0 { return extraColors.indices.contains(-node - 1) ? extraColors[-node - 1] : unaccounted }
        guard let kind = tree.kindID(node) else { return directory }
        return color(forKind: kind)
    }
}
