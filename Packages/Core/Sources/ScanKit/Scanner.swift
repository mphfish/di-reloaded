import CBulkAttr
import Darwin
import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    public enum SizeMode: Sendable { case allocated, logical }

    public var sizeMode: SizeMode = .allocated
    /// Worker thread count. Scans are bound by SSD latency for metadata reads, and past
    /// about six threads APFS contention costs more than the extra parallelism gains
    /// (measured on an M5, see PLAN.md).
    public var threads: Int = min(ProcessInfo.processInfo.activeProcessorCount, 6)
    /// Descend into directories that live on other devices.
    public var crossMountPoints = false

    public init() {}
}

/// Live counters a UI can poll while a scan runs. Also used to cancel.
public final class ScanProgress: Sendable {
    let filesCounter = Atomic<Int>(0)
    let directoriesCounter = Atomic<Int>(0)
    let bytesCounter = Atomic<UInt64>(0)
    let cancelled = Atomic<Bool>(false)
    let walkNanos = Atomic<UInt64>(0)
    let assembleNanos = Atomic<UInt64>(0)

    public init() {}

    /// Time spent reading directories, and time spent building the tree afterwards.
    public var walkSeconds: Double { Double(walkNanos.load(ordering: .relaxed)) / 1e9 }
    public var assembleSeconds: Double { Double(assembleNanos.load(ordering: .relaxed)) / 1e9 }

    public var files: Int { filesCounter.load(ordering: .relaxed) }
    public var directories: Int { directoriesCounter.load(ordering: .relaxed) }
    public var bytes: UInt64 { bytesCounter.load(ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }
}

public enum ScanError: Error, Equatable {
    case cannotOpenRoot(path: String, errno: Int32)
    case cancelled
}

public enum Scanner {
    /// Scans `path` and returns the full tree. Blocks the calling thread; call it from a
    /// background task.
    public static func scan(
        path: String,
        options: ScanOptions = ScanOptions(),
        progress: ScanProgress = ScanProgress()
    ) throws(ScanError) -> FileTree {
        let rootPath = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path

        var rootStat = stat()
        guard stat(rootPath, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw .cannotOpenRoot(path: rootPath, errno: errno)
        }

        let context = ScanContext(
            rootPath: rootPath,
            rootDevice: rootStat.st_dev,
            options: options,
            progress: progress
        )
        let walkStart = DispatchTime.now().uptimeNanoseconds
        context.run()
        let assembleStart = DispatchTime.now().uptimeNanoseconds
        progress.walkNanos.store(assembleStart - walkStart, ordering: .relaxed)

        if progress.isCancelled { throw .cancelled }
        let tree = TreeAssembler.assemble(rootPath: rootPath, workers: context.outputs, directoryCount: context.directoryCount)
        progress.assembleNanos.store(DispatchTime.now().uptimeNanoseconds - assembleStart, ordering: .relaxed)
        return tree
    }
}

// MARK: - Internals

/// A directory waiting to be read.
struct DirectoryJob {
    let id: UInt32
    let path: String
}

/// Entries one worker found. Each entry belongs to a directory identified by its job id.
final class WorkerOutput: @unchecked Sendable {
    static let noDirectory = UInt32.max

    var parentDirectory: [UInt32] = []
    var nameOffset: [UInt32] = []
    var nameLength: [UInt16] = []
    var size: [UInt64] = []
    /// The entry's own directory job id, or `noDirectory` for non-directories.
    var directoryID: [UInt32] = []
    var flags: [UInt8] = []
    var names: [UInt8] = []
    /// Flags discovered for directories once they're read (e.g. inaccessible), keyed by job id.
    var directoryFlags: [(UInt32, UInt8)] = []

    func append(parent: UInt32, name: UnsafeRawBufferPointer, size: UInt64, directoryID: UInt32, flags: FileTree.Flags) {
        parentDirectory.append(parent)
        nameOffset.append(UInt32(names.count))
        nameLength.append(UInt16(name.count))
        names.append(contentsOf: name)
        self.size.append(size)
        self.directoryID.append(directoryID)
        self.flags.append(flags.rawValue)
    }
}

final class ScanContext: @unchecked Sendable {
    let rootPath: String
    let rootDevice: dev_t
    let options: ScanOptions
    let progress: ScanProgress

    private let condition = NSCondition()
    private var queue: [DirectoryJob] = []
    /// Jobs queued or in progress. The scan ends when this reaches zero.
    private var pending = 0
    private var nextDirectoryID: UInt32 = 1

    private let hardLinks = Mutex<Set<UInt64>>([])
    /// On the system volume, the Data volume is reachable both through firmlinks and at
    /// this path. Skip the path so nothing is counted twice.
    private let excludedPaths: Set<String>
    /// When scanning `/`, firmlinks such as /Users lead onto the Data volume, which has
    /// its own device id. Those are followed rather than treated as mount points.
    private let dataVolumeDevice: dev_t?

    private(set) var outputs: [WorkerOutput] = []
    var directoryCount: Int { Int(nextDirectoryID) }

    init(rootPath: String, rootDevice: dev_t, options: ScanOptions, progress: ScanProgress) {
        self.rootPath = rootPath
        self.rootDevice = rootDevice
        self.options = options
        self.progress = progress
        self.excludedPaths = rootPath == "/" ? ["/System/Volumes/Data"] : []
        var dataStat = stat()
        self.dataVolumeDevice = rootPath == "/" && stat("/System/Volumes/Data", &dataStat) == 0 ? dataStat.st_dev : nil
    }

