import ScanKit
import SwiftUI

/// Shown before the first scan: pick a volume or folder.
struct StartView: View {
    let session: ScanSession
    let volumes: VolumeList
    let chooseFolder: () -> Void
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3.square")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.tint)
                    Text("What's taking up space?").font(.largeTitle.weight(.semibold))
                    Text("Choose a disk or folder to scan.").foregroundStyle(.secondary)
                }

                if !hasFullDiskAccess {
                    FullDiskAccessCard { hasFullDiskAccess = FullDiskAccess.isGranted }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)], spacing: 16) {
                    ForEach(volumes.volumes) { volume in
                        VolumeCard(volume: volume) { session.scan(volume.target) }
                    }
                }
                .frame(maxWidth: 900)

                Button("Choose Folder…", systemImage: "folder", action: chooseFolder)
                    .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
    }
}

struct VolumeCard: View {
    let volume: Volume
    let scan: () -> Void

    var body: some View {
        Button(action: scan) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: volume.symbolName).font(.title2).foregroundStyle(.tint)
                    Spacer()
                    if let format = volume.format {
                        Text(format).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(volume.name).font(.headline).lineLimit(1)
                CapacityBar(capacity: volume.capacity).frame(height: 6)
                Text("\(Format.bytes(volume.capacity.used)) used · \(Format.bytes(volume.capacity.available)) free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .glassEffectIfAvailable(in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Scan \(volume.name)")
    }
}

struct FullDiskAccessCard: View {
    let recheck: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield").font(.title).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow Full Disk Access for a complete picture").font(.headline)
                Text("Without it, macOS hides parts of your Library (Mail, Messages, Safari, app containers) from DI Reloaded, and that space shows up as unaccounted.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
                    Button("Check Again", action: recheck)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .glassEffectIfAvailable(in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ScanningView: View {
    let session: ScanSession

    var body: some View {
        VStack(spacing: 16) {
            Text("Scanning \(session.target?.name ?? "")…").font(.title2.weight(.semibold))
            Group {
                if let fraction = session.estimatedProgress {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .frame(width: 360)
            Text("\(Format.count(session.scannedFiles)) files · \(Format.bytes(session.scannedBytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            LiveBreakdown(entries: session.scanTopLevel)
                .frame(width: 480)
            if session.scanSeemsStalled {
                Label("If macOS is asking for permission to access a folder, allow it to continue. Full Disk Access avoids these prompts.",
                      systemImage: "hand.raised")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            Button("Cancel", role: .cancel) { session.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The largest top-level folders found so far, as bars that grow while the scan runs.
struct LiveBreakdown: View {
    let entries: [ScanProgress.TopLevelEntry]
    private let limit = 8

    var body: some View {
        let shown = Array(entries.prefix(limit))
        let largest = Double(shown.first?.bytes ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.on.doc.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 140, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.accentColor.gradient)
                            .frame(width: max(4, proxy.size.width * Double(entry.bytes) / largest))
                    }
                    .frame(height: 8)
                    Text(Format.bytes(entry.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.smooth(duration: 0.3), value: shown.map(\.bytes))
        .padding(.top, 8)
    }
}

extension View {
    /// Liquid Glass on macOS 26, a material on earlier versions.
    @ViewBuilder
    func glassEffectIfAvailable(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
