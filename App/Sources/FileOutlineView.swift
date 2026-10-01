import AppKit
import ScanKit
import SwiftUI

/// The folder/file list. An NSOutlineView, because it stays fast with millions of
/// lazily loaded rows.
struct FileOutlineView: NSViewRepresentable {
    let session: ScanSession
    // Passed in so SwiftUI updates the view when they change.
    let revision: Int
    let selection: FileTree.NodeID?

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.autosaveExpandedItems = false
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14

        for column in Coordinator.Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 160 : 60
            tableColumn.headerCell.alignment = column.alignment
            outline.addTableColumn(tableColumn)
            if column == .name { outline.outlineTableColumn = tableColumn }
        }
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.menu = context.coordinator.contextMenu
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(revision: revision, selection: selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        enum Column: String, CaseIterable {
            case name, size, items, kind

            var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
            var title: String {
                switch self {
                case .name: "Name"
                case .size: "Size"
                case .items: "Items"
                case .kind: "Kind"
                }
            }
            var width: CGFloat {
                switch self {
                case .name: 280
                case .size: 80
                case .items: 70
                case .kind: 140
                }
            }
            var alignment: NSTextAlignment { self == .size || self == .items ? .right : .left }
        }

        /// NSOutlineView tracks items by object identity, so each node gets one stable box.
        final class Node {
            let id: FileTree.NodeID
            init(_ id: FileTree.NodeID) { self.id = id }
        }

        let session: ScanSession
        weak var outline: NSOutlineView?
        private var boxes: [FileTree.NodeID: Node] = [:]
        private var childCache: [FileTree.NodeID: [FileTree.NodeID]] = [:]
        private var revision = -1
        private var isSelectingProgrammatically = false
        lazy var contextMenu: NSMenu = {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }()

        init(session: ScanSession) {
            self.session = session
        }

        private func box(_ id: FileTree.NodeID) -> Node {
            if let box = boxes[id] { return box }
            let box = Node(id)
            boxes[id] = box
            return box
        }

        private func children(of id: FileTree.NodeID) -> [FileTree.NodeID] {
            if let cached = childCache[id] { return cached }
            let children = session.tree?.sortedChildren(id) ?? []
            childCache[id] = children
            return children
        }

        func update(revision: Int, selection: FileTree.NodeID?) {
            guard let outline else { return }
            if revision != self.revision {
                if session.tree == nil || self.revision == -1 { boxes = [:] }
                self.revision = revision
                childCache = [:]
                FileIcons.reset()
                outline.reloadData()
            }
            select(selection, in: outline)
        }

        private func select(_ node: FileTree.NodeID?, in outline: NSOutlineView) {
            let current = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Node)?.id : nil
            guard current != node else { return }
            isSelectingProgrammatically = true
            defer { isSelectingProgrammatically = false }

            guard let node, let tree = session.tree, node != tree.root else {
                outline.deselectAll(nil)
                return
            }
            // Expand from the top down so each level's rows exist.
            var ancestors: [FileTree.NodeID] = []
            var cursor = tree.parent(node)
            while let parent = cursor, parent != tree.root {
                ancestors.append(parent)
                cursor = tree.parent(parent)
            }
            for ancestor in ancestors.reversed() { outline.expandItem(box(ancestor)) }
            let row = outline.row(forItem: box(node))
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let tree = session.tree else { return 0 }
            return children(of: (item as? Node)?.id ?? tree.root).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let parent = (item as? Node)?.id ?? session.tree?.root ?? 0
            return box(children(of: parent)[index])
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node, let tree = session.tree else { return false }
            return tree.isDirectory(node.id) && !tree.children(node.id).isEmpty
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let tree = session.tree,
                  let column = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) })
            else { return nil }

            let identifier = column.identifier
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(column)
            let flags = tree.flags(node.id)
            switch column {
            case .name:
                cell.textField?.stringValue = tree.name(node.id)
                cell.imageView?.image = FileIcons.icon(for: node.id, in: tree)
                cell.textField?.textColor = flags.contains(.inaccessible) || flags.contains(.mountPoint) ? .secondaryLabelColor : .labelColor
            case .size:
                cell.textField?.stringValue = Format.bytes(tree.size(node.id))
            case .items:
                cell.textField?.stringValue = tree.isDirectory(node.id) ? Format.count(tree.descendantCount(node.id)) : ""
            case .kind:
                if flags.contains(.inaccessible) {
                    cell.textField?.stringValue = "No access"
                } else if flags.contains(.mountPoint) {
                    cell.textField?.stringValue = "Other volume"
                } else if flags.contains(.package) {
                    cell.textField?.stringValue = "Package"
                } else {
                    cell.textField?.stringValue = tree.kind(node.id)?.displayName ?? "Folder"
                }
            }
            return cell
        }

        private func makeCell(_ column: Column) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = column.identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.alignment = column.alignment
            text.translatesAutoresizingMaskIntoConstraints = false
            if column == .size || column == .items {
                text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            if column == .kind { text.textColor = .secondaryLabelColor }
            cell.addSubview(text)
            cell.textField = text

            if column == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSelectingProgrammatically, let outline else { return }
            let node = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Node)?.id : nil
            session.selection = node
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? Node,
                  let tree = session.tree, tree.isDirectory(node.id)
            else { return }
            session.zoom(to: node.id)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
            session.selection = node.id
            for item in FileActions.menuItems(for: node.id, in: session) { menu.addItem(item) }
        }
    }
}

/// Actions shared by the outline and treemap context menus.
@MainActor
enum FileActions {
    static func menuItems(for node: FileTree.NodeID, in session: ScanSession) -> [NSMenuItem] {
        guard let tree = session.tree else { return [] }
        var items: [NSMenuItem] = [
            ClosureMenuItem("Show in Finder", symbol: "folder") { session.revealInFinder(node) },
            ClosureMenuItem("Quick Look", symbol: "eye") { session.quickLook(node) },
        ]
        if tree.isDirectory(node) {
            items.append(ClosureMenuItem("Zoom In", symbol: "plus.magnifyingglass") { session.zoom(to: node) })
        }
        items.append(.separator())
        items.append(ClosureMenuItem("Copy Path", symbol: "doc.on.doc") {
            guard let path = session.tree?.path(node) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        })
        if session.canTrash(node) {
            items.append(.separator())
            items.append(ClosureMenuItem("Move to Trash…", symbol: "trash") { TrashConfirmation.request(node, in: session) })
        }
        return items
    }
}

/// Lets AppKit menus ask the SwiftUI window to show its Move to Trash confirmation.
@MainActor
enum TrashConfirmation {
    static func request(_ node: FileTree.NodeID, in session: ScanSession) {
        session.selection = node
        session.pendingTrash = node
    }
}
