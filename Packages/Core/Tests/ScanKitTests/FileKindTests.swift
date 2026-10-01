import Foundation
@testable import ScanKit
import Testing

@Suite struct FileKindTests {
    func key(_ name: String) -> String? {
        Array(name.utf8).withUnsafeBufferPointer { KindClassifier.extensionKey($0)?.string }
    }

    @Test func extensionParsing() {
        #expect(key("photo.JPG") == "jpg")
        #expect(key("archive.tar.gz") == "gz")
        #expect(key(".zshrc") == nil)
        #expect(key("Makefile") == nil)
        #expect(key("trailing.") == nil)
        #expect(key("Screenshot at 10.23 PM") == nil)
        #expect(key("x.abcdefghijklmnop") == "abcdefghijklmnop") // 16 bytes is the limit
        #expect(key("x.abcdefghijklmnopq") == nil)
    }

    @Test func kindsMergeByTypeAndRankBySize() throws {
        let fixture = try Fixture()
        try fixture.file("a.jpg", bytes: 1_000)
        try fixture.file("b.JPEG", bytes: 2_000)
        try fixture.file("c.txt", bytes: 10_000)
        try fixture.file("README", bytes: 50)
        try fixture.file(".hidden", bytes: 25)

        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let kinds = tree.kinds.all
        #expect(kinds.map(\.id) == Array(kinds.indices))
        #expect(kinds.map(\.totalSize) == kinds.map(\.totalSize).sorted(by: >))

        let jpeg = try #require(kinds.first { $0.typeIdentifier == "public.jpeg" })
        #expect(jpeg.fileCount == 2)
        #expect(jpeg.totalSize == 3_000)
        #expect(jpeg.extensions == ["jpeg", "jpg"]) // most space first
        #expect(jpeg.category == .images)

        let text = try #require(kinds.first { $0.typeIdentifier == "public.plain-text" })
        #expect(text.id == 0)
        #expect(text.category == .documents)

        let none = try #require(kinds.first { $0.displayName == "Document (no extension)" })
        #expect(none.fileCount == 2)
        #expect(none.totalSize == 75)

        let a = try #require(node(named: "a.jpg", under: tree.root, in: tree))
        #expect(tree.kind(a)?.id == jpeg.id)
    }

    @Test func directoriesHaveNoKindAndPackagesAreFlagged() throws {
        let fixture = try Fixture()
        try fixture.file("Thing.app/Contents/Info.plist", bytes: 10)
        try fixture.file("folder.withdot/x.c", bytes: 10)

        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let app = try #require(node(named: "Thing.app", under: tree.root, in: tree))
        #expect(tree.kindID(app) == nil)
        #expect(tree.flags(app).contains(.package))

        let folder = try #require(node(named: "folder.withdot", under: tree.root, in: tree))
        #expect(!tree.flags(folder).contains(.package))
        #expect(tree.kinds.all.map(\.fileCount).reduce(0, +) == 2) // Info.plist and x.c only
    }

    @Test func symlinksGetTheirOwnKind() throws {
        let fixture = try Fixture()
        try fixture.file("target.txt", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: fixture.root + "/link.txt", withDestinationPath: "target.txt")

        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let link = try #require(node(named: "link.txt", under: tree.root, in: tree))
        #expect(tree.kind(link)?.displayName == "Symbolic link")
    }

    @Test func unknownExtensionsStayDistinct() throws {
        let fixture = try Fixture()
        try fixture.file("a.zzqx1", bytes: 10)
        try fixture.file("b.zzqx2", bytes: 20)

        let tree = try Scanner.scan(path: fixture.root, options: logicalOptions())
        let names = Set(tree.kinds.all.map(\.displayName))
        #expect(names == ["ZZQX1 file", "ZZQX2 file"])
    }
}
