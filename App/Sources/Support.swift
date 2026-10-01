import AppKit
import ScanKit
import SwiftUI
import TreemapKit
import UniformTypeIdentifiers

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }
}

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Full Disk Access can't be requested from code; it can only be detected and the user
/// sent to System Settings.
enum FullDiskAccess {
    /// Reading the TCC database requires Full Disk Access.
    static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return errno != EPERM && errno != EACCES
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Icons for outline rows, cached by kind so each type is looked up once.
@MainActor
enum FileIcons {
    private static var byKind: [Int: NSImage] = [:]
    private static var byPath: [String: NSImage] = [:]
    static let folder = NSWorkspace.shared.icon(for: .folder)
    static let document = NSWorkspace.shared.icon(for: .data)

    static func icon(for node: FileTree.NodeID, in tree: FileTree) -> NSImage {
        let flags = tree.flags(node)
        if flags.contains(.package) {
            let path = tree.path(node)
            if let cached = byPath[path] { return cached }
            let image = NSWorkspace.shared.icon(forFile: path)
            byPath[path] = image
            return image
        }
        if flags.contains(.directory) { return folder }
        guard let kind = tree.kind(node) else { return document }
        if let cached = byKind[kind.id] { return cached }
        let image = kind.typeIdentifier.flatMap(UTType.init).map { NSWorkspace.shared.icon(for: $0) } ?? document
        byKind[kind.id] = image
        return image
    }

    /// Kind ids change between scans.
    static func reset() {
        byKind = [:]
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
