import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Internal drag payload: which items are moving.
    public static let aigleItems = UTType(exportedAs: "cool.aigle.items")
    /// Internal drag payload: a collection being re-parented or reordered.
    public static let aigleCollection = UTType(exportedAs: "cool.aigle.collection")
}

/// The justified thumbnail grid: zoomable, pannable, selectable, droppable.
struct GridView: View {
    let namespace: Namespace.ID

    @Environment(LibraryController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(CommandBus.self) private var bus

    @State private var bridge = ScrollBridge()
    @State private var containerWidth: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var pinchStartZoom: Double?
    @State private var isDropTargeted = false
    @State private var marquee: MarqueeState?
    @State private var spaceHeld = false
    @FocusState private var isGridFocused: Bool

    private var items: [Item] { controller.visibleItems }

    private var layout: JustifiedLayout {
        JustifiedLayoutEngine.compute(
            items: items,
            width: max(0, containerWidth - 2 * horizontalInset),
            targetHeight: controller.zoom,
            spacing: settings.gridSpacing
        )
    }

    private let horizontalInset: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let layout = layout
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: settings.gridSpacing) {
                        ForEach(layout.rows) { row in
                            rowView(row)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 16)

                    if let marquee {
                        MarqueeRectangle(rect: marquee.rect, tint: settings.selectionTint.color)
                            .offset(x: horizontalInset, y: 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(ScrollViewFinder(bridge: bridge))
                .background(marqueeCatcher(layout: layout))
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(backgroundStyle)
            .onAppear {
                containerWidth = proxy.size.width
                viewportHeight = proxy.size.height
            }
            .onChange(of: proxy.size) { _, newValue in
                containerWidth = newValue.width
                viewportHeight = newValue.height
            }
            .overlay(alignment: .center) { emptyState }
            .overlay(alignment: .bottomTrailing) { ZoomSlider() }
            .overlay { dropHighlight }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isGridFocused)
        .onAppear { isGridFocused = true }
        .gesture(pinch)
        .gridEventMonitors(eventHandlers)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            handleArrow(press)
        }
        .onKeyPress(.return) {
            if let id = controller.focusedItemID ?? controller.selectedItemIDs.first {
                controller.openDetail(id)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            controller.selectedItemIDs.removeAll()
            return .handled
        }
        .onKeyPress(.delete) {
            deleteSelection()
            return .handled
        }
        .onKeyPress(.deleteForward) {
            deleteSelection()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "aA"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            controller.selectedItemIDs = Set(items.map(\.id))
            return .handled
        }
        .onDrop(of: DropImporter.acceptedTypes + [.aigleItems], isTargeted: $isDropTargeted) { providers in
            handleExternalDrop(providers)
        }
        .onChange(of: bus.zoomInTicks) { _, _ in adjustZoom(by: 1.18) }
        .onChange(of: bus.zoomOutTicks) { _, _ in adjustZoom(by: 1 / 1.18) }
        .onChange(of: bus.toggleQuickLookTicks) { _, _ in openHoveredOrSelected() }
        .task(id: controller.sortKey) { await controller.loadGlobalOrderIfNeeded() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: GridRowLayout) -> some View {
        HStack(spacing: settings.gridSpacing) {
            ForEach(row.cells) { cell in
                if let item = controller.item(cell.id) {
                    cellView(item: item, size: CGSize(width: cell.width, height: row.height))
                } else {
                    Color.clear.frame(width: cell.width, height: row.height)
                }
            }
        }
        .frame(height: row.height, alignment: .leading)
    }

    @ViewBuilder
    private func cellView(item: Item, size: CGSize) -> some View {
        GridCell(
            item: item,
            size: size,
            isSelected: controller.selectedItemIDs.contains(item.id),
            isFocused: controller.focusedItemID == item.id,
            namespace: namespace,
            isDetailSource: controller.detailItemID == item.id
        )
        .onTapGesture(count: 2) { controller.openDetail(item.id) }
        .simultaneousGesture(TapGesture(count: 1).onEnded { handleClick(item) })
        .contextMenu { ItemContextMenu(item: item) }
        .onDrag { dragProvider(for: item) }
        .onDrop(of: [.aigleItems], isTargeted: nil) { providers in
            handleReorderDrop(providers, before: item)
        }
    }

    // MARK: - Background & chrome

    @ViewBuilder
    private var backgroundStyle: some View {
        if let custom = settings.resolvedBackground {
            custom.ignoresSafeArea()
        } else {
            Color(nsColor: .textBackgroundColor).opacity(0.35).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(settings.selectionTint.color, lineWidth: 3)
                .padding(6)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if items.isEmpty && !controller.isImporting {
            GridEmptyState(selection: controller.selection, hasSearch: !controller.searchText.isEmpty)
        }
    }

    // MARK: - Zoom

    private var pinch: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchStartZoom == nil { pinchStartZoom = controller.zoom }
                guard let start = pinchStartZoom else { return }
                controller.zoom = clampZoom(start * value.magnification)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    private func clampZoom(_ value: Double) -> Double {
        min(max(value, 80), 720)
    }

    private func adjustZoom(by factor: Double) {
        let old = layout.contentHeight
        withAnimation(settings.motionReduced ? nil : .snappy(duration: 0.22)) {
            controller.zoom = clampZoom(controller.zoom * factor)
        }
        preserveAnchor(oldHeight: old)
    }

    private func preserveAnchor(oldHeight: CGFloat) {
        let anchor = viewportHeight / 2
        DispatchQueue.main.async {
            bridge.preserveAnchor(
                anchorY: anchor,
                oldContentHeight: oldHeight,
                newContentHeight: layout.contentHeight
            )
        }
    }

    private var eventHandlers: GridEventHandlers {
        GridEventHandlers(
            onCommandScroll: { delta, _ in
                let old = layout.contentHeight
                controller.zoom = clampZoom(controller.zoom * (1 + delta * 0.004))
                preserveAnchor(oldHeight: old)
            },
            onPan: { delta in bridge.scroll(by: delta) },
            onSpaceKey: { openHoveredOrSelected() },
            spaceHeldChanged: { spaceHeld = $0 }
        )
    }

    // MARK: - Selection

    private func handleClick(_ item: Item) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) {
            controller.toggleLike(ids: [item.id])
            return
        }
        if flags.contains(.command) {
            if controller.selectedItemIDs.contains(item.id) {
                controller.selectedItemIDs.remove(item.id)
            } else {
                controller.selectedItemIDs.insert(item.id)
            }
        } else if flags.contains(.shift), let anchor = controller.focusedItemID,
                  let start = items.firstIndex(where: { $0.id == anchor }),
                  let end = items.firstIndex(where: { $0.id == item.id }) {
            let range = start <= end ? start...end : end...start
            controller.selectedItemIDs.formUnion(items[range].map(\.id))
        } else {
            controller.selectedItemIDs = [item.id]
        }
        controller.focusedItemID = item.id
        isGridFocused = true
    }

    private func deleteSelection() {
        guard !controller.selectedItemIDs.isEmpty else { return }
        if case .smart(.trash) = controller.selection {
            controller.restore(ids: controller.selectedItemIDs)
        } else {
            controller.moveToTrash(ids: controller.selectedItemIDs)
        }
    }

    private func openHoveredOrSelected() {
        if controller.isDetailPresented {
            controller.closeDetail()
            return
        }
        if let hovered = controller.hoveredItemID {
            controller.openDetail(hovered)
        } else if let id = controller.focusedItemID ?? controller.selectedItemIDs.first {
            controller.openDetail(id)
        }
    }

    // MARK: - Keyboard navigation

    private func handleArrow(_ press: KeyPress) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let frames = layout.frames
        let currentID = controller.focusedItemID ?? controller.selectedItemIDs.first ?? items[0].id
        guard let currentIndex = items.firstIndex(where: { $0.id == currentID }) else { return .ignored }

        var targetID: String?
        switch press.key {
        case .leftArrow:
            targetID = currentIndex > 0 ? items[currentIndex - 1].id : nil
        case .rightArrow:
            targetID = currentIndex + 1 < items.count ? items[currentIndex + 1].id : nil
        case .upArrow, .downArrow:
            targetID = verticalNeighbour(
                from: currentID,
                frames: frames,
                down: press.key == .downArrow
            )
        default:
            return .ignored
        }

        guard let targetID else { return .handled }
        if press.modifiers.contains(.shift) {
            controller.selectedItemIDs.insert(targetID)
        } else {
            controller.selectedItemIDs = [targetID]
        }
        controller.focusedItemID = targetID
        scrollToVisible(targetID, frames: frames)
        return .handled
    }

