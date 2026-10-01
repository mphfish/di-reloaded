import UniformTypeIdentifiers

/// A kind of file, such as "JPEG image", with totals across the scanned tree.
public struct FileKind: Sendable, Identifiable {
    public enum Category: String, Sendable, CaseIterable {
        case images, video, audio, documents, code, archives, diskImages, applications, fonts, other
    }

    /// Rank by total size: 0 is the kind taking the most space.
    public let id: Int
    public let displayName: String
    /// Lowercased extensions seen for this kind, most space first.
    public let extensions: [String]
    /// The UTType identifier, or nil for files with no extension, symlinks, and
    /// extensions the system doesn't know.
    public let typeIdentifier: String?
    public let category: Category
    public let totalSize: UInt64
    public let fileCount: Int
}

public struct KindTable: Sendable {
    /// All kinds, largest total size first. A kind's `id` is its index here.
    public let all: [FileKind]

    public subscript(id: Int) -> FileKind { all[id] }
}

/// Assigns a kind to every file node. Runs after assembly on the final, BFS-ordered arrays.
enum KindClassifier {
    static let directoryKind = UInt16.max

    /// Up to 16 bytes of lowercased extension, packed for allocation-free hashing.
    struct ExtensionKey: Hashable {
        var low: UInt64 = 0
        var high: UInt64 = 0
        var length: UInt8 = 0

