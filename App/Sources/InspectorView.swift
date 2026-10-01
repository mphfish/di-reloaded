import ScanKit
import SwiftUI

/// Details about the selection.
struct InspectorView: View {
    let session: ScanSession

    var body: some View {
        if let tree = session.tree {
            let node = session.selectedOrRoot
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(nsImage: FileIcons.icon(for: node, in: tree))
                            .resizable()
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading) {
                            Text(node == tree.root ? (session.target?.name ?? tree.name(node)) : tree.name(node))
                                .font(.headline)
                                .lineLimit(2)
                            Text(kindDescription(node, in: tree)).foregroundStyle(.secondary)
                        }
                    }

                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Size").foregroundStyle(.secondary)
                            Text(Format.bytes(tree.size(node))).monospacedDigit()
                        }
                        if tree.isDirectory(node) {
                            GridRow {
                                Text("Items").foregroundStyle(.secondary)
                                Text(Format.count(tree.descendantCount(node))).monospacedDigit()
                            }
                        }
                        if let parent = tree.parent(node), tree.size(parent) > 0 {
                            GridRow {
                                Text("Of parent").foregroundStyle(.secondary)
                                Text((Double(tree.size(node)) / Double(tree.size(parent))).formatted(.percent.precision(.fractionLength(1))))
                                    .monospacedDigit()
                            }
                        }
                        GridRow(alignment: .top) {
                            Text("Where").foregroundStyle(.secondary)
                            Text(tree.path(node))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.callout)

                    if let note = note(node, in: tree) {
                        Label(note, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button("Show in Finder", systemImage: "folder") { session.revealInFinder(node) }
                        Button("Quick Look", systemImage: "eye") { session.quickLook(node) }
                        if session.canTrash(node) {
                            Button("Move to Trash…", systemImage: "trash", role: .destructive) {
                                TrashConfirmation.request(node, in: session)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "square.dashed")
        }
    }

    private func kindDescription(_ node: FileTree.NodeID, in tree: FileTree) -> String {
        let flags = tree.flags(node)
        if flags.contains(.package) { return "Package" }
        if flags.contains(.directory) { return "Folder" }
        return tree.kind(node)?.displayName ?? "File"
    }

    private func note(_ node: FileTree.NodeID, in tree: FileTree) -> String? {
        let flags = tree.flags(node)
        if flags.contains(.inaccessible) {
            return "DI Reloaded couldn't read this folder. Granting Full Disk Access in System Settings may help."
        }
        if flags.contains(.mountPoint) { return "Another volume is mounted here; it wasn't scanned." }
        if flags.contains(.hardLinkDuplicate) { return "A hard link to a file counted elsewhere, so it adds no size here." }
        if flags.contains(.excluded) { return "Skipped to avoid counting the Data volume twice." }
        return nil
    }
}
