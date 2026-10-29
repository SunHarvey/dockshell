import CoreGraphics
import Foundation

/// Explicit presentation of the existing terminals. Horizontal means one row of
/// equal-width terminals; vertical means one column of equal-height terminals.
public enum TerminalArrangement: Equatable, Sendable {
    case tabs, horizontal, vertical
}

/// Linear tiling geometry for an existing ordered set of terminals.
///
/// The historical type name is retained for source-file continuity. No automatic
/// grid, shape scoring or mixed rows are produced: direction is always explicit.
public enum TerminalGridLayout {
    /// Returns exactly `count` ordered frames for positive counts in O(count) time.
    ///
    /// Horizontal frames span the entire height and equally divide the width;
    /// vertical frames span the entire width and equally divide the height.
    /// In tab presentation every frame equals the available area; the UI hides
    /// all but its selected terminal. Bounds are standardized and invalid bounds
    /// produce safe zero-size frames while preserving indices. Gaps shrink when
    /// necessary so panels retain at least three quarters of the divided axis.
    public static func frames(count: Int, in bounds: CGRect, arrangement: TerminalArrangement,
                              gap: CGFloat = 6) -> [CGRect] {
        guard count > 0 else { return [] }
        let origin = CGPoint(x: bounds.origin.x.isFinite ? bounds.origin.x : 0,
                             y: bounds.origin.y.isFinite ? bounds.origin.y : 0)
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite else {
            return Array(repeating: CGRect(origin: origin, size: .zero), count: count)
        }
        let area = bounds.standardized
        let safeOrigin = CGPoint(x: area.origin.x.isFinite ? area.origin.x : origin.x,
                                 y: area.origin.y.isFinite ? area.origin.y : origin.y)
        guard area.width > 0, area.height > 0, area.maxX.isFinite, area.maxY.isFinite else {
            return Array(repeating: CGRect(origin: safeOrigin, size: .zero), count: count)
        }
        guard arrangement != .tabs, count > 1 else { return Array(repeating: area, count: count) }
        let horizontal = arrangement == .horizontal
        let extent = horizontal ? area.width : area.height
        let requestedGap = gap.isFinite ? max(0, gap) : 0
        let spacing = min(requestedGap, extent / CGFloat(count - 1) / 4)
        let panelExtent = max(0, extent - spacing * CGFloat(count - 1)) / CGFloat(count)
        let start = horizontal ? area.minX : area.minY
        let end = horizontal ? area.maxX : area.maxY
        return (0..<count).map { index in
            let position = min(end, start + CGFloat(index) * (panelExtent + spacing))
            // Pin the final outer edge instead of accumulating a floating-point gap.
            let farEdge = index == count - 1 ? end : min(end, position + panelExtent)
            return horizontal
                ? CGRect(x: position, y: area.minY, width: max(0, farEdge - position), height: area.height)
                : CGRect(x: area.minX, y: position, width: area.width, height: max(0, farEdge - position))
        }
    }
}
