import QuickLook
import ScanKit
import SwiftUI

struct ContentView: View {
    @State private var session = ScanSession()
    @State private var showInspector = true
    @State private var trashError: String?
    private let volumes = VolumeList.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(session: session, volumes: volumes, chooseFolder: chooseFolder)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail.toolbar { toolbar }
        }
        .navigationTitle(session.target?.name ?? "DI Reloaded")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $showInspector) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .quickLookPreview($session.quickLookURL)
        .confirmationDialog(trashTitle, isPresented: trashBinding, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard let node = session.pendingTrash else { return }
                do {
                    try session.moveToTrash(node)
                } catch {
                    trashError = error.localizedDescription
                }
            }
        } message: {
            Text("You can restore it from the Trash later.")
        }
        .alert("Couldn't move to Trash", isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
        } message: {
            Text(trashError ?? "")
        }
        .focusedSceneValue(\.session, session)
        .task {
            // Development aid: `-scan <path>` starts scanning at launch.
            if session.phase == .idle, let path = UserDefaults.standard.string(forKey: "scan") {
                let url = URL(fileURLWithPath: path)
                let volume = volumes.volumes.first { $0.url.standardizedFileURL == url.standardizedFileURL }
                session.scan(volume?.target ?? ScanTarget(url: url, name: url.lastPathComponent, capacity: nil))
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch session.phase {
        case .idle:
            StartView(session: session, volumes: volumes, chooseFolder: chooseFolder)
        case .scanning:
            ScanningView(session: session)
        case .failed(let message):
            ContentUnavailableView {
                Label("Scan Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { session.rescan() }
            }
        case .done:
            HSplitView {
                FileOutlineView(session: session, revision: session.revision, selection: session.selection)
                    .frame(minWidth: 300, idealWidth: 420)
                TreemapPane(session: session)
                    .frame(minWidth: 320)
                    .layoutPriority(1)
            }
        }
    }

    private var subtitle: String {
        guard let tree = session.tree else { return "" }
        let scanned = "\(Format.bytes(tree.size(tree.root))) in \(Format.count(tree.descendantCount(tree.root))) items"
        return session.scanDuration > 0 ? "\(scanned) · scanned in \(session.scanDuration.formatted(.number.precision(.fractionLength(1))))s" : scanned
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Zoom Out", systemImage: "arrow.up.left.and.arrow.down.right") { session.zoomOut() }
                .help("Zoom out to the enclosing folder")
                .disabled(!session.canZoomOut)
            Button("Zoom In", systemImage: "arrow.down.right.and.arrow.up.left") { session.zoomIn() }
                .help("Zoom into the selected folder")
                .disabled(!session.canZoomIn)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Show in Finder", systemImage: "folder") { session.revealInFinder(session.selectedOrRoot) }
                .disabled(session.tree == nil)
            Button("Quick Look", systemImage: "eye") { session.quickLook(session.selectedOrRoot) }
                .disabled(session.tree == nil)
            Button("Move to Trash", systemImage: "trash") {
                if let node = session.selection { TrashConfirmation.request(node, in: session) }
            }
            .disabled(!session.canTrash(session.selection))
            Button("Rescan", systemImage: "arrow.clockwise") { session.rescan() }
                .disabled(session.target == nil || session.phase == .scanning)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
        }
    }

    private var trashBinding: Binding<Bool> {
        Binding(get: { session.pendingTrash != nil }, set: { if !$0 { session.pendingTrash = nil } })
    }

    private var trashTitle: String {
        guard let node = session.pendingTrash, let tree = session.tree else { return "" }
        return "Move “\(tree.name(node))” (\(Format.bytes(tree.size(node)))) to the Trash?"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.scan(ScanTarget(url: url, name: url.lastPathComponent, capacity: nil))
    }
}

extension FocusedValues {
    @Entry var session: ScanSession?
}
