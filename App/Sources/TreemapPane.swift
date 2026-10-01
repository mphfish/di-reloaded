import ScanKit
import SwiftUI
import TreemapKit
import TreemapView

struct TreemapRepresentable: NSViewRepresentable {
    let session: ScanSession
    // Passed in so SwiftUI updates the view when they change.
    let revision: Int
    let zoomRoot: FileTree.NodeID
    let selection: FileTree.NodeID?
    let highlightedKind: Int?

    final class Coordinator {
        var revision = -1
        var zoomRoot = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TreemapMetalView {
        let view = TreemapMetalView()
        view.dataSource = session
        view.onHover = { [weak session] item in session?.hovered = item }
        view.onClick = { [weak session] item in
            guard let session else { return }
            session.selection = item.flatMap { $0.node >= 0 ? $0.node : nil }
        }
        view.onDoubleClick = { [weak session] item in
            guard let session, item.node >= 0 else { return }
            session.zoom(to: item.node)
        }
        view.onContextMenu = { [weak session] item, _ in
            guard let session, item.node >= 0 else { return nil }
            let menu = NSMenu()
            for menuItem in FileActions.menuItems(for: item.node, in: session) { menu.addItem(menuItem) }
            return menu
        }
        return view
    }

    func updateNSView(_ view: TreemapMetalView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.revision != revision || coordinator.zoomRoot != zoomRoot {
            coordinator.revision = revision
            coordinator.zoomRoot = zoomRoot
            view.reloadData()
        }
        view.selectedNode = selection
        view.highlightedKind = highlightedKind
    }
}

struct TreemapPane: View {
    @Bindable var session: ScanSession

    var body: some View {
        TreemapRepresentable(
            session: session,
            revision: session.revision,
            zoomRoot: session.zoomRoot,
            selection: session.selection,
            highlightedKind: session.highlightedKind
        )
        .accessibilityLabel("Treemap of \(session.target?.name ?? "scan")")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(session: session)
        }
    }
}

/// Shows what's under the pointer, or the selection.
struct StatusBar: View {
    let session: ScanSession

    var body: some View {
        HStack(spacing: 8) {
            if let (title, detail) = description {
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Text(detail).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("Hover over the treemap to see what takes up space.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var description: (String, String)? {
        guard let tree = session.tree else { return nil }
        if let item = session.hovered {
            if let extra = item.extraIndex, session.extraBlocks.indices.contains(extra) {
                let block = session.extraBlocks[extra]
                return (block.name, Format.bytes(block.size))
            }
            guard item.node >= 0 && item.node < tree.count else { return nil }
            return describe(item.node, in: tree)
        }
        return session.selection.map { describe($0, in: tree) }
    }

    private func describe(_ node: FileTree.NodeID, in tree: FileTree) -> (String, String) {
        let kind = tree.kind(node)?.displayName ?? (tree.isDirectory(node) ? "\(Format.count(tree.descendantCount(node))) items" : "")
        return (tree.path(node), "\(Format.bytes(tree.size(node)))  ·  \(kind)")
    }
}
