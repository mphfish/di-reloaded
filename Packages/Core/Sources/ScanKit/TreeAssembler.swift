/// Merges per-worker scan output into a `FileTree`.
///
/// Temporary node `t` is 0 for the root and `1 + i` for the i-th entry across all workers.
/// Directory job ids always increase from parent to child, which lets totals be summed in
/// a single reverse pass.
enum TreeAssembler {
    static func assemble(rootPath: String, workers: [WorkerOutput], directoryCount: Int) -> FileTree {
        let entryCount = workers.reduce(0) { $0 + $1.size.count }
        let nodeCount = entryCount + 1

        // 1. Concatenate worker output into temporary arrays.
        var parentDirectory = [UInt32](repeating: 0, count: nodeCount)
        var nameOffset = [UInt32](repeating: 0, count: nodeCount)
        var nameLength = [UInt16](repeating: 0, count: nodeCount)
        var size = [UInt64](repeating: 0, count: nodeCount)
        var flags = [UInt8](repeating: 0, count: nodeCount)
        var nameBytes: [UInt8] = []
        nameBytes.reserveCapacity(workers.reduce(0) { $0 + $1.names.count })

        // Temporary node index of each directory, by job id.
        var directoryNode = [UInt32](repeating: 0, count: directoryCount)
        flags[0] = FileTree.Flags.directory.rawValue

        var t = 1
        for worker in workers {
            let base = UInt32(nameBytes.count)
            nameBytes.append(contentsOf: worker.names)
            for i in 0 ..< worker.size.count {
                parentDirectory[t] = worker.parentDirectory[i]
                nameOffset[t] = worker.nameOffset[i] + base
                nameLength[t] = worker.nameLength[i]
                size[t] = worker.size[i]
                flags[t] = worker.flags[i]
                let id = worker.directoryID[i]
                if id != WorkerOutput.noDirectory { directoryNode[Int(id)] = UInt32(t) }
                t += 1
            }
        }
        for worker in workers {
            for (id, extra) in worker.directoryFlags {
                flags[Int(directoryNode[Int(id)])] |= extra
            }
        }

        // 2. Sum sizes and descendant counts up the tree.
        var descendants = [UInt32](repeating: 0, count: nodeCount)
        for node in 1 ..< nodeCount where flags[node] & FileTree.Flags.directory.rawValue == 0 {
            let parent = Int(directoryNode[Int(parentDirectory[node])])
            size[parent] += size[node]
            descendants[parent] += 1
        }
        for id in stride(from: directoryCount - 1, through: 1, by: -1) {
            let node = Int(directoryNode[id])
            let parent = Int(directoryNode[Int(parentDirectory[node])])
            size[parent] += size[node]
            descendants[parent] += descendants[node] + 1
        }
        // Directories that were skipped (mount points, excluded) never got a job id but are
        // still entries; count them as descendants too.
        for node in 1 ..< nodeCount
        where flags[node] & FileTree.Flags.directory.rawValue != 0 && !hasJob(node: node, flags: flags) {
            descendants[Int(directoryNode[Int(parentDirectory[node])])] += 1
        }

        // 3. Group children by parent (CSR layout), then sort each group by size.
        var childStart = [Int](repeating: 0, count: directoryCount + 1)
        for node in 1 ..< nodeCount { childStart[Int(parentDirectory[node]) + 1] += 1 }
        for i in 0 ..< directoryCount { childStart[i + 1] += childStart[i] }
        var fill = childStart
        var grouped = [UInt32](repeating: 0, count: entryCount)
        for node in 1 ..< nodeCount {
            let dir = Int(parentDirectory[node])
            grouped[fill[dir]] = UInt32(node)
            fill[dir] += 1
        }
        grouped.withUnsafeMutableBufferPointer { buffer in
            for dir in 0 ..< directoryCount where childStart[dir + 1] - childStart[dir] > 1 {
                buffer[childStart[dir] ..< childStart[dir + 1]].sort { size[Int($0)] > size[Int($1)] }
            }
        }
        // Job id of each temporary directory node, to find its children group.
        var jobOfNode = [Int32](repeating: -1, count: nodeCount)
        for id in 0 ..< directoryCount { jobOfNode[Int(directoryNode[id])] = Int32(id) }

        // 4. Emit nodes breadth-first so siblings are contiguous.
        var order = [UInt32](repeating: 0, count: nodeCount)
        var finalParent = [UInt32](repeating: 0, count: nodeCount)
        var firstChild = [UInt32](repeating: 0, count: nodeCount)
        var childCount = [UInt32](repeating: 0, count: nodeCount)
        var emitted = 1
        var cursor = 0
        while cursor < emitted {
            let node = Int(order[cursor])
            firstChild[cursor] = UInt32(emitted)
            let job = jobOfNode[node]
            if job >= 0 {
                let range = childStart[Int(job)] ..< childStart[Int(job) + 1]
                childCount[cursor] = UInt32(range.count)
                for child in grouped[range] {
                    order[emitted] = child
                    finalParent[emitted] = UInt32(cursor)
                    emitted += 1
                }
            }
            cursor += 1
        }

        func permute<T>(_ values: [T]) -> [T] { order.map { values[Int($0)] } }

        let finalSizes = permute(size)
        let finalNameOffsets = permute(nameOffset)
        let finalNameLengths = permute(nameLength)
        var finalFlags = permute(flags)
        let kinds = KindClassifier.classify(
            nameBytes: nameBytes, nameOffsets: finalNameOffsets, nameLengths: finalNameLengths,
            sizes: finalSizes, flags: &finalFlags
        )

        return FileTree(
            rootPath: rootPath,
            parents: finalParent,
            firstChildren: firstChild,
            childCounts: childCount,
            sizes: finalSizes,
            descendantCounts: permute(descendants),
            nameOffsets: finalNameOffsets,
            nameLengths: finalNameLengths,
            flagBits: finalFlags,
            nameBytes: nameBytes,
            kindIndices: kinds.kindOfNode,
            kinds: kinds.table
        )
    }

    private static func hasJob(node: Int, flags: [UInt8]) -> Bool {
        let skipped = FileTree.Flags.mountPoint.rawValue | FileTree.Flags.excluded.rawValue
        return flags[node] & skipped == 0
    }
}