    private func verticalNeighbour(from id: String, frames: [String: CGRect], down: Bool) -> String? {
        guard let current = frames[id] else { return nil }
        let rows = layout.rows
        guard let rowIndex = rows.firstIndex(where: { row in row.cells.contains(where: { $0.id == id }) })
        else { return nil }
        let targetIndex = down ? rowIndex + 1 : rowIndex - 1
        guard rows.indices.contains(targetIndex) else { return nil }
        let currentCentre = current.midX
        return rows[targetIndex].cells.min(by: { lhs, rhs in
            abs(lhs.x + lhs.width / 2 - currentCentre) < abs(rhs.x + rhs.width / 2 - currentCentre)
        })?.id
    }

    private func scrollToVisible(_ id: String, frames: [String: CGRect]) {
        guard let frame = frames[id] else { return }
        let visible = bridge.visibleRect
        let top = frame.minY + 16
        let bottom = frame.maxY + 16
        if top < visible.minY {
            bridge.scroll(toY: max(0, top - 12))
        } else if bottom > visible.maxY {
            bridge.scroll(toY: bottom - visible.height + 12)
        }
    }

    // MARK: - Marquee (rubber-band) selection

    private struct MarqueeState {
        var start: CGPoint
        var current: CGPoint
        var additive: Bool
        var rect: CGRect {
            CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(start.x - current.x),
                height: abs(start.y - current.y)
            )
        }
    }

    @ViewBuilder
    private func marqueeCatcher(layout: JustifiedLayout) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { value in
                        guard !spaceHeld else { return }
                        let origin = CGPoint(x: value.startLocation.x - horizontalInset, y: value.startLocation.y - 16)
                        let current = CGPoint(x: value.location.x - horizontalInset, y: value.location.y - 16)
                        if marquee == nil {
                            marquee = MarqueeState(
                                start: origin,
                                current: current,
                                additive: NSEvent.modifierFlags.contains(.shift)
                            )
                        } else {
                            marquee?.current = current
                        }
                        applyMarquee(layout: layout)
                    }
                    .onEnded { _ in marquee = nil }
            )
    }

    private func applyMarquee(layout: JustifiedLayout) {
        guard let marquee else { return }
        let rect = marquee.rect
        let hits = layout.frames.filter { $0.value.intersects(rect) }.keys
        controller.selectedItemIDs = marquee.additive
            ? controller.selectedItemIDs.union(hits)
            : Set(hits)
    }

    // MARK: - Drag & drop

    private func dragProvider(for item: Item) -> NSItemProvider {
        let ids = controller.selectedItemIDs.contains(item.id)
            ? Array(controller.selectedItemIDs)
            : [item.id]
        controller.draggingItemIDs = Set(ids)

        let provider: NSItemProvider
        if let url = controller.fileURL(for: item), FileManager.default.fileExists(atPath: url.path) {
            provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        } else {
            provider = NSItemProvider()
        }
        let payload = Data(ids.joined(separator: "\n").utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.aigleItems.identifier, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    private func handleExternalDrop(_ providers: [NSItemProvider]) -> Bool {
        // Internal reorder drops are handled by the per-cell destination.
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.aigleItems.identifier) }) {
            return false
        }
        return DropImporter.handleDrop(
            providers: providers,
            into: controller.selection.collectionID,
            controller: controller
        )
    }

    private func handleReorderDrop(_ providers: [NSItemProvider], before target: Item) -> Bool {
        guard controller.currentSortOrder.field == .custom else { return false }
        let moving = controller.draggingItemIDs
        guard !moving.isEmpty, !moving.contains(target.id) else { return false }
        _ = providers
        var order = items.map(\.id)
        order.removeAll(where: moving.contains)
        guard let insertAt = order.firstIndex(of: target.id) else { return false }
        order.insert(contentsOf: items.map(\.id).filter(moving.contains), at: insertAt)
        Task { await controller.setCustomOrder(order) }
        return true
    }
}

