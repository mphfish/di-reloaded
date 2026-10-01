import Foundation
import ScanKit

public struct TreemapRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

/// Coefficients of a cushion surface z = s2x·x² + s1x·x + s2y·y² + s1y·y
/// (van Wijk & van de Wetering, "Cushion Treemaps", 1999).
public struct Cushion: Sendable, Equatable {
    public var s1x = 0.0, s2x = 0.0, s1y = 0.0, s2y = 0.0

    /// Adds a parabolic ridge spanning `rect` with the given height.
    mutating func addRidge(_ rect: TreemapRect, height h: Double) {
        if rect.width > 0 {
            let x1 = rect.x, x2 = rect.x + rect.width
            s1x += 4 * h * (x2 + x1) / (x2 - x1)
            s2x -= 4 * h / (x2 - x1)
        }
        if rect.height > 0 {
            let y1 = rect.y, y2 = rect.y + rect.height
            s1y += 4 * h * (y2 + y1) / (y2 - y1)
            s2y -= 4 * h / (y2 - y1)
        }
    }
}

public struct TreemapItem: Sendable {
    public var rect: TreemapRect
    public var node: FileTree.NodeID
    public var depth: Int
    public var cushion: Cushion
}

public enum TreemapLayout {
    /// Ridge height for the top level; each level down is scaled by `heightFactor`.
    public static let initialHeight = 0.5
    public static let heightFactor = 0.75
    /// Rectangles smaller than this (in points²) are not laid out.
    public static let minimumArea = 1.0

    /// Lays out the subtree under `root` with the squarified algorithm
    /// (Bruls, Huizing & van Wijk, 2000). Items are returned parent-first, so painting them
    /// in order draws children over their parent.
    public static func layout(tree: FileTree, root: FileTree.NodeID, in bounds: TreemapRect) -> [TreemapItem] {
        var items: [TreemapItem] = []
        items.reserveCapacity(Int(min(Double(tree.count), bounds.area / 4)))

        var rootCushion = Cushion()
        rootCushion.addRidge(bounds, height: initialHeight)
        items.append(TreemapItem(rect: bounds, node: root, depth: 0, cushion: rootCushion))

        // Indices into `items` whose children still need laying out.
        var stack = [0]
        var row: [(node: FileTree.NodeID, area: Double)] = []

        while let index = stack.popLast() {
            let parent = items[index]
            let total = Double(tree.size(parent.node))
            guard tree.isDirectory(parent.node), total > 0 else { continue }

            let scale = parent.rect.area / total
            let childHeight = initialHeight * pow(heightFactor, Double(parent.depth + 1))
            var free = parent.rect
            let children = tree.children(parent.node)
            var next = children.lowerBound

            while next < children.upperBound {
                // Children are sorted largest first, so everything after a too-small child
                // is too small as well.
                let firstArea = Double(tree.size(next)) * scale
                if firstArea < minimumArea { break }

                let side = min(free.width, free.height)
                guard side > 0 else { break }

                row.removeAll(keepingCapacity: true)
                row.append((next, firstArea))
                var rowArea = firstArea
                var rowMin = firstArea, rowMax = firstArea
                next += 1

                while next < children.upperBound {
                    let area = Double(tree.size(next)) * scale
                    if area < minimumArea { break }
                    let current = worstRatio(sum: rowArea, min: rowMin, max: rowMax, side: side)
                    let candidate = worstRatio(sum: rowArea + area, min: Swift.min(rowMin, area), max: Swift.max(rowMax, area), side: side)
                    if candidate > current { break }
                    row.append((next, area))
                    rowArea += area
                    rowMin = Swift.min(rowMin, area)
                    rowMax = Swift.max(rowMax, area)
                    next += 1
                }

                // Lay the row along the shorter side of the free space.
                let horizontal = free.width >= free.height
                let thickness = rowArea / side
                var offset = 0.0
                for (node, area) in row {
                    let length = area / thickness
                    let rect = horizontal
                        ? TreemapRect(x: free.x, y: free.y + offset, width: thickness, height: length)
                        : TreemapRect(x: free.x + offset, y: free.y, width: length, height: thickness)
                    offset += length

                    var cushion = parent.cushion
                    cushion.addRidge(rect, height: childHeight)
                    items.append(TreemapItem(rect: rect, node: node, depth: parent.depth + 1, cushion: cushion))
                    if tree.isDirectory(node), rect.width >= 1, rect.height >= 1 {
                        stack.append(items.count - 1)
                    }
                }
                if horizontal {
                    free.x += thickness
                    free.width = Swift.max(0, free.width - thickness)
                } else {
                    free.y += thickness
                    free.height = Swift.max(0, free.height - thickness)
                }
            }
        }
        return items
    }

    /// The worst aspect ratio in a row of rectangles with total area `sum`, laid along a
    /// side of length `side`.
    @inline(__always)
    static func worstRatio(sum: Double, min: Double, max: Double, side: Double) -> Double {
        let s2 = sum * sum, w2 = side * side
        return Swift.max(w2 * max / s2, s2 / (w2 * min))
    }

    /// The deepest item containing the point, or nil if it's outside the layout.
    public static func hitTest(_ items: [TreemapItem], x: Double, y: Double) -> TreemapItem? {
        // Items are parent-first, so the last match is the deepest.
        items.last { $0.rect.contains(x: x, y: y) }
    }
}