        var string: String {
            var bytes: [UInt8] = []
            for i in 0 ..< Int(length) {
                let word = i < 8 ? low : high
                bytes.append(UInt8(truncatingIfNeeded: word >> (UInt64(i % 8) * 8)))
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// The extension of a file name, or nil if it has none (or one too long to be real).
    @inline(__always)
    static func extensionKey(_ name: UnsafeBufferPointer<UInt8>) -> ExtensionKey? {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return nil }
        let count = name.count - dot - 1
        guard count > 0, count <= 16 else { return nil }
        var key = ExtensionKey(length: UInt8(count))
        for i in 0 ..< count {
            var byte = name[dot + 1 + i]
            if byte == UInt8(ascii: " ") { return nil } // "Screenshot 10.23 PM" has no extension
            if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") { byte |= 0x20 }
            if i < 8 {
                key.low |= UInt64(byte) << (UInt64(i) * 8)
            } else {
                key.high |= UInt64(byte) << (UInt64(i - 8) * 8)
            }
        }
        return key
    }

    struct Result {
        var kindOfNode: [UInt16]
        var table: KindTable
    }

    static func classify(
        nameBytes: [UInt8], nameOffsets: [UInt32], nameLengths: [UInt16], sizes: [UInt64], flags: inout [UInt8]
    ) -> Result {
        let count = sizes.count
        let directory = FileTree.Flags.directory.rawValue
        let symlink = FileTree.Flags.symlink.rawValue

        // Pass 1: map each file to a provisional kind, one per distinct extension.
        // Provisional 0 is "no extension" and 1 is "symlink".
        var provisionalOfExtension: [ExtensionKey: UInt16] = [:]
        var extensionOfProvisional: [ExtensionKey?] = [nil, nil]
        var packageExtensions: [ExtensionKey: Bool] = [:]
        var kindOfNode = [UInt16](repeating: directoryKind, count: count)

        nameBytes.withUnsafeBufferPointer { bytes in
            for node in 1 ..< max(count, 1) {
                let start = Int(nameOffsets[node])
                let name = UnsafeBufferPointer(rebasing: bytes[start ..< start + Int(nameLengths[node])])

                if flags[node] & directory != 0 {
                    if let key = extensionKey(name) {
                        let isPackage = packageExtensions[key] ?? {
                            // The default lookup only matches types conforming to .data, which bundles don't.
                            let value = UTType(filenameExtension: key.string, conformingTo: .package).map { !$0.isDynamic } ?? false
                            packageExtensions[key] = value
                            return value
                        }()
                        if isPackage { flags[node] |= FileTree.Flags.package.rawValue }
                    }
                    continue
                }
                if flags[node] & symlink != 0 {
                    kindOfNode[node] = 1
                    continue
                }
                guard let key = extensionKey(name) else {
                    kindOfNode[node] = 0
                    continue
                }
                if let provisional = provisionalOfExtension[key] {
                    kindOfNode[node] = provisional
                } else if extensionOfProvisional.count < Int(directoryKind) {
                    let provisional = UInt16(extensionOfProvisional.count)
                    provisionalOfExtension[key] = provisional
                    extensionOfProvisional.append(key)
                    kindOfNode[node] = provisional
                } else {
                    kindOfNode[node] = 0 // absurdly many distinct extensions
                }
            }
        }

        // Pass 2: totals per provisional kind.
        var provisionalSize = [UInt64](repeating: 0, count: extensionOfProvisional.count)
        var provisionalCount = [Int](repeating: 0, count: extensionOfProvisional.count)
        for node in 0 ..< count where kindOfNode[node] != directoryKind {
            provisionalSize[Int(kindOfNode[node])] += sizes[node]
            provisionalCount[Int(kindOfNode[node])] += 1
        }

        // Pass 3: resolve each extension's UTType and merge extensions sharing one.
        struct Group {
            var displayName: String
            var typeIdentifier: String?
            var category: FileKind.Category
            var extensions: [(String, UInt64)] = []
            var size: UInt64 = 0
            var count = 0
        }
        var groups: [Group] = [
            Group(displayName: "Document (no extension)", typeIdentifier: nil, category: .other),
            Group(displayName: "Symbolic link", typeIdentifier: nil, category: .other),
        ]
        var groupOfIdentifier: [String: Int] = [:]
        var groupOfProvisional = [Int](repeating: 0, count: extensionOfProvisional.count)
        groupOfProvisional[1] = 1

        for provisional in 2 ..< extensionOfProvisional.count where provisionalCount[provisional] > 0 {
            let ext = extensionOfProvisional[provisional]!.string
            let type = UTType(filenameExtension: ext)
            let index: Int
            if let type, !type.isDynamic {
                if let existing = groupOfIdentifier[type.identifier] {
                    index = existing
                } else {
                    index = groups.count
                    groupOfIdentifier[type.identifier] = index
                    groups.append(Group(
                        displayName: type.localizedDescription ?? "\(ext.uppercased()) file",
                        typeIdentifier: type.identifier,
                        category: category(of: type)
                    ))
                }
            } else {
                index = groups.count
                groups.append(Group(displayName: "\(ext.uppercased()) file", typeIdentifier: nil, category: .other))
            }
            groupOfProvisional[provisional] = index
            groups[index].extensions.append((ext, provisionalSize[provisional]))
        }
        for provisional in 0 ..< extensionOfProvisional.count {
            groups[groupOfProvisional[provisional]].size += provisionalSize[provisional]
            groups[groupOfProvisional[provisional]].count += provisionalCount[provisional]
        }

        // Pass 4: rank by size and rewrite node kinds to ranks.
        let ranked = groups.indices.filter { groups[$0].count > 0 }.sorted {
            groups[$0].size != groups[$1].size ? groups[$0].size > groups[$1].size : groups[$0].displayName < groups[$1].displayName
        }
        var rankOfGroup = [UInt16](repeating: 0, count: groups.count)
        for (rank, group) in ranked.enumerated() { rankOfGroup[group] = UInt16(rank) }
        let rankOfProvisional = groupOfProvisional.map { rankOfGroup[$0] }
        for node in 0 ..< count where kindOfNode[node] != directoryKind {
            kindOfNode[node] = rankOfProvisional[Int(kindOfNode[node])]
        }

        let kinds = ranked.enumerated().map { rank, index in
            let group = groups[index]
            return FileKind(
                id: rank,
                displayName: group.displayName,
                extensions: group.extensions.sorted { $0.1 > $1.1 }.map(\.0),
                typeIdentifier: group.typeIdentifier,
                category: group.category,
                totalSize: group.size,
                fileCount: group.count
            )
        }
        return Result(kindOfNode: kindOfNode, table: KindTable(all: kinds))
    }

    static func category(of type: UTType) -> FileKind.Category {
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .diskImage) { return .diskImages }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .propertyList) { return .code }
        if type.conforms(to: .font) { return .fonts }
        if type.conforms(to: .application) || type.conforms(to: .executable) || type.conforms(to: .bundle) { return .applications }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .documents }
        return .other
    }
}
