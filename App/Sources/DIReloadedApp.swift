import SwiftUI

@main
struct DIReloadedApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
        .commands { ScanCommands() }
    }
}

struct ScanCommands: Commands {
    @FocusedValue(\.session) private var session

    var body: some Commands {
        CommandMenu("Scan") {
            Button("Rescan") { session?.rescan() }
                .keyboardShortcut("r")
                .disabled(session?.target == nil)
            Button("Stop Scanning") { session?.cancel() }
                .keyboardShortcut(".")
                .disabled(session?.phase != .scanning)
            Divider()
            Button("Zoom In") { session?.zoomIn() }
                .keyboardShortcut(.downArrow)
                .disabled(session?.canZoomIn != true)
            Button("Zoom Out") { session?.zoomOut() }
                .keyboardShortcut(.upArrow)
                .disabled(session?.canZoomOut != true)
            Divider()
            Button("Show in Finder") { if let session { session.revealInFinder(session.selectedOrRoot) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(session?.tree == nil)
            Button("Quick Look") { if let session { session.quickLook(session.selectedOrRoot) } }
                .keyboardShortcut("y")
                .disabled(session?.tree == nil)
            Button("Move to Trash…") {
                if let session, let node = session.selection { TrashConfirmation.request(node, in: session) }
            }
            .keyboardShortcut(.delete)
            .disabled(session?.canTrash(session?.selection) != true)
        }
    }
}
