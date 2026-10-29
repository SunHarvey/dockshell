import CoreGraphics
import DockShellFeatures
import Foundation

private struct TerminalGridLayoutFailure: Error, CustomStringConvertible { let description: String }

/// Verifies exact one-row/one-column tiling without views, connections or credentials.
enum TerminalGridLayoutVerification {
    static func run() throws {
        let directions: [TerminalArrangement] = [.horizontal, .vertical]
        let rectangles = [CGRect(x: 0, y: 0, width: 1280, height: 720),
                          CGRect(x: 17, y: 31, width: 720, height: 1280),
                          CGRect(x: -10, y: -20, width: 720, height: 720),
                          CGRect(x: 30, y: 50, width: -900, height: -500),
                          CGRect(x: 0, y: 0, width: 0.01, height: 0.02)]
        for direction in directions {
            try check(TerminalGridLayout.frames(count: 0, in: .zero, arrangement: direction).isEmpty,
                      "A zero terminal count produced cells")
            try check(TerminalGridLayout.frames(count: -1, in: .zero, arrangement: direction).isEmpty,
                      "A negative terminal count produced cells")
            for rectangle in rectangles {
                for count in [1, 2, 3, 4, 5, 6, 7, 10, 100] {
                    for gap: CGFloat in [0, 6, 1_000_000] {
                        try verify(count: count, bounds: rectangle, arrangement: direction, gap: gap)
                    }
                }
            }
            for rectangle in [CGRect.zero, CGRect(x: 3, y: 7, width: 0, height: 400),
                              CGRect(x: 3, y: 7, width: CGFloat.infinity, height: 400),
                              CGRect(x: -CGFloat.greatestFiniteMagnitude, y: 7,
                                     width: -CGFloat.greatestFiniteMagnitude, height: 400)] {
                let frames = TerminalGridLayout.frames(count: 5, in: rectangle, arrangement: direction)
                try check(frames.count == 5 && frames.allSatisfy { $0.width == 0 && $0.height == 0
                    && $0.origin.x.isFinite && $0.origin.y.isFinite }, "Invalid bounds produced invalid linear cells")
            }
            let normal = CGRect(x: 0, y: 0, width: 900, height: 700)
            try check(TerminalGridLayout.frames(count: 5, in: normal, arrangement: direction, gap: -10)
                == TerminalGridLayout.frames(count: 5, in: normal, arrangement: direction, gap: 0),
                      "A negative gap was not sanitized")
            try verify(count: 1_000, bounds: normal, arrangement: direction, gap: 6)
        }

        // The reported three-terminal regression must be three complete columns
        // or three complete rows, never an automatic two-plus-one grid.
        let three = CGRect(x: 10, y: 20, width: 900, height: 600)
        let horizontal = TerminalGridLayout.frames(count: 3, in: three, arrangement: .horizontal, gap: 0)
        let vertical = TerminalGridLayout.frames(count: 3, in: three, arrangement: .vertical, gap: 0)
        try check(horizontal == [CGRect(x: 10, y: 20, width: 300, height: 600),
                                 CGRect(x: 310, y: 20, width: 300, height: 600),
                                 CGRect(x: 610, y: 20, width: 300, height: 600)],
                  "Three horizontal terminals were not three equal full-height columns")
        try check(vertical == [CGRect(x: 10, y: 20, width: 900, height: 200),
                               CGRect(x: 10, y: 220, width: 900, height: 200),
                               CGRect(x: 10, y: 420, width: 900, height: 200)],
                  "Three vertical terminals were not three equal full-width rows")
        try check(TerminalGridLayout.frames(count: 3, in: three, arrangement: .tabs)
            == Array(repeating: three, count: 3), "Tab mode changed the available terminal area")
        print("PASS terminal linear geometry: three equal columns or rows, one-axis order, full-span panels, adaptive gaps, invalid bounds and 1000 cells")
    }

    private static func verify(count: Int, bounds: CGRect, arrangement: TerminalArrangement, gap: CGFloat) throws {
        let area = bounds.standardized
        let frames = TerminalGridLayout.frames(count: count, in: bounds, arrangement: arrangement, gap: gap)
        try check(frames.count == count, "Linear frame count differs from the open terminal count")
        try check(frames == TerminalGridLayout.frames(count: count, in: bounds, arrangement: arrangement, gap: gap),
                  "Linear frame order is nondeterministic")
        let tolerance = max(area.width, area.height) * 1e-8 + 1e-10
        let allowed = area.insetBy(dx: -tolerance, dy: -tolerance)
        let horizontal = arrangement == .horizontal
        let firstExtent = horizontal ? frames[0].width : frames[0].height
        var totalArea: CGFloat = 0
        for (index, frame) in frames.enumerated() {
            try check(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width > 0
                && frame.height > 0 && allowed.contains(frame), "A linear cell escaped its bounds or became invalid")
            let extent = horizontal ? frame.width : frame.height
            try check(abs(extent - firstExtent) <= tolerance, "Linear terminal extents are not equal")
            if horizontal {
                try check(abs(frame.minY - area.minY) <= tolerance && abs(frame.height - area.height) <= tolerance,
                          "Horizontal tiling introduced a second row or partial-height panel")
            } else {
                try check(abs(frame.minX - area.minX) <= tolerance && abs(frame.width - area.width) <= tolerance,
                          "Vertical tiling introduced a second column or partial-width panel")
            }
            if index > 0 {
                let previous = frames[index - 1]
                try check(horizontal ? previous.maxX <= frame.minX + tolerance : previous.maxY <= frame.minY + tolerance,
                          "Linear cells overlapped or changed order")
            }
            totalArea += frame.width * frame.height
        }
        try check(horizontal
            ? abs(frames[0].minX - area.minX) <= tolerance && abs(frames[count - 1].maxX - area.maxX) <= tolerance
            : abs(frames[0].minY - area.minY) <= tolerance && abs(frames[count - 1].maxY - area.maxY) <= tolerance,
                  "Linear tiling did not reach both outer edges")
        if gap == 0 {
            try check(abs(totalArea - area.width * area.height) <= max(1, area.width * area.height) * 1e-8,
                      "Gap-free linear tiling did not use all available area")
        }
    }

    private static func check(_ value: Bool, _ description: String) throws {
        if !value { throw TerminalGridLayoutFailure(description: description) }
    }
}
