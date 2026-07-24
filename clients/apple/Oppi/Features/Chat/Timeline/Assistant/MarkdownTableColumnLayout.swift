import UIKit

/// Pure layout policy for assistant markdown tables.
///
/// Prefer fitting narrow tables (especially 2–3 columns) into the available
/// bubble width by wrapping cell text. Fall back to single-line + horizontal
/// scroll when a table is too wide to wrap usefully.
enum MarkdownTableColumnLayout {
    /// Wrap when the table has at most this many columns.
    static let maxWrapColumnCount = 3

    /// Floor for a wrapped column so labels remain readable.
    static let minimumWrappedColumnWidth: CGFloat = 56

    /// Horizontal padding inside the table card around cell content.
    static let horizontalContentInset: CGFloat = 8

    /// Gap between columns in wrap mode (includes room for a thin divider).
    static let columnSpacing: CGFloat = 8

    static func contentBudget(forAvailableWidth availableWidth: CGFloat, columnCount: Int) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        let spacing = columnSpacing * CGFloat(max(0, columnCount - 1))
        return max(0, availableWidth - (horizontalContentInset * 2) - spacing)
    }

    /// - Parameter naturalContentWidth: full single-line table width including
    ///   clip-mode padding/separators (not bare text widths only).
    static func shouldWrap(
        columnCount: Int,
        naturalContentWidth: CGFloat,
        availableWidth: CGFloat
    ) -> Bool {
        guard columnCount > 0, availableWidth > 0 else { return false }
        guard columnCount <= maxWrapColumnCount else { return false }
        let budget = contentBudget(forAvailableWidth: availableWidth, columnCount: columnCount)
        guard budget > 0 else { return false }
        // Compare the full single-line width against the available card width so
        // separator/padding chrome alone can trigger wrap. Leave a little slack
        // so borderline tables stay single-line.
        return naturalContentWidth > availableWidth + 0.5
    }

    /// Distribute `availableContentWidth` across columns.
    ///
    /// Starts from natural single-line widths, then shrinks proportionally
    /// while respecting `minimumWrappedColumnWidth` when possible.
    static func allocateColumnWidths(
        naturalWidths: [CGFloat],
        availableContentWidth: CGFloat
    ) -> [CGFloat] {
        let count = naturalWidths.count
        guard count > 0 else { return [] }

        let clampedNatural = naturalWidths.map { max(1, ceil($0)) }
        let naturalSum = clampedNatural.reduce(0, +)
        let budget = max(0, floor(availableContentWidth))
        if naturalSum <= budget || budget <= 0 {
            return clampedNatural
        }

        let minWidth = minimumWrappedColumnWidth
        let minTotal = minWidth * CGFloat(count)
        if budget <= minTotal {
            // Not enough room for every minimum — split evenly.
            let even = floor(budget / CGFloat(count))
            var widths = Array(repeating: max(1, even), count: count)
            let remainder = Int(budget - widths.reduce(0, +))
            if remainder > 0 {
                for index in 0..<remainder {
                    widths[index] += 1
                }
            }
            return widths
        }

        // First pass: proportional scale.
        var widths = clampedNatural.map { width in
            max(minWidth, floor(width * budget / naturalSum))
        }

        // Fix rounding drift so the sum matches the budget as closely as possible.
        var sum = widths.reduce(0, +)
        if sum > budget {
            // Shrink the widest columns first, but not below the minimum.
            while sum > budget {
                guard let index = widths.enumerated()
                    .filter({ $0.element > minWidth })
                    .max(by: { $0.element < $1.element })?
                    .offset
                else { break }
                widths[index] -= 1
                sum -= 1
            }
        } else if sum < budget {
            while sum < budget {
                guard let index = widths.enumerated()
                    .max(by: { $0.element < $1.element })?
                    .offset
                else { break }
                widths[index] += 1
                sum += 1
            }
        }

        return widths
    }
}