private struct MarqueeRectangle: View {
    let rect: CGRect
    let tint: Color

    var body: some View {
        Rectangle()
            .fill(tint.opacity(0.16))
            .overlay { Rectangle().strokeBorder(tint.opacity(0.8), lineWidth: 1) }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}

private struct GridEmptyState: View {
    let selection: SidebarSelection
    let hasSearch: Bool

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .allowsHitTesting(false)
    }

    private var title: LocalizedStringKey {
        if hasSearch { return "No matches" }
        switch selection {
        case .smart(.trash): return "Trash is empty"
        case .smart(.likes): return "Nothing liked yet"
        case .smart(.inbox): return "Inbox is empty"
        default: return "Nothing here yet"
        }
    }

    private var message: LocalizedStringKey {
        if hasSearch { return "Try a different name or tag." }
        switch selection {
        case .smart(.trash): return "Deleted items appear here until you empty the trash."
        case .smart(.likes): return "Option-click a thumbnail to like it."
        default: return "Drag images, videos, PDFs or links here to add them."
        }
    }

    private var symbol: String {
        if hasSearch { return "magnifyingglass" }
        switch selection {
        case .smart(.trash): return "trash"
        case .smart(.likes): return "heart"
        default: return "square.grid.2x2"
        }
    }
}

/// Bottom-right zoom slider, the mouse-friendly counterpart to pinch.
private struct ZoomSlider: View {
    @Environment(LibraryController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: $controller.zoom, in: 80...720)
                .frame(width: 110)
                .controlSize(.mini)
            Image(systemName: "photo")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.separator.opacity(0.5)) }
        .padding(12)
        .accessibilityLabel("Thumbnail size")
    }
}
