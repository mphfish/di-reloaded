import Darwin
import Foundation
import ScanKit
import TreemapKit

// dir-bench: measures how fast ScanKit walks a directory tree.
//
//   dir-bench <path> [--threads N] [--logical] [--runs N] [--top N] [--kinds N]
//                    [--treemap out.png] [--json] [--inaccessible]
//   dir-bench <path> --filemanager         FileManager baseline
//   dir-bench --generate <dir> [--files N]  create a synthetic fixture tree

struct Arguments {
    var path = "."
    var threads: Int?
    var logical = false
    var runs = 1
    var top = 10
    var kinds = 10
    var fileManagerBaseline = false
    var treemapOutput: String?
    var json = false
    var listInaccessible = false
    var generate: String?
    var generateFiles = 200_000
}

func parseArguments() -> Arguments {
    var result = Arguments()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--threads": result.threads = args.next().flatMap(Int.init)
        case "--logical": result.logical = true
        case "--runs": result.runs = max(1, args.next().flatMap(Int.init) ?? 1)
        case "--top": result.top = args.next().flatMap(Int.init) ?? 10
        case "--kinds": result.kinds = args.next().flatMap(Int.init) ?? 10
        case "--filemanager": result.fileManagerBaseline = true
        case "--treemap": result.treemapOutput = args.next()
        case "--json": result.json = true
        case "--inaccessible": result.listInaccessible = true
        case "--generate": result.generate = args.next()
        case "--files": result.generateFiles = args.next().flatMap(Int.init) ?? 200_000
        default: result.path = arg
        }
    }
    return result
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_maxrss) // bytes on macOS
}

func measure<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let value = try body()
    let elapsed = ContinuousClock.now - start
    return (value, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// Baseline: what a straightforward FileManager implementation achieves.
func fileManagerScan(path: String) -> (files: Int, bytes: UInt64) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
    ) else { return (0, 0) }
    var files = 0
    var bytes: UInt64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
        files += 1
        bytes += UInt64(values.totalFileAllocatedSize ?? 0)
    }
    return (files, bytes)
}

/// Creates a deterministic tree of `fileCount` sparse files: up to 40 files and 6
/// subdirectories per directory, with a mix of extensions.
func generateFixture(at root: String, fileCount: Int) {
    let extensions = ["jpg", "png", "mov", "mp3", "swift", "c", "h", "json", "txt", "pdf", "zip", "dmg", "plist", "", "o", "dylib"]
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func random() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 33
    }

    var queue = [root]
    var made = 0
    var head = 0
    while made < fileCount {
        let dir = queue[head]
        head += 1
        mkdir(dir, 0o755)
        let files = min(Int(random() % 40) + 1, fileCount - made)
        for i in 0 ..< files {
            let ext = extensions[Int(random() % UInt64(extensions.count))]
            let path = "\(dir)/file\(i)" + (ext.isEmpty ? "" : ".\(ext)")
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd < 0 { fail("can't create \(path)") }
            ftruncate(fd, off_t(random() % (1 << 20)))
            close(fd)
        }
        made += files
        for i in 0 ..< Int(random() % 6) + 1 { queue.append("\(dir)/dir\(i)") }
    }
}

let arguments = parseArguments()

if let root = arguments.generate {
    let (_, seconds) = measure { generateFixture(at: root, fileCount: arguments.generateFiles) }
    print("generated \(arguments.generateFiles) files in \(root) (\(String(format: "%.1f", seconds))s)")
    exit(0)
}

if arguments.fileManagerBaseline {
    let (result, seconds) = measure { fileManagerScan(path: arguments.path) }
    print("FileManager: \(result.files) files, \(formatBytes(result.bytes)) in \(String(format: "%.2f", seconds))s"
        + " (\(Int(Double(result.files) / seconds)) files/s)")
    exit(0)
}

var options = ScanOptions()
if let threads = arguments.threads { options.threads = threads }
if arguments.logical { options.sizeMode = .logical }

// Best of N runs.
var best: (tree: FileTree, seconds: Double, progress: ScanProgress)?
for _ in 0 ..< arguments.runs {
    let progress = ScanProgress()
    do {
        let (tree, seconds) = try measure { try Scanner.scan(path: arguments.path, options: options, progress: progress) }
        if best == nil || seconds < best!.seconds { best = (tree, seconds, progress) }
    } catch {
        fail("scan failed: \(error)")
    }
}
let (tree, seconds, progress) = best!

let bounds = TreemapRect(x: 0, y: 0, width: 1600, height: 1000)
let (layout, layoutSeconds) = measure { TreemapLayout.layout(tree: tree, root: tree.root, in: bounds) }

if arguments.json {
    let summary: [String: Any] = [
        "path": tree.rootPath,
        "entries": tree.count,
        "seconds": seconds,
        "walkSeconds": progress.walkSeconds,
        "assembleSeconds": progress.assembleSeconds,
        "totalBytes": tree.size(tree.root),
        "bytesPerEntry": tree.memoryFootprint / max(tree.count, 1),
        "layoutRects": layout.count,
        "layoutMilliseconds": layoutSeconds * 1000,
        "kinds": tree.kinds.all.count,
    ]
    let data = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

let inaccessible = (0 ..< tree.count).reduce(0) { $0 + (tree.flags($1).contains(.inaccessible) ? 1 : 0) }

print("""
ScanKit (\(options.threads) threads, \(options.sizeMode) size\(arguments.runs > 1 ? ", best of \(arguments.runs)" : ""))
  path:          \(tree.rootPath)
  entries:       \(tree.count) (\(progress.files) files, \(progress.directories) dirs read, \(inaccessible) inaccessible)
  total:         \(formatBytes(tree.size(tree.root)))
  time:          \(String(format: "%.3f", seconds))s  (\(Int(Double(tree.count) / seconds)) entries/s)
  phases:        walk \(String(format: "%.3f", progress.walkSeconds))s, assemble \(String(format: "%.3f", progress.assembleSeconds))s
  tree memory:   \(formatBytes(UInt64(tree.memoryFootprint))) (\(tree.memoryFootprint / max(tree.count, 1)) bytes/entry)
  peak RSS:      \(formatBytes(peakResidentBytes()))
  layout:        \(layout.count) rects at 1600×1000 in \(String(format: "%.1f", layoutSeconds * 1000))ms
""")

func column(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }

if arguments.top > 0 {
    print("  largest children:")
    for child in tree.children(tree.root).prefix(arguments.top) {
        let marker = tree.isDirectory(child) ? "/" : ""
        print("    \(column(formatBytes(tree.size(child)), 10)) \(tree.name(child))\(marker)")
    }
}

if arguments.kinds > 0 {
    print("  largest kinds (\(tree.kinds.all.count) total):")
    for kind in tree.kinds.all.prefix(arguments.kinds) {
        let extensions = kind.extensions.prefix(3).map { "." + $0 }.joined(separator: " ")
        print("    \(column(formatBytes(kind.totalSize), 10)) \(column(String(kind.fileCount), 8)) \(column(kind.category.rawValue, 12)) \(kind.displayName)  \(extensions)")
    }
}

if arguments.listInaccessible {
    print("  inaccessible directories:")
    for node in 0 ..< tree.count where tree.flags(node).contains(.inaccessible) { print("    " + tree.path(node)) }
}

if let output = arguments.treemapOutput {
    let (_, renderSeconds) = measure { try? TreemapImageRenderer.writePNG(layout: layout, tree: tree, size: bounds, to: output) }
    print("  render+encode: \(String(format: "%.1f", renderSeconds * 1000))ms → \(output)")
}
