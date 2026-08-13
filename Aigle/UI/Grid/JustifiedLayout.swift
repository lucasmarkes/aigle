import CoreGraphics
import Foundation

/// One justified row: cells share a height and exactly fill the container width,
/// the way Eagle, Atlas and Google Photos lay images out.
public struct GridRowLayout: Identifiable, Hashable, Sendable {
    public let id: String
    public let y: CGFloat
    public let height: CGFloat
    public let cells: [GridCellLayout]
}

public struct GridCellLayout: Identifiable, Hashable, Sendable {
    public let id: String
    public let width: CGFloat
    public let x: CGFloat
}

public struct JustifiedLayout: Sendable {
    public var rows: [GridRowLayout]
    public var contentHeight: CGFloat
    /// Item id → frame in content coordinates. Powers rubber-band selection.
    public var frames: [String: CGRect]

    public static let empty = JustifiedLayout(rows: [], contentHeight: 0, frames: [:])
}

public enum JustifiedLayoutEngine {
    /// - Parameters:
    ///   - targetHeight: the zoom level, expressed as an ideal row height.
    public static func compute(
        items: [Item],
        width: CGFloat,
        targetHeight: CGFloat,
        spacing: CGFloat
    ) -> JustifiedLayout {
        guard width > 1, targetHeight > 1, !items.isEmpty else { return .empty }

        var rows: [GridRowLayout] = []
        var frames: [String: CGRect] = [:]
        frames.reserveCapacity(items.count)

        var current: [Item] = []
        var currentAspectSum: CGFloat = 0
        var y: CGFloat = 0

        func flush(justify: Bool) {
            guard !current.isEmpty else { return }
            let gaps = spacing * CGFloat(current.count - 1)
            let available = width - gaps
            let rowHeight: CGFloat
            if justify {
                rowHeight = max(24, min(available / max(currentAspectSum, 0.01), targetHeight * 2.4))
            } else {
                rowHeight = targetHeight
            }

            var x: CGFloat = 0
            var cells: [GridCellLayout] = []
            cells.reserveCapacity(current.count)
            for (index, item) in current.enumerated() {
                var cellWidth = (clampedAspect(item) * rowHeight).rounded()
                if justify, index == current.count - 1 {
                    // Absorb rounding drift into the last cell so rows end flush.
                    cellWidth = max(24, width - x)
                }
                cells.append(GridCellLayout(id: item.id, width: cellWidth, x: x))
                frames[item.id] = CGRect(x: x, y: y, width: cellWidth, height: rowHeight)
                x += cellWidth + spacing
            }
            rows.append(GridRowLayout(id: current[0].id, y: y, height: rowHeight, cells: cells))
            y += rowHeight + spacing
            current.removeAll(keepingCapacity: true)
            currentAspectSum = 0
        }

        for item in items {
            let aspect = clampedAspect(item)
            let projectedWidth = (currentAspectSum + aspect) * targetHeight + spacing * CGFloat(current.count)
            current.append(item)
            currentAspectSum += aspect
            if projectedWidth >= width {
                flush(justify: true)
            }
        }
        // The trailing partial row keeps the target height rather than stretching.
        flush(justify: false)

        return JustifiedLayout(rows: rows, contentHeight: max(0, y - spacing), frames: frames)
    }

    /// Extreme panoramas and hairline strips would otherwise wreck a row.
    static func clampedAspect(_ item: Item) -> CGFloat {
        let aspect = item.aspectRatio
        guard aspect.isFinite, aspect > 0 else { return 1 }
        return min(max(aspect, 0.28), 4.0)
    }
}
