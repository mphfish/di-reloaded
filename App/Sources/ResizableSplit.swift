import SwiftUI

/// A two-pane horizontal split with a draggable divider. HSplitView mispositions its first
/// pane inside a macOS 26 NavigationSplitView detail column, so this is plain SwiftUI.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    @AppStorage("outlineWidth") private var leadingWidth = 440.0
    @State private var dragStartWidth: Double?
    let minLeading: Double
    let minTrailing: Double
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        GeometryReader { proxy in
            let maxLeading = max(minLeading, proxy.size.width - minTrailing)
            let width = min(max(leadingWidth, minLeading), maxLeading)
            HStack(spacing: 0) {
                leading.frame(width: width)
                Divider()
                    .overlay {
                        Color.clear
                            .frame(width: 8)
                            .contentShape(Rectangle())
                            .pointerStyle(.frameResize(position: .trailing))
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        let start = dragStartWidth ?? width
                                        dragStartWidth = start
                                        leadingWidth = min(max(start + value.translation.width, minLeading), maxLeading)
                                    }
                                    .onEnded { _ in dragStartWidth = nil }
                            )
                    }
                trailing.frame(maxWidth: .infinity)
            }
        }
    }
}
