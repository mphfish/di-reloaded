import AppKit
import Observation

struct Volume: Identifiable, Hashable {
    var id: URL { url }
    var url: URL
    var name: String
    var capacity: VolumeCapacity
    var isRoot: Bool
    var isInternal: Bool
    var format: String?

    var target: ScanTarget {
        ScanTarget(url: url, name: name, capacity: capacity)
    }

    var symbolName: String {
        isRoot ? "internaldrive" : isInternal ? "internaldrive" : "externaldrive"
    }
}

/// Mounted, browsable volumes, kept current as disks come and go.
@MainActor
@Observable
final class VolumeList {
    static let shared = VolumeList()

    private(set) var volumes: [Volume] = []

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        reload()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { VolumeList.shared.reload() }
            })
        }
    }

    func reload() {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
            .volumeIsBrowsableKey, .volumeLocalizedFormatDescriptionKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable != false else { return nil }
            let total = UInt64(values.volumeTotalCapacity ?? 0)
            // "Important usage" includes purgeable space, matching what Finder reports.
            let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
                ?? UInt64(values.volumeAvailableCapacity ?? 0)
            return Volume(
                url: url,
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                capacity: VolumeCapacity(total: total, available: min(available, total)),
                isRoot: values.volumeIsRootFileSystem ?? false,
                isInternal: values.volumeIsInternal ?? false,
                format: values.volumeLocalizedFormatDescription
            )
        }
        .sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }
}