    func run() {
        queue.append(DirectoryJob(id: 0, path: rootPath))
        pending = 1

        let threadCount = max(1, options.threads)
        outputs = (0 ..< threadCount).map { _ in WorkerOutput() }

        let group = DispatchGroup()
        for output in outputs {
            let thread = Thread { [self] in
                work(output: output)
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            group.enter()
            thread.start()
        }
        group.wait()
    }

    private func nextJob() -> DirectoryJob? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty {
            if pending == 0 { return nil }
            condition.wait()
        }
        return queue.removeLast()
    }

    /// Assigns ids to newly found subdirectories and marks the current job finished.
    private func finish(adding paths: [String], ids: inout [UInt32]) {
        condition.lock()
        defer { condition.unlock() }
        for path in paths {
            let id = nextDirectoryID
            nextDirectoryID += 1
            ids.append(id)
            queue.append(DirectoryJob(id: id, path: path))
        }
        pending += paths.count - 1
        if !paths.isEmpty || pending == 0 {
            condition.broadcast()
        }
    }


    private func work(output: WorkerOutput) {
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        let entryCapacity = dib_max_entries(bufferSize)
        let entries = UnsafeMutablePointer<dib_entry>.allocate(capacity: entryCapacity)
        defer {
            buffer.deallocate()
            entries.deallocate()
        }

        var subdirectoryPaths: [String] = []
        var subdirectoryNames: [(offset: Int, length: Int)] = []
        var newIDs: [UInt32] = []
        var scratchNames: [UInt8] = []

        while let job = nextJob() {
            subdirectoryPaths.removeAll(keepingCapacity: true)
            subdirectoryNames.removeAll(keepingCapacity: true)
            scratchNames.removeAll(keepingCapacity: true)
            newIDs.removeAll(keepingCapacity: true)

            if progress.isCancelled {
                finish(adding: [], ids: &newIDs)
                continue
            }

            progress.directoriesCounter.add(1, ordering: .relaxed)
            let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                output.directoryFlags.append((job.id, FileTree.Flags.inaccessible.rawValue))
                finish(adding: [], ids: &newIDs)
                continue
            }

            var fileCount = 0
            var byteCount: UInt64 = 0
            let prefix = job.path == "/" ? "" : job.path

            while true {
                let count = dib_read_entries(fd, buffer, bufferSize, entries)
                if count < 0 {
                    output.directoryFlags.append((job.id, FileTree.Flags.inaccessible.rawValue))
                    break
                }
                if count == 0 { break }

                for i in 0 ..< Int(count) {
                    let entry = entries[i]
                    guard let namePointer = entry.name else { continue }
                    let name = UnsafeRawBufferPointer(start: namePointer, count: Int(entry.name_len))

                    switch entry.type {
                    case UInt32(DIB_TYPE_DIR.rawValue):
                        var flags: FileTree.Flags = .directory
                        let path = prefix + "/" + String(decoding: name, as: UTF8.self)
                        if !options.crossMountPoints && dev_t(entry.dev) != rootDevice && !isFirmlinkedDataVolume(entry.dev) {
                            flags.insert(.mountPoint)
                        } else if excludedPaths.contains(path) {
                            flags.insert(.excluded)
                        }
                        if flags == .directory {
                            subdirectoryPaths.append(path)
                            subdirectoryNames.append((scratchNames.count, name.count))
                            scratchNames.append(contentsOf: name)
                        } else {
                            output.append(parent: job.id, name: name, size: 0, directoryID: WorkerOutput.noDirectory, flags: flags)
                        }

                    default:
                        var flags: FileTree.Flags = entry.type == UInt32(DIB_TYPE_SYMLINK.rawValue) ? .symlink : []
                        var size = options.sizeMode == .allocated ? entry.alloc_size : entry.logical_size
                        if entry.link_count > 1 && entry.type == UInt32(DIB_TYPE_FILE.rawValue) {
                            let isFirst = hardLinks.withLock { $0.insert(entry.file_id).inserted }
                            if !isFirst {
                                flags.insert(.hardLinkDuplicate)
                                size = 0
                            }
                        }
                        output.append(parent: job.id, name: name, size: size, directoryID: WorkerOutput.noDirectory, flags: flags)
                        fileCount += 1
                        byteCount += size
                    }
                }
            }
            close(fd)

            progress.filesCounter.add(fileCount, ordering: .relaxed)
            progress.bytesCounter.add(byteCount, ordering: .relaxed)

            finish(adding: subdirectoryPaths, ids: &newIDs)
            scratchNames.withUnsafeBytes { bytes in
                for (index, id) in newIDs.enumerated() {
                    let range = subdirectoryNames[index]
                    let name = UnsafeRawBufferPointer(rebasing: bytes[range.offset ..< range.offset + range.length])
                    output.append(parent: job.id, name: name, size: 0, directoryID: id, flags: .directory)
                }
            }
        }
    }

    private func isFirmlinkedDataVolume(_ device: Int32) -> Bool {
        dataVolumeDevice.map { $0 == dev_t(device) } ?? false
    }
}
