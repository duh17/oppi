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

    /// Theme-derived colors for top-level branches. Index wraps around for large trees.
    private static func branchPalette(theme: RenderTheme) -> [CGColor] {
        [
            theme.accentBlue,
            theme.accentGreen,
            theme.accentOrange,
            theme.accentPurple,
            theme.accentCyan,
            theme.accentRed,
            theme.accentYellow,
            theme.type,
        ]
    }

    private static func branchColor(index: Int, theme: RenderTheme, alpha: CGFloat = 1.0) -> CGColor {
        let colors = branchPalette(theme: theme)
        let base = colors[index % colors.count]
        return base.copy(alpha: alpha) ?? base
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

        var nodeWidth = textSize.width + constants.hPadding * 2
        var nodeHeight = textSize.height + constants.vPadding * 2

        // Circle shape uses max(w,h) as diameter at draw time — allocate that here
        // so the layout engine spaces siblings correctly.
        if node.shape == .circle {
            let diameter = max(nodeWidth, nodeHeight)
            nodeWidth = diameter
            nodeHeight = diameter
        }

        // Cloud (bang) shape has bumps that protrude beyond the rect — expand to fit.
        if node.shape == .bang {
            let bumpOverflow = min(nodeHeight * 0.22, 10.0) + 4
            nodeWidth += bumpOverflow * 2
            nodeHeight += bumpOverflow * 2
        }

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
            drawConnection(from: parentRect, to: nodeRect, branchIndex: node.branchIndex, theme: theme, in: ctx)
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
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let startX = parentRect.maxX
        let startY = parentRect.midY
        let endX = childRect.minX
        let endY = childRect.midY

        let controlOffset = (endX - startX) * 0.5

        ctx.saveGState()
        ctx.setStrokeColor(branchColor(index: max(0, branchIndex), theme: theme, alpha: 0.6))
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
            // Root: use the primary diagram accent, lightly tinted so theme foreground stays readable.
            fillColor = theme.accentBlue.copy(alpha: 0.22) ?? theme.accentBlue
            strokeColor = theme.accentBlue.copy(alpha: 0.78) ?? theme.accentBlue
        } else {
            // Branch/leaf: use the active theme palette rather than hardcoded RGB values.
            let alpha: CGFloat = node.depth == 1 ? 0.18 : 0.10
            fillColor = branchColor(index: max(0, node.branchIndex), theme: theme, alpha: alpha)
            strokeColor = branchColor(index: max(0, node.branchIndex), theme: theme, alpha: 0.72)
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

    /// Cloud/bang shape — rounded bumpy outline resembling a thought bubble.
    private static func cloudPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let r = rect.insetBy(dx: 2, dy: 2)
        let bump: CGFloat = min(r.height * 0.22, 10)

        // 4 bumps on top/bottom, curved sides — larger arcs for a rounder look.
        let topSegments = 4
        let bottomSegments = 4
        let topStep = r.width / CGFloat(topSegments)
        let bottomStep = r.width / CGFloat(bottomSegments)

        // Start at top-left
        path.move(to: CGPoint(x: r.minX, y: r.minY + bump))

        // Left side — single outward curve
        path.addQuadCurve(
            to: CGPoint(x: r.minX, y: r.maxY - bump),
            control: CGPoint(x: r.minX - bump, y: r.midY)
        )

        // Bottom edge — bumps going left to right
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        for i in 0 ..< bottomSegments {
            let x1 = r.minX + bottomStep * CGFloat(i)
            let x2 = r.minX + bottomStep * CGFloat(i + 1)
            let midX = (x1 + x2) / 2
            path.addQuadCurve(to: CGPoint(x: x2, y: r.maxY), control: CGPoint(x: midX, y: r.maxY + bump))
        }

        // Right side — single outward curve
        path.addQuadCurve(
            to: CGPoint(x: r.maxX, y: r.minY + bump),
            control: CGPoint(x: r.maxX + bump, y: r.midY)
        )

        // Top edge — bumps going right to left
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        for i in (0 ..< topSegments).reversed() {
            let x1 = r.minX + topStep * CGFloat(i + 1)
            let x2 = r.minX + topStep * CGFloat(i)
            let midX = (x1 + x2) / 2
            path.addQuadCurve(to: CGPoint(x: x2, y: r.minY), control: CGPoint(x: midX, y: r.minY - bump))
        }

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
        MermaidTextUtils.drawText(
            text,
            centeredIn: rect,
            font: font,
            fontSize: fontSize,
            foregroundColor: theme.foreground,
            in: ctx
        )
    }

    // MARK: - Text helpers

    private static func measureText(_ text: String, font: CTFont, fontSize: CGFloat) -> CGSize {
        MermaidTextUtils.measureText(text, font: font, fontSize: fontSize)
    }
}
