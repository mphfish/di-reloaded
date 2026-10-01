import Darwin
import Foundation
import ScanKit
import TreemapKit

// dir-bench: measures how fast ScanKit walks a directory tree.
//
//   dir-bench <path> [--threads N] [--logical] [--top N] [--filemanager] [--treemap out.png]

struct Arguments {
    var path = "."
    var threads: Int?
    var logical = false
    var top = 10
    var fileManagerBaseline = false
    var treemapOutput: String?
}

func parseArguments() -> Arguments {
    var result = Arguments()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--threads": result.threads = args.next().flatMap(Int.init)
        case "--logical": result.logical = true
        case "--top": result.top = args.next().flatMap(Int.init) ?? 10
        case "--filemanager": result.fileManagerBaseline = true
        case "--treemap": result.treemapOutput = args.next()
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

let arguments = parseArguments()

if arguments.fileManagerBaseline {
    let (result, seconds) = measure { fileManagerScan(path: arguments.path) }
    print("FileManager: \(result.files) files, \(formatBytes(result.bytes)) in \(String(format: "%.2f", seconds))s"
        + " (\(Int(Double(result.files) / seconds)) files/s)")
    exit(0)
}

var options = ScanOptions()
if let threads = arguments.threads { options.threads = threads }
if arguments.logical { options.sizeMode = .logical }

let progress = ScanProgress()
let (tree, seconds): (FileTree, Double)
do {
    (tree, seconds) = try measure { try Scanner.scan(path: arguments.path, options: options, progress: progress) }
} catch {
    FileHandle.standardError.write("scan failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let inaccessible = (0 ..< tree.count).reduce(0) { $0 + (tree.flags($1).contains(.inaccessible) ? 1 : 0) }

print("""
ScanKit (\(options.threads) threads, \(options.sizeMode) size)
  path:          \(tree.rootPath)
  entries:       \(tree.count) (\(progress.files) files, \(progress.directories) dirs read, \(inaccessible) inaccessible)
  total:         \(formatBytes(tree.size(tree.root)))
  time:          \(String(format: "%.3f", seconds))s  (\(Int(Double(tree.count) / seconds)) entries/s)
  phases:        walk \(String(format: "%.3f", progress.walkSeconds))s, assemble \(String(format: "%.3f", progress.assembleSeconds))s
  tree memory:   \(formatBytes(UInt64(tree.memoryFootprint))) (\(tree.memoryFootprint / max(tree.count, 1)) bytes/entry)
  peak RSS:      \(formatBytes(peakResidentBytes()))
""")

if arguments.top > 0 {
    print("  largest children:")
    for child in tree.children(tree.root).prefix(arguments.top) {
        let marker = tree.isDirectory(child) ? "/" : ""
        print("    \(formatBytes(tree.size(child)).padding(toLength: 10, withPad: " ", startingAt: 0)) \(tree.name(child))\(marker)")
    }
}

if let output = arguments.treemapOutput {
    let bounds = TreemapRect(x: 0, y: 0, width: 1600, height: 1000)
    let (layout, layoutSeconds) = measure { TreemapLayout.layout(tree: tree, root: tree.root, in: bounds) }
    let (_, renderSeconds) = measure { try? TreemapImageRenderer.writePNG(layout: layout, tree: tree, size: bounds, to: output) }
    print("""
    Treemap 1600×1000
      rects:         \(layout.count)
      layout:        \(String(format: "%.1f", layoutSeconds * 1000))ms
      render+encode: \(String(format: "%.1f", renderSeconds * 1000))ms
      written to:    \(output)
    """)
}
