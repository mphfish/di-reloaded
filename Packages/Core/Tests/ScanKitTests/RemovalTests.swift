import Foundation
@testable import ScanKit
import Testing

@Suite struct RemovalTests {
    @Test func removingUpdatesAncestorsKindsAndOrder() throws {
        let fixture = try Fixture()
        try fixture.file("big/a.mov", bytes: 9_000)
        try fixture.file("big/b.txt", bytes: 100)
        try fixture.file("medium/c.txt", bytes: 5_000)

        var tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let big = try #require(node(named: "big", under: tree.root, in: tree))
        let medium = try #require(node(named: "medium", under: tree.root, in: tree))
        #expect(tree.sortedChildren(tree.root) == [big, medium])
        let movie = try #require(node(named: "a.mov", under: big, in: tree))
        let movieKind = try #require(tree.kindID(movie))

        tree.remove(movie)

        #expect(tree.isRemoved(movie))
        #expect(tree.size(big) == 100)
        #expect(tree.size(tree.root) == 5_100)
        #expect(tree.descendantCount(tree.root) == 4)
        #expect(tree.kinds[movieKind].fileCount == 0)
        #expect(tree.kinds[movieKind].totalSize == 0)
        #expect(tree.sortedChildren(big).map(tree.name) == ["b.txt"])
        #expect(tree.sortedChildren(tree.root) == [medium, big]) // re-sorted by new size
    }

    @Test func removingADirectoryRemovesItsWholeSubtree() throws {
        let fixture = try Fixture()
        try fixture.file("dir/x/y/z.txt", bytes: 700)
        try fixture.file("dir/w.txt", bytes: 300)
        try fixture.file("keep.txt", bytes: 1)

        var tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let dir = try #require(node(named: "dir", under: tree.root, in: tree))
        tree.remove(dir)
        tree.remove(dir) // second removal is a no-op

        #expect(tree.size(tree.root) == 1)
        #expect(tree.descendantCount(tree.root) == 1)
        #expect(tree.kinds.all.map(\.fileCount).reduce(0, +) == 1)
    }
}
