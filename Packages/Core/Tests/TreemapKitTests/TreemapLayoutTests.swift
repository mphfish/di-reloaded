import Foundation
import ScanKit
@testable import TreemapKit
import Testing

@Suite struct TreemapLayoutTests {
    func scanFixture(_ sizes: [String: Int]) throws -> (FileTree, String) {
        let root = NSTemporaryDirectory() + "treemap-" + UUID().uuidString
        for (path, bytes) in sizes {
            let url = URL(fileURLWithPath: root + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        var options = ScanOptions()
        options.sizeMode = .logical
        return (try Scanner.scan(path: root, options: options), root)
    }

    @Test func childAreasAreProportionalAndInsideParent() throws {
        let (tree, root) = try scanFixture(["a": 6000, "b": 3000, "c": 2000, "d/e": 1000, "d/f": 1000, "g": 3000])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let bounds = TreemapRect(x: 0, y: 0, width: 600, height: 400)
        let items = TreemapLayout.layout(tree: tree, root: tree.root, in: bounds)
        let byNode = Dictionary(uniqueKeysWithValues: items.map { ($0.node, $0) })

        let total = Double(tree.size(tree.root))
        var childArea = 0.0
        for child in tree.children(tree.root) {
            let item = try #require(byNode[child])
            let expected = bounds.area * Double(tree.size(child)) / total
            #expect(abs(item.rect.area - expected) < 0.01)
            #expect(item.rect.x >= -1e-9 && item.rect.y >= -1e-9)
            #expect(item.rect.x + item.rect.width <= bounds.width + 1e-6)
            #expect(item.rect.y + item.rect.height <= bounds.height + 1e-6)
            childArea += item.rect.area
        }
        #expect(abs(childArea - bounds.area) < 0.01)
    }

    @Test func siblingsDoNotOverlap() throws {
        var files: [String: Int] = [:]
        for i in 0 ..< 60 { files["f\(i)"] = (i + 1) * 37 }
        let (tree, root) = try scanFixture(files)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let items = TreemapLayout.layout(tree: tree, root: tree.root, in: TreemapRect(x: 0, y: 0, width: 800, height: 500))
            .filter { $0.depth == 1 }
        for i in items.indices {
            for j in items.indices where j > i {
                let a = items[i].rect, b = items[j].rect
                let overlapW = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let overlapH = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                #expect(overlapW <= 1e-6 || overlapH <= 1e-6)
            }
        }
    }

    @Test func squarifiedRatiosStayReasonable() throws {
        var files: [String: Int] = [:]
        for i in 0 ..< 40 { files["f\(i)"] = 1000 + i * 50 }
        let (tree, root) = try scanFixture(files)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let items = TreemapLayout.layout(tree: tree, root: tree.root, in: TreemapRect(x: 0, y: 0, width: 1000, height: 1000))
            .filter { $0.depth == 1 }
        let worst = items.map { max($0.rect.width / $0.rect.height, $0.rect.height / $0.rect.width) }.max() ?? 0
        #expect(worst < 3)
    }

    @Test func tinyItemsAreCulled() throws {
        let (tree, root) = try scanFixture(["huge": 10_000_000, "tiny": 1])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let items = TreemapLayout.layout(tree: tree, root: tree.root, in: TreemapRect(x: 0, y: 0, width: 100, height: 100))
        #expect(items.count == 2) // root + huge
    }

    @Test func hitTestFindsDeepestItem() throws {
        let (tree, root) = try scanFixture(["dir/only": 500])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let items = TreemapLayout.layout(tree: tree, root: tree.root, in: TreemapRect(x: 0, y: 0, width: 100, height: 100))
        let hit = try #require(TreemapLayout.hitTest(items, x: 50, y: 50))
        #expect(tree.name(hit.node) == "only")
        #expect(TreemapLayout.hitTest(items, x: 150, y: 50) == nil)
    }
}

@Suite struct TreemapExtrasTests {
    @Test func extrasAreLaidOutBesideRootChildren() throws {
        let root = NSTemporaryDirectory() + "treemap-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: URL(fileURLWithPath: root + "/file"))
        var options = ScanOptions()
        options.sizeMode = .logical
        let tree = try Scanner.scan(path: root, options: options)

        let bounds = TreemapRect(x: 0, y: 0, width: 400, height: 100)
        let items = TreemapLayout.layout(tree: tree, root: tree.root, in: bounds, extras: [3_000])
        let extra = try #require(items.first { $0.extraIndex == 0 })
        #expect(abs(extra.rect.area - bounds.area * 0.75) < 0.01)
        let file = try #require(items.first { $0.node > 0 })
        #expect(abs(file.rect.area - bounds.area * 0.25) < 0.01)
    }

    @Test func removedNodesDisappearFromLayout() throws {
        let root = NSTemporaryDirectory() + "treemap-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: URL(fileURLWithPath: root + "/a"))
        try Data(count: 2_000).write(to: URL(fileURLWithPath: root + "/b"))
        var options = ScanOptions()
        options.sizeMode = .logical
        var tree = try Scanner.scan(path: root, options: options)
        let b = try #require(tree.children(tree.root).first { tree.name($0) == "b" })
        tree.remove(b)

        let items = TreemapLayout.layout(tree: tree, root: tree.root, in: TreemapRect(x: 0, y: 0, width: 100, height: 100))
        #expect(items.map(\.node).contains(b) == false)
        #expect(items.count == 2)
        #expect(abs(items[1].rect.area - 10_000) < 0.01) // "a" now fills everything
    }
}
