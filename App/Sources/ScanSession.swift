import AppKit
import Observation
import ScanKit
import TreemapKit
import TreemapView

/// Something to scan: a volume or a folder.
struct ScanTarget: Hashable {
    var url: URL
    var name: String
    /// Set for whole volumes, so free and unaccounted space can be shown.
    var capacity: VolumeCapacity?
}

struct VolumeCapacity: Hashable {
    var total: UInt64
    var available: UInt64
    var used: UInt64 { total > available ? total - available : 0 }
}

/// One window's scan: its tree, selection, zoom and highlight.
@MainActor
@Observable
final class ScanSession {
    enum Phase: Equatable {
        case idle
        case scanning
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var target: ScanTarget?
    private(set) var tree: FileTree?
    /// Bumped whenever the tree's contents change, so views know to reload.
    private(set) var revision = 0

    var selection: FileTree.NodeID?
    private(set) var zoomRoot: FileTree.NodeID = 0
    var hovered: TreemapItem?
    var highlightedKind: Int?
    var quickLookURL: URL?
    /// A node waiting for the user to confirm Move to Trash.
    var pendingTrash: FileTree.NodeID?

    // Live progress while scanning.
    private(set) var scannedFiles = 0
    private(set) var scannedBytes: UInt64 = 0
    private(set) var scanStarted = Date.now
    private(set) var scanDuration: TimeInterval = 0
    /// True when nothing new has been found for a while, usually because macOS is waiting
    /// for the user to answer a folder access prompt.
    private(set) var scanSeemsStalled = false

    @ObservationIgnored private var progress: ScanProgress?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    // MARK: Scanning

    func scan(_ target: ScanTarget) {
        cancel()
        self.target = target
        tree = nil
        selection = nil
        zoomRoot = 0
        hovered = nil
        highlightedKind = nil
        scannedFiles = 0
        scannedBytes = 0
        scanSeemsStalled = false
        scanStarted = .now
        phase = .scanning

        let progress = ScanProgress()
        self.progress = progress
        let path = target.url.path(percentEncoded: false)

        scanTask = Task {
            let polling = Task {
                var lastChange = ContinuousClock.now
                while !Task.isCancelled {
                    if progress.files != scannedFiles { lastChange = .now }
                    scannedFiles = progress.files
                    scannedBytes = progress.bytes
                    scanSeemsStalled = ContinuousClock.now - lastChange > .seconds(2)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws(ScanError) in try Scanner.scan(path: path, progress: progress) }
            }.value
            polling.cancel()
            guard self.progress === progress else { return } // superseded by another scan

            switch result {
            case .success(let tree):
                self.tree = tree
                scanDuration = Date.now.timeIntervalSince(scanStarted)
                revision += 1
                phase = .done
            case .failure(.cancelled):
                phase = .idle
            case .failure(.cannotOpenRoot(let path, let code)):
                phase = .failed("Couldn't open \(path): \(String(cString: strerror(code)))")
            }
        }
    }

    func cancel() {
        progress?.cancel()
        progress = nil
        scanTask = nil
        if phase == .scanning { phase = tree == nil ? .idle : .done }
    }

    func rescan() {
        if let target { scan(target) }
    }

    /// Fraction done, estimated from bytes found against the volume's used space.
    var estimatedProgress: Double? {
        guard let used = target?.capacity?.used, used > 0 else { return nil }
        return min(1, Double(scannedBytes) / Double(used))
    }

    // MARK: Navigation

    var selectedOrRoot: FileTree.NodeID { selection ?? zoomRoot }

    func zoom(to node: FileTree.NodeID) {
        guard let tree else { return }
        var directory = node
        while !tree.isDirectory(directory), let parent = tree.parent(directory) { directory = parent }
        zoomRoot = directory
    }

    func zoomIn() {
        if let selection { zoom(to: selection) }
    }

    func zoomOut() {
        guard let tree, let parent = tree.parent(zoomRoot) else { return }
        selection = zoomRoot
        zoomRoot = parent
    }

    var canZoomIn: Bool {
        guard let tree, let selection else { return false }
        return tree.isDirectory(selection) && selection != zoomRoot
    }

    var canZoomOut: Bool { zoomRoot != 0 }

    // MARK: Files

    func url(of node: FileTree.NodeID) -> URL? {
        tree.map { URL(fileURLWithPath: $0.path(node)) }
    }

    func revealInFinder(_ node: FileTree.NodeID) {
        guard let url = url(of: node) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func quickLook(_ node: FileTree.NodeID) {
        quickLookURL = url(of: node)
    }

    func canTrash(_ node: FileTree.NodeID?) -> Bool {
        guard let node, let tree else { return false }
        return node != tree.root && !tree.isRemoved(node)
    }

    /// Moves a file or folder to the Trash and updates the tree without rescanning.
    func moveToTrash(_ node: FileTree.NodeID) throws {
        guard canTrash(node), let url = url(of: node) else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        let parent = tree?.parent(node)
        tree?.remove(node)
        if selection == node { selection = parent }
        if hovered?.node == node { hovered = nil }
        revision += 1
    }

    // MARK: Extra blocks

    static let freeSpaceColor = TreemapPalette.freeSpace
    static let unaccountedColor = TreemapPalette.unaccounted

    /// Free space and "used but not found by the scan", for whole-volume scans.
    var extraBlocks: [(name: String, size: UInt64, color: RGB)] {
        guard let capacity = target?.capacity, let tree else { return [] }
        let scanned = tree.size(tree.root)
        let unaccounted = capacity.used > scanned ? capacity.used - scanned : 0
        return [
            ("Free space", capacity.available, Self.freeSpaceColor),
            ("Unaccounted space", unaccounted, Self.unaccountedColor),
        ].filter { $0.1 > 0 }
    }
}

extension ScanSession: TreemapDataSource {
    var treemapTree: FileTree? { tree }
    var treemapRoot: FileTree.NodeID { zoomRoot }
    var treemapExtras: [(size: UInt64, color: RGB)] { extraBlocks.map { ($0.size, $0.color) } }
}
