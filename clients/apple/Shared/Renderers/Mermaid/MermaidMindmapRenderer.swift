import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid mindmaps.
///
/// Draws a horizontal tree layout: root on the left, branches radiating right.
/// Each top-level branch gets a distinct color; children inherit at reduced opacity.
/// Uses the same `FlowchartLayout` container with `customDraw`/`customSize`.
enum MermaidMindmapRenderer {

    // MARK: - Branch palette

    /// Colors for top-level branches. Index wraps around for large trees.
    private static let branchColors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (0.30, 0.56, 0.88),  // blue
        (0.36, 0.72, 0.36),  // green
        (0.90, 0.58, 0.22),  // orange
        (0.62, 0.42, 0.82),  // purple
        (0.20, 0.72, 0.76),  // cyan
        (0.86, 0.36, 0.42),  // red
        (0.56, 0.70, 0.32),  // olive
        (0.78, 0.48, 0.64),  // pink
    ]

    private static func branchColor(index: Int, alpha: CGFloat = 1.0) -> CGColor {
        let c = branchColors[index % branchColors.count]
        return CGColor(red: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    // MARK: - Layout constants

    private struct LayoutConstants: Sendable {
        let fontSize: CGFloat
        let hPadding: CGFloat     // horizontal padding inside nodes
        let vPadding: CGFloat     // vertical padding inside nodes
        let hSpacing: CGFloat     // horizontal gap between parent and children
        let vSpacing: CGFloat     // vertical gap between sibling nodes
        let rootExtraPad: CGFloat // extra padding for the root node
        let margin: CGFloat       // outer margin around the whole diagram

        var font: CTFont { CTFontCreateWithName("Helvetica" as CFString, fontSize, nil) }

        init(fontSize: CGFloat) {
            self.fontSize = fontSize
            self.hPadding = fontSize * 1.2
            self.vPadding = fontSize * 0.6
            self.hSpacing = fontSize * 3.0
            self.vSpacing = fontSize * 0.8
            self.rootExtraPad = fontSize * 0.6
            self.margin = fontSize * 1.5
        }
    }

    // MARK: - Measured node (intermediate representation)

    /// A node with its measured size and children, ready for positioning.
    private struct MeasuredNode {
        let label: String
        let shape: MindmapNodeShape
        let nodeSize: CGSize          // size of this node box (text + padding)
        let subtreeHeight: CGFloat    // total height of this subtree
        let subtreeWidth: CGFloat     // total width of this subtree (node + children)
        let children: [MeasuredNode]
    }

    /// A positioned node ready for drawing.
    private struct PositionedNode {
        let label: String
        let shape: MindmapNodeShape
        let rect: CGRect
        let branchIndex: Int          // which top-level branch (for coloring)
        let depth: Int                // 0 = root, 1 = branch, 2+ = leaf
        let children: [PositionedNode]
    }

    // MARK: - Public entry point

    nonisolated static func layout(
        _ diagram: MindmapDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        let constants = LayoutConstants(fontSize: configuration.fontSize)
        let theme = configuration.theme

        // Measure all nodes recursively.
        let measured = measure(diagram.root, constants: constants)

        // Position: root on the left, children to the right.
        let totalWidth = measured.subtreeWidth + constants.margin * 2
        let totalHeight = measured.subtreeHeight + constants.margin * 2
        let rootX = constants.margin
        let rootY = constants.margin + (measured.subtreeHeight - measured.nodeSize.height) / 2

        let positioned = position(
            measured,
            x: rootX,
            y: rootY,
            subtreeTop: constants.margin,
            branchIndex: -1, // root has no branch
            depth: 0,
            constants: constants
        )

        let size = CGSize(width: totalWidth, height: max(totalHeight, measured.nodeSize.height + constants.margin * 2))

        let drawBlock: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            drawTree(positioned, parent: nil, in: ctx, at: origin, constants: constants, theme: theme)
        }

        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: GraphLayoutResult(nodePositions: [:], edgePaths: [], totalSize: .zero),
            flowchart: .empty,
            nodeLabels: [:],
            nodeShapes: [:],
            edgeLabels: [:],
            edgeStyles: [:],
            classDefs: [:],
            styleDirectives: [:],
            fontSize: configuration.fontSize,
            theme: theme,
            isPlaceholder: false,
            placeholderText: nil,
            customDraw: drawBlock,
            customSize: size
        )
    }

    // MARK: - Measure pass

    private static func measure(_ node: MindmapNode, constants: LayoutConstants) -> MeasuredNode {
        let textSize = measureText(node.label, font: constants.font, fontSize: constants.fontSize)
        let isRoot = true // caller doesn't know yet, but we add root extra pad at position time
        _ = isRoot

        let nodeWidth = textSize.width + constants.hPadding * 2
        let nodeHeight = textSize.height + constants.vPadding * 2

        let nodeSize = CGSize(width: nodeWidth, height: nodeHeight)

        let measuredChildren = node.children.map { measure($0, constants: constants) }

        if measuredChildren.isEmpty {
            return MeasuredNode(
                label: node.label,
                shape: node.shape,
                nodeSize: nodeSize,
                subtreeHeight: nodeSize.height,
                subtreeWidth: nodeSize.width,
                children: []
            )
        }

        // Subtree height = sum of children subtree heights + spacing between them.
        let childrenTotalHeight = measuredChildren.reduce(CGFloat(0)) { $0 + $1.subtreeHeight }
            + CGFloat(measuredChildren.count - 1) * constants.vSpacing

        let subtreeHeight = max(nodeSize.height, childrenTotalHeight)

        // Subtree width = this node + spacing + max child subtree width.
        let maxChildWidth = measuredChildren.map(\.subtreeWidth).max() ?? 0
        let subtreeWidth = nodeSize.width + constants.hSpacing + maxChildWidth

        return MeasuredNode(
            label: node.label,
            shape: node.shape,
            nodeSize: nodeSize,
            subtreeHeight: subtreeHeight,
            subtreeWidth: subtreeWidth,
            children: measuredChildren
        )
    }

    // MARK: - Position pass

    private static func position(
        _ node: MeasuredNode,
        x: CGFloat,
        y: CGFloat,
        subtreeTop: CGFloat,
        branchIndex: Int,
        depth: Int,
        constants: LayoutConstants
    ) -> PositionedNode {
        // Apply extra padding for root node.
        let actualSize: CGSize
        if depth == 0 {
            actualSize = CGSize(
                width: node.nodeSize.width + constants.rootExtraPad * 2,
                height: node.nodeSize.height + constants.rootExtraPad
            )
        } else {
            actualSize = node.nodeSize
        }

        let rect = CGRect(origin: CGPoint(x: x, y: y), size: actualSize)

        let childX = x + actualSize.width + constants.hSpacing

        var positionedChildren: [PositionedNode] = []
        var currentY = subtreeTop

        for (i, child) in node.children.enumerated() {
            // At depth 0, each child is a new branch with its own color index.
            let childBranch = (depth == 0) ? i : branchIndex

            let childCenterY = currentY + (child.subtreeHeight - child.nodeSize.height) / 2

            let positioned = position(
                child,
                x: childX,
                y: childCenterY,
                subtreeTop: currentY,
                branchIndex: childBranch,
                depth: depth + 1,
                constants: constants
            )
            positionedChildren.append(positioned)
            currentY += child.subtreeHeight + constants.vSpacing
        }

        return PositionedNode(
            label: node.label,
            shape: node.shape,
            rect: rect,
            branchIndex: branchIndex,
            depth: depth,
            children: positionedChildren
        )
    }

    // MARK: - Draw pass

    private static func drawTree(
        _ node: PositionedNode,
        parent: PositionedNode?,
        in ctx: CGContext,
        at origin: CGPoint,
        constants: LayoutConstants,
        theme: RenderTheme
    ) {
        let nodeRect = node.rect.offsetBy(dx: origin.x, dy: origin.y)

        // Draw connecting line from parent to this node.
        if let parent {
            let parentRect = parent.rect.offsetBy(dx: origin.x, dy: origin.y)
            drawConnection(from: parentRect, to: nodeRect, branchIndex: node.branchIndex, in: ctx)
        }

        // Draw node shape.
        drawNodeShape(node, rect: nodeRect, theme: theme, in: ctx, constants: constants)

        // Draw label.
        drawLabel(node.label, in: nodeRect, fontSize: constants.fontSize, font: constants.font, theme: theme, in: ctx)

        // Recurse into children.
        for child in node.children {
            drawTree(child, parent: node, in: ctx, at: origin, constants: constants, theme: theme)
        }
    }

    // MARK: - Connection drawing

    private static func drawConnection(
        from parentRect: CGRect,
        to childRect: CGRect,
        branchIndex: Int,
        in ctx: CGContext
    ) {
        let startX = parentRect.maxX
        let startY = parentRect.midY
        let endX = childRect.minX
        let endY = childRect.midY

        let controlOffset = (endX - startX) * 0.5

        ctx.saveGState()
        ctx.setStrokeColor(branchColor(index: max(0, branchIndex), alpha: 0.6))
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.round)

        ctx.move(to: CGPoint(x: startX, y: startY))
        ctx.addCurve(
            to: CGPoint(x: endX, y: endY),
            control1: CGPoint(x: startX + controlOffset, y: startY),
            control2: CGPoint(x: endX - controlOffset, y: endY)
        )
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Node shape drawing

    private static func drawNodeShape(
        _ node: PositionedNode,
        rect: CGRect,
        theme: RenderTheme,
        in ctx: CGContext,
        constants: LayoutConstants
    ) {
        ctx.saveGState()

        let fillColor: CGColor
        let strokeColor: CGColor

        if node.depth == 0 {
            // Root: use theme foreground tinted
            fillColor = CGColor(red: 0.25, green: 0.45, blue: 0.70, alpha: 1.0)
            strokeColor = CGColor(red: 0.30, green: 0.55, blue: 0.80, alpha: 1.0)
        } else {
            // Branch/leaf: use branch palette
            let alpha: CGFloat = node.depth == 1 ? 0.20 : 0.12
            fillColor = branchColor(index: max(0, node.branchIndex), alpha: alpha)
            strokeColor = branchColor(index: max(0, node.branchIndex), alpha: 0.7)
        }

        ctx.setFillColor(fillColor)
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(1.5)

        let path: CGPath
        let shape = node.depth == 0 ? .rounded : node.shape

        switch shape {
        case .default:
            let radius = min(rect.height * 0.3, 6)
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .square:
            path = CGPath(rect: rect, transform: nil)
        case .rounded:
            let radius = min(rect.height / 2, 12)
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .circle:
            let diameter = max(rect.width, rect.height)
            let circleRect = CGRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            path = CGPath(ellipseIn: circleRect, transform: nil)
        case .bang:
            path = cloudPath(rect)
        case .hexagon:
            path = hexagonPath(rect)
        }

        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    /// Cloud/bang shape — wavy rounded outline.
    private static func cloudPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let inset: CGFloat = 4
        let r = rect.insetBy(dx: inset, dy: inset)
        let bump: CGFloat = min(r.height * 0.15, 6)

        // Approximate cloud with arcs along the rectangle edges.
        let segments = 6
        let topY = r.minY
        let bottomY = r.maxY
        let leftX = r.minX
        let rightX = r.maxX

        path.move(to: CGPoint(x: leftX, y: r.midY))

        // Top edge — bumps going left to right
        let topStep = r.width / CGFloat(segments)
        for i in 0 ..< segments {
            let x1 = leftX + topStep * CGFloat(i)
            let x2 = leftX + topStep * CGFloat(i + 1)
            let midX = (x1 + x2) / 2
            path.addQuadCurve(to: CGPoint(x: x2, y: topY), control: CGPoint(x: midX, y: topY - bump))
        }

        // Right side
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: bottomY),
            control: CGPoint(x: rightX + bump, y: r.midY)
        )

        // Bottom edge — bumps going right to left
        for i in (0 ..< segments).reversed() {
            let x1 = leftX + topStep * CGFloat(i + 1)
            let x2 = leftX + topStep * CGFloat(i)
            let midX = (x1 + x2) / 2
            path.addQuadCurve(to: CGPoint(x: x2, y: bottomY), control: CGPoint(x: midX, y: bottomY + bump))
        }

        // Left side
        path.addQuadCurve(
            to: CGPoint(x: leftX, y: topY),
            control: CGPoint(x: leftX - bump, y: r.midY)
        )

        path.closeSubpath()
        return path
    }

    /// Hexagon shape.
    private static func hexagonPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let inset = rect.width * 0.15
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    // MARK: - Label drawing

    private static func drawLabel(
        _ text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        font: CTFont,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let textColor: CGColor = theme.foreground
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        let textX = rect.midX - bounds.width / 2
        let textY = rect.midY - bounds.height / 2

        drawCTLine(line, at: CGPoint(x: textX, y: textY), fontSize: fontSize, in: ctx)
    }

    // MARK: - Text helpers

    private static func measureText(_ text: String, font: CTFont, fontSize: CGFloat) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        return CGSize(
            width: max(bounds.width, fontSize * 2),
            height: max(bounds.height, fontSize * 1.4)
        )
    }

    /// Draw a CTLine at (x, y) in UIKit top-left (Y-down) coordinates.
    ///
    /// CTLineDraw uses CG coords (Y-up). This flips locally so text renders right-side-up.
    private static func drawCTLine(_ line: CTLine, at point: CGPoint, fontSize: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y + fontSize)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
