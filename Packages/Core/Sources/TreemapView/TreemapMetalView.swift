import AppKit
import MetalKit
import ScanKit
import TreemapKit

/// Supplies what the treemap draws. The view asks again whenever it needs a new layout
/// (resize, `reloadData()`), and doesn't hold on to the tree in between, so the owner can
/// mutate its tree without triggering a copy.
@MainActor
public protocol TreemapDataSource: AnyObject {
    var treemapTree: FileTree? { get }
    /// The node to show, for zooming in.
    var treemapRoot: FileTree.NodeID { get }
    /// Blocks laid out beside the root's children, such as free space.
    var treemapExtras: [(size: UInt64, color: RGB)] { get }
}

/// A cushion treemap drawn with Metal: one instanced draw call per frame.
@MainActor
public final class TreemapMetalView: MTKView, MTKViewDelegate {
    public weak var dataSource: (any TreemapDataSource)?

    public var onHover: ((TreemapItem?) -> Void)?
    public var onClick: ((TreemapItem?) -> Void)?
    public var onDoubleClick: ((TreemapItem) -> Void)?
    public var onContextMenu: ((TreemapItem, NSEvent) -> NSMenu?)?

    /// Outlined in the accent color. If the node is too small to have its own rectangle,
    /// its nearest visible ancestor is outlined instead.
    public var selectedNode: FileTree.NodeID? { didSet { if oldValue != selectedNode { rebuildOverlay() } } }
    /// Dims every file that isn't of this kind.
    public var highlightedKind: Int? { didSet { if oldValue != highlightedKind { rebuildInstances() } } }

    public private(set) var items: [TreemapItem] = []
    /// Kind per item: -1 for directories, -2 for extras.
    private var itemKinds: [Int32] = []
    private var itemColors: [RGB] = []
    private var itemIndexOfNode: [FileTree.NodeID: Int] = [:]
    private var hoveredIndex: Int? { didSet { if oldValue != hoveredIndex { rebuildOverlay() } } }

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var instanceBuffer: MTLBuffer?
    private var instanceCount = 0
    private var overlayBuffer: MTLBuffer?
    private var overlayCount = 0
    private var trackingArea: NSTrackingArea?

    struct Instance {
        var rect: SIMD4<Float>
        var shade: SIMD4<Float>
        var color: SIMD4<Float>
    }

    public init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { fatalError("Metal is not available") }
        commandQueue = queue

        do {
            let library = try device.makeLibrary(source: TreemapShaders.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "treemap_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "treemap_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Treemap shaders failed to compile: \(error)")
        }

        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        delegate = self
        setAccessibilityRole(.image)
        setAccessibilityLabel("Treemap")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    /// Lays out again from the data source.
    public func reloadData() {
        relayout()
    }

    // MARK: Layout and buffers

    private var pixelScale: Double { Double(window?.backingScaleFactor ?? 2) }

    private func relayout() {
        let size = drawableSize
        guard let source = dataSource, let tree = source.treemapTree, size.width > 0, size.height > 0 else {
            items = []
            itemKinds = []
            itemIndexOfNode = [:]
            rebuildInstances()
            return
        }
        let root = source.treemapRoot
        let extras = root == tree.root ? source.treemapExtras : []
        let bounds = TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
        items = TreemapLayout.layout(tree: tree, root: root, in: bounds, extras: extras.map(\.size))

        let extraColors = extras.map(\.color)
        itemKinds = items.map { item in
            item.node < 0 ? -2 : tree.kindID(item.node).map(Int32.init) ?? -1
        }
        itemColors = items.map { TreemapPalette.color(for: $0.node, in: tree, extraColors: extraColors) }
        itemIndexOfNode = Dictionary(items.indices.map { (items[$0].node, $0) }, uniquingKeysWith: { $1 })
        hoveredIndex = nil
        rebuildInstances()
    }

    private func rebuildInstances() {
        var instances: [Instance] = []
        instances.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            var color = itemColors[index]
            if let highlightedKind, itemKinds[index] != Int32(highlightedKind) {
                color = RGB(color.r * 0.3, color.g * 0.3, color.b * 0.3)
            }
            instances.append(instance(for: item, color: color))
        }
        instanceBuffer = makeBuffer(instances)
        instanceCount = instances.count
        rebuildOverlay()
    }

