import Foundation
@testable import ScanKit
import Testing

/// A temporary directory tree that removes itself when the test ends.
final class Fixture {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "scankit-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions so cleanup can remove locked directories.
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let path as String in enumerator { chmod(root + "/" + path, 0o755) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func file(_ path: String, bytes: Int) throws {
        let url = URL(fileURLWithPath: root + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    func directory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: root + "/" + path, withIntermediateDirectories: true)
    }
}

func logicalOptions(threads: Int = 4) -> ScanOptions {
    var options = ScanOptions()
    options.sizeMode = .logical
    options.threads = threads
    return options
}

func node(named name: String, under parent: FileTree.NodeID, in tree: FileTree) -> FileTree.NodeID? {
    tree.children(parent).first { tree.name($0) == name }
}

@Suite struct ScannerTests {
    @Test func totalsMatchKnownSizes() throws {
        let fixture = try Fixture()
        try fixture.file("a.txt", bytes: 100)
        try fixture.file("dir/b.bin", bytes: 2_000)
        try fixture.file("dir/sub/c.bin", bytes: 30_000)
        try fixture.file("dir/sub/d.bin", bytes: 5)
        try fixture.directory("empty")

        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())

        #expect(tree.size(tree.root) == 32_105)
        #expect(tree.count == 8) // root, a.txt, dir, b.bin, sub, c.bin, d.bin, empty
        #expect(tree.descendantCount(tree.root) == 7)

        let dir = try #require(node(named: "dir", under: tree.root, in: tree))
        #expect(tree.isDirectory(dir))
        #expect(tree.size(dir) == 32_005)
        let sub = try #require(node(named: "sub", under: dir, in: tree))
        #expect(tree.size(sub) == 30_005)
        #expect(tree.path(sub) == fixture.root + "/dir/sub")

        let empty = try #require(node(named: "empty", under: tree.root, in: tree))
        #expect(tree.size(empty) == 0)
        #expect(tree.children(empty).isEmpty)
    }

    @Test func childrenAreSortedLargestFirstAndParentsLinkBack() throws {
        let fixture = try Fixture()
        for (i, size) in [10, 5000, 300, 70, 999].enumerated() {
            try fixture.file("f\(i)", bytes: size)
        }
        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let sizes = tree.children(tree.root).map(tree.size)
        #expect(sizes == [5000, 999, 300, 70, 10])
        for child in tree.children(tree.root) { #expect(tree.parent(child) == tree.root) }
    }

    @Test func hardLinksAreCountedOnce() throws {
        let fixture = try Fixture()
        try fixture.file("original", bytes: 4_000)
        try fixture.directory("other")
        try FileManager.default.linkItem(atPath: fixture.root + "/original", toPath: fixture.root + "/other/link")

        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        #expect(tree.size(tree.root) == 4_000)
        let duplicates = (0 ..< tree.count).filter { tree.flags($0).contains(.hardLinkDuplicate) }
        #expect(duplicates.count == 1)
    }

    @Test func symlinksAreNotFollowed() throws {
        let fixture = try Fixture()
        try fixture.file("target/big", bytes: 50_000)
        try FileManager.default.createSymbolicLink(atPath: fixture.root + "/link", withDestinationPath: fixture.root + "/target")

        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let link = try #require(node(named: "link", under: tree.root, in: tree))
        #expect(tree.flags(link).contains(.symlink))
        #expect(!tree.isDirectory(link))
        #expect(tree.size(tree.root) < 51_000)
    }

    @Test func unreadableDirectoriesAreFlagged() throws {
        let fixture = try Fixture()
        try fixture.file("locked/secret", bytes: 1_000)
        try fixture.file("open", bytes: 10)
        chmod(fixture.root + "/locked", 0o000)

        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let locked = try #require(node(named: "locked", under: tree.root, in: tree))
        #expect(tree.flags(locked).contains(.inaccessible))
        #expect(tree.size(tree.root) == 10)
    }

    @Test func allocatedSizeIsAtLeastLogicalSize() throws {
        let fixture = try Fixture()
        try fixture.file("one-byte", bytes: 1)
        var options = ScanOptions()
        options.sizeMode = .allocated
        let tree = try Scanner.scan(path: fixture.root, options: options)
        #expect(tree.size(tree.root) >= 1)
    }

    @Test(arguments: [1, 2, 8, 32])
    func resultIsIndependentOfThreadCount(threads: Int) throws {
        let fixture = try Fixture()
        for d in 0 ..< 20 {
            for f in 0 ..< 15 { try fixture.file("d\(d)/e\(d % 3)/f\(f)", bytes: d * 100 + f + 1) }
        }
        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions(threads: threads))
        let expected = (0 ..< 20).reduce(0) { sum, d in sum + (0 ..< 15).reduce(0) { $0 + d * 100 + $1 + 1 } }
        #expect(tree.size(tree.root) == UInt64(expected))
        #expect(tree.count == 1 + 20 * (1 + 1 + 15))
    }

    @Test func missingRootThrows() {
        #expect(throws: ScanError.self) {
            try Scanner.scan(path: "/definitely/not/here-\(UUID().uuidString)")
        }
    }

    @Test func cancellationThrows() throws {
        let fixture = try Fixture()
        try fixture.file("a/b", bytes: 1)
        let progress = ScanProgress()
        progress.cancel()
        #expect(throws: ScanError.cancelled) {
            try Scanner.scan(path: fixture.root, progress: progress)
        }
    }

    @Test func namesWithUnicodeRoundTrip() throws {
        let fixture = try Fixture()
        try fixture.file("Fotos 📷/résumé.pdf", bytes: 12)
        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let photos = try #require(node(named: "Fotos 📷", under: tree.root, in: tree))
        #expect(tree.children(photos).map(tree.name) == ["résumé.pdf"])
    }
}

@Suite struct ProgressTests {
    @Test func topLevelSnapshotMatchesFinalTree() throws {
        let fixture = try Fixture()
        try fixture.file("photos/a/b/c.jpg", bytes: 9_000)
        try fixture.file("photos/d.jpg", bytes: 1_000)
        try fixture.file("code/main.swift", bytes: 500)
        try fixture.file("loose1.txt", bytes: 30)
        try fixture.file("loose2.txt", bytes: 20)
        try fixture.directory("empty")

        let progress = ScanProgress()
        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions(), progress: progress)
        let snapshot = progress.topLevelSnapshot()

        #expect(snapshot.map(\.name) == ["photos", "code", "Files"])
        #expect(snapshot.map(\.bytes) == [10_000, 500, 50])
        #expect(snapshot.map(\.bytes).reduce(0, +) == tree.size(tree.root))
        #expect(snapshot.last?.isDirectory == false)
    }
}
