import ScanKit
import SwiftUI
import TreemapKit

struct SidebarView: View {
    @Bindable var session: ScanSession
    let volumes: VolumeList
    let chooseFolder: () -> Void

    var body: some View {
        List {
            Section("Locations") {
                ForEach(volumes.volumes) { volume in
                    Button {
                        session.scan(volume.target)
                    } label: {
                        VolumeRow(volume: volume, isCurrent: session.target?.url == volume.url)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: chooseFolder) {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
            }

            if let tree = session.tree {
                Section("Kinds") {
                    ForEach(tree.kinds.all.prefix(60).filter { $0.fileCount > 0 }) { kind in
                        KindRow(kind: kind, isHighlighted: session.highlightedKind == kind.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                session.highlightedKind = session.highlightedKind == kind.id ? nil : kind.id
                            }
                    }
                }
                if !session.extraBlocks.isEmpty {
                    Section("Volume") {
                        ForEach(session.extraBlocks, id: \.name) { block in
                            HStack {
                                Swatch(color: block.color.color)
                                Text(block.name)
                                Spacer()
                                Text(Format.bytes(block.size)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .help(block.name == "Unaccounted space"
                                ? "Used space the scan couldn't attribute to files: other APFS volumes, snapshots, purgeable data, and folders without access."
                                : "Space available on the volume.")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct VolumeRow: View {
    let volume: Volume
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volume.symbolName)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name).fontWeight(isCurrent ? .semibold : .regular)
                CapacityBar(capacity: volume.capacity).frame(height: 4)
                Text("\(Format.bytes(volume.capacity.available)) free of \(Format.bytes(volume.capacity.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct CapacityBar: View {
    let capacity: VolumeCapacity

    var body: some View {
        GeometryReader { proxy in
            let fraction = capacity.total > 0 ? Double(capacity.used) / Double(capacity.total) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(fraction > 0.9 ? Color.orange : Color.accentColor)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(Int((capacity.total > 0 ? Double(capacity.used) / Double(capacity.total) : 0) * 100)) percent used")
    }
}

struct KindRow: View {
    let kind: FileKind
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Swatch(color: TreemapPalette.color(forKind: kind.id).color)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName).lineLimit(1)
                Text("\(Format.count(kind.fileCount)) files").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(Format.bytes(kind.totalSize)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(isHighlighted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

struct Swatch: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color.gradient)
            .frame(width: 12, height: 12)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.15)))
    }
}