    private func instance(for item: TreemapItem, color: RGB) -> Instance {
        // Re-base the cushion polynomial at the rect origin in double precision, so the
        // shader only evaluates small numbers.
        let c = item.cushion
        let r = item.rect
        return Instance(
            rect: SIMD4(Float(r.x), Float(r.y), Float(r.width), Float(r.height)),
            shade: SIMD4(Float(2 * c.s2x * r.x + c.s1x), Float(2 * c.s2x), Float(2 * c.s2y * r.y + c.s1y), Float(2 * c.s2y)),
            color: SIMD4(Float(color.r), Float(color.g), Float(color.b), 1)
        )
    }

    private func rebuildOverlay() {
        var overlay: [Instance] = []
        let scale = Float(pixelScale)
        func outline(_ rect: TreemapRect, width: Float, color: SIMD3<Float>) {
            let x = Float(rect.x), y = Float(rect.y), w = Float(rect.width), h = Float(rect.height)
            let t = min(width, w / 2, h / 2)
            let solid = SIMD4(color, 0)
            for r in [SIMD4(x, y, w, t), SIMD4(x, y + h - t, w, t), SIMD4(x, y, t, h), SIMD4(x + w - t, y, t, h)] {
                overlay.append(Instance(rect: r, shade: .zero, color: solid))
            }
        }
        if let hoveredIndex, hoveredIndex < items.count {
            outline(items[hoveredIndex].rect, width: 1 * scale, color: SIMD3(1, 1, 1))
        }
        if let selectedNode, let index = visibleItemIndex(for: selectedNode) {
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            outline(items[index].rect, width: 2 * scale,
                    color: SIMD3(Float(accent.redComponent), Float(accent.greenComponent), Float(accent.blueComponent)))
        }
        overlayBuffer = makeBuffer(overlay)
        overlayCount = overlay.count
        needsDisplay = true
    }

    private func visibleItemIndex(for node: FileTree.NodeID) -> Int? {
        if let index = itemIndexOfNode[node] { return index }
        guard let tree = dataSource?.treemapTree, node < tree.count else { return nil }
        var current = node
        while let parent = tree.parent(current) {
            if let index = itemIndexOfNode[parent] { return index }
            current = parent
        }
        return nil
    }

    private func makeBuffer(_ instances: [Instance]) -> MTLBuffer? {
        guard !instances.isEmpty else { return nil }
        return instances.withUnsafeBytes { device?.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        relayout()
    }

    public func draw(in view: MTKView) {
        guard let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = commandQueue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        var viewport = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        for (buffer, count) in [(instanceBuffer, instanceCount), (overlayBuffer, overlayCount)] {
            guard let buffer, count > 0 else { continue }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    // MARK: Mouse

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func itemIndex(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let x = Double(point.x) * pixelScale, y = Double(point.y) * pixelScale
        // Items are parent-first, so the last match is the deepest.
        return items.lastIndex { $0.rect.contains(x: x, y: y) }
    }

    override public func mouseMoved(with event: NSEvent) {
        hoveredIndex = itemIndex(at: event)
        onHover?(hoveredIndex.map { items[$0] })
    }

    override public func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        onHover?(nil)
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let item = itemIndex(at: event).map { items[$0] }
        if event.clickCount == 2, let item {
            onDoubleClick?(item)
        } else {
            onClick?(item)
        }
    }

    override public func menu(for event: NSEvent) -> NSMenu? {
        guard let index = itemIndex(at: event) else { return nil }
        onClick?(items[index])
        return onContextMenu?(items[index], event)
    }
}
