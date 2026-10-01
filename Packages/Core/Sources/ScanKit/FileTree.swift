import Foundation

/// An immutable, compact file tree stored as parallel arrays.
///
/// Nodes are laid out breadth-first, so each directory's children are contiguous and
/// sorted by size, largest first. Node 0 is the root.
public struct FileTree: Sendable {
    public typealias NodeID = Int

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let directory    = Flags(rawValue: 1 << 0)
        public static let symlink      = Flags(rawValue: 1 << 1)
        /// A directory that couldn't be opened or read (permissions, Full Disk Access).
        public static let inaccessible = Flags(rawValue: 1 << 2)
        /// A directory on another device that was not descended into.
        public static let mountPoint   = Flags(rawValue: 1 << 3)
        /// An extra hard link to a file already counted elsewhere. Its size is 0.
        public static let hardLinkDuplicate = Flags(rawValue: 1 << 4)
        /// A directory that was excluded from the scan (e.g. the firmlinked Data volume).
        public static let excluded     = Flags(rawValue: 1 << 5)
        /// A directory macOS presents as a single file, such as an .app or .photoslibrary.
        public static let package      = Flags(rawValue: 1 << 6)
    }

    public let rootPath: String

    let parents: [UInt32]
    let firstChildren: [UInt32]
    let childCounts: [UInt32]
    let sizes: [UInt64]
    let descendantCounts: [UInt32]
    let nameOffsets: [UInt32]
    let nameLengths: [UInt16]
    let flagBits: [UInt8]
    let nameBytes: [UInt8]
    let kindIndices: [UInt16]

    /// Totals per kind of file, largest first.
    public let kinds: KindTable

    public var count: Int { sizes.count }
    public var root: NodeID { 0 }

    public func size(_ id: NodeID) -> UInt64 { sizes[id] }
    public func flags(_ id: NodeID) -> Flags { Flags(rawValue: flagBits[id]) }
    public func isDirectory(_ id: NodeID) -> Bool { flags(id).contains(.directory) }

    /// The file's kind, or nil for directories.
    public func kindID(_ id: NodeID) -> Int? {
        let kind = kindIndices[id]
        return kind == KindClassifier.directoryKind ? nil : Int(kind)
    }

    public func kind(_ id: NodeID) -> FileKind? { kindID(id).map { kinds[$0] } }

    /// Number of files and directories below this node (not counting the node itself).
    public func descendantCount(_ id: NodeID) -> Int { Int(descendantCounts[id]) }

    public func parent(_ id: NodeID) -> NodeID? {
        id == 0 ? nil : Int(parents[id])
    }

    /// Children, sorted by size, largest first.
    public func children(_ id: NodeID) -> Range<NodeID> {
        let start = Int(firstChildren[id])
        return start ..< start + Int(childCounts[id])
    }

    public func name(_ id: NodeID) -> String {
        if id == 0 { return rootPath }
        let start = Int(nameOffsets[id])
        return nameBytes.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[start ..< start + Int(nameLengths[id])]), as: UTF8.self)
        }
    }

    /// The node's name as raw UTF-8 bytes, without allocating a String.
    public func withNameBytes<R>(_ id: NodeID, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let start = Int(nameOffsets[id])
        return nameBytes.withUnsafeBufferPointer {
            body(UnsafeBufferPointer(rebasing: $0[start ..< start + Int(nameLengths[id])]))
        }
    }

    public func path(_ id: NodeID) -> String {
        var components: [String] = []
        var current = id
        while current != 0 {
            components.append(name(current))
            current = Int(parents[current])
        }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return ([base] + components.reversed()).joined(separator: "/")
    }

    /// Bytes of memory held by the tree's arrays.
    public var memoryFootprint: Int {
        parents.count * 4 + firstChildren.count * 4 + childCounts.count * 4 + sizes.count * 8
            + descendantCounts.count * 4 + nameOffsets.count * 4 + nameLengths.count * 2
            + flagBits.count + nameBytes.count + kindIndices.count * 2
    }
}
