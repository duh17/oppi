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
        let outlineIndent: CGFloat // outline fallback: indent per depth
        let outlineRowGap: CGFloat // outline fallback: gap between rows

        var font: CTFont { CTFontCreateWithName("Helvetica" as CFString, fontSize, nil) }

        init(fontSize: CGFloat) {
            self.fontSize = fontSize
            self.hPadding = fontSize * 1.2
            self.vPadding = fontSize * 0.6
            self.hSpacing = fontSize * 3.0
            self.vSpacing = fontSize * 0.8
            self.rootExtraPad = fontSize * 0.6
            self.margin = fontSize * 1.5
            self.outlineIndent = fontSize * 1.6
            self.outlineRowGap = fontSize * 0.5
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
        let children: [Self]
    }

    /// A positioned node ready for drawing.
    private struct PositionedNode {
        let label: String
        let shape: MindmapNodeShape
        let rect: CGRect
        let branchIndex: Int          // which top-level branch (for coloring)
        let depth: Int                // 0 = root, 1 = branch, 2+ = leaf
        let children: [Self]
    }

    private enum RenderLayout {
        case horizontal
        case tidyTree
        /// Indented outline: each node under its parent, one indent to the
        /// right, joined by elbow connectors from a trunk below the parent.
        case outline
    }

    private struct PreparedLayout {
        let positioned: PositionedNode
        let size: CGSize
        let renderLayout: RenderLayout
    }

    // MARK: - Public entry point

    nonisolated static func layout(
        _ diagram: MindmapDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        let constants = LayoutConstants(fontSize: configuration.fontSize)
        let theme = configuration.theme

        var layoutResult: PreparedLayout
        switch diagram.layout {
        case .default:
            layoutResult = horizontalLayout(for: diagram.root, constants: constants)
        case .tidyTree:
            layoutResult = tidyTreeLayout(for: diagram.root, constants: constants)
        }
        // A branching layout wider than the view may fall back to the
        // outline, which grows down instead of across and wraps labels to the
        // width. It is used only when it shows larger on screen: a tall
        // outline the inline height cap would shrink more keeps the branches.
        var choice = RenderFitChoice(natural: layoutResult, size: layoutResult.size, configuration: configuration)
        if choice.canImprove(minimumWidth: 0) {
            let outline = outlineLayout(for: diagram.root, constants: constants, maxWidth: configuration.maxWidth)
            choice.consider(outline, size: outline.size)
            layoutResult = choice.best
        }

        let positioned = layoutResult.positioned
        let size = layoutResult.size
        let renderLayout = layoutResult.renderLayout

        let drawBlock: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            drawTree(
                positioned,
                in: ctx,
                at: origin,
                constants: constants,
                font: constants.font,
                theme: theme,
                layout: renderLayout
            )
        }
        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: GraphLayoutResult(nodePositions: [:], edgePaths: [], totalSize: .zero),
            flowchart: .empty,
            subgraphFrames: [:],
            nodeLabels: [:],
            nodeShapes: [:],
            edgeLabels: [:],
            edgeStyles: [:],
            edgeIds: [:],
            edgeKeys: [],
            edgeStyleDirectives: [:],
            edgeEndpointSubgraphs: [:],
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

    // MARK: - Layout passes

    private static func horizontalLayout(
        for root: MindmapNode,
        constants: LayoutConstants
    ) -> PreparedLayout {
        let measured = measure(root, constants: constants)
        let totalWidth = measured.subtreeWidth + constants.margin * 2
        let totalHeight = measured.subtreeHeight + constants.margin * 2
        let rootX = constants.margin
        let rootY = constants.margin + (measured.subtreeHeight - measured.nodeSize.height) / 2
        let positioned = position(
            measured,
            x: rootX,
            y: rootY,
            subtreeTop: constants.margin,
            branchIndex: -1,
            depth: 0,
            constants: constants
        )
        let size = CGSize(
            width: totalWidth,
            height: max(totalHeight, measured.nodeSize.height + constants.margin * 2)
        )
        return PreparedLayout(positioned: positioned, size: size, renderLayout: .horizontal)
    }

    private static func tidyTreeLayout(
        for root: MindmapNode,
        constants: LayoutConstants
    ) -> PreparedLayout {
        let measured = measureTidy(root, constants: constants)
        let positioned = positionTidy(
            measured,
            subtreeLeft: constants.margin,
            y: constants.margin,
            branchIndex: -1,
            depth: 0,
            constants: constants
        )
        let size = CGSize(
            width: measured.subtreeWidth + constants.margin * 2,
            height: measured.subtreeHeight + constants.margin * 2
        )
        return PreparedLayout(positioned: positioned, size: size, renderLayout: .tidyTree)
    }

    /// Outline fallback: one node per row, indented by depth. Labels wrap to
    /// the width left after the indent so the outline fits `maxWidth`
    /// unless a single word is wider.
    private static func outlineLayout(
        for root: MindmapNode,
        constants: LayoutConstants,
        maxWidth: CGFloat
    ) -> PreparedLayout {
        let font = constants.font
        let indent = constants.outlineIndent
        var y = constants.margin
        var maxX: CGFloat = 0

        func place(_ node: MindmapNode, depth: Int, branchIndex: Int) -> PositionedNode {
            let x = constants.margin + CGFloat(depth) * indent
            let rootPad = depth == 0 ? constants.rootExtraPad * 2 : 0
            let room = maxWidth - constants.margin - x - constants.hPadding * 2 - rootPad
            let label = MermaidTextUtils.wrapText(
                node.label,
                maxWidth: max(room, MermaidTextUtils.widestWord(node.label, font: font, fontSize: constants.fontSize)),
                font: font,
                fontSize: constants.fontSize
            )
            // The root always draws as a rounded box, so it is not sized as
            // a circle here; a square would waste a tall first row.
            let shape = depth == 0 ? .rounded : node.shape
            var size = nodeSize(label, shape: shape, font: font, constants: constants)
            if depth == 0 {
                size.width += rootPad
                size.height += constants.rootExtraPad
            }
            let rect = CGRect(x: x, y: y, width: size.width, height: size.height)
            maxX = max(maxX, rect.maxX)
            y = rect.maxY + constants.outlineRowGap
            let children = node.children.enumerated().map { index, child in
                place(child, depth: depth + 1, branchIndex: depth == 0 ? index : branchIndex)
            }
            return PositionedNode(
                label: label,
                shape: node.shape,
                rect: rect,
                branchIndex: branchIndex,
                depth: depth,
                children: children
            )
        }

        let positioned = place(root, depth: 0, branchIndex: -1)
        let size = CGSize(
            width: maxX + constants.margin,
            height: y - constants.outlineRowGap + constants.margin
        )
        return PreparedLayout(positioned: positioned, size: size, renderLayout: .outline)
    }

    // MARK: - Measure pass

    /// Box for a node label (text + padding), before the root's extra pad.
    private static func nodeSize(
        _ label: String,
        shape: MindmapNodeShape,
        font: CTFont,
        constants: LayoutConstants
    ) -> CGSize {
        let textSize = measureText(label, font: font, fontSize: constants.fontSize)
        var nodeWidth = textSize.width + constants.hPadding * 2
        var nodeHeight = textSize.height + constants.vPadding * 2

        // Circle shape uses max(w,h) as diameter at draw time — allocate that here
        // so the layout engine spaces siblings correctly.
        if shape == .circle {
            let diameter = max(nodeWidth, nodeHeight)
            nodeWidth = diameter
            nodeHeight = diameter
        }

        // Cloud shape has bumps that protrude beyond the rect — expand to fit.
        if shape == .cloud {
            let bumpOverflow = min(nodeHeight * 0.22, 10.0) + 4
            nodeWidth += bumpOverflow * 2
            nodeHeight += bumpOverflow * 2
        }
        return CGSize(width: nodeWidth, height: nodeHeight)
    }

    private static func measure(_ node: MindmapNode, constants: LayoutConstants) -> MeasuredNode {
        let nodeSize = nodeSize(node.label, shape: node.shape, font: constants.font, constants: constants)

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

    private static func measureTidy(_ node: MindmapNode, constants: LayoutConstants) -> MeasuredNode {
        let nodeSize = nodeSize(node.label, shape: node.shape, font: constants.font, constants: constants)
        let measuredChildren = node.children.map { measureTidy($0, constants: constants) }

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

        let childrenTotalWidth = measuredChildren.reduce(CGFloat(0)) { $0 + $1.subtreeWidth }
            + CGFloat(measuredChildren.count - 1) * constants.hSpacing
        let maxChildHeight = measuredChildren.map(\.subtreeHeight).max() ?? 0
        return MeasuredNode(
            label: node.label,
            shape: node.shape,
            nodeSize: nodeSize,
            subtreeHeight: nodeSize.height + constants.vSpacing * 2 + maxChildHeight,
            subtreeWidth: max(nodeSize.width, childrenTotalWidth),
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

    private static func positionTidy(
        _ node: MeasuredNode,
        subtreeLeft: CGFloat,
        y: CGFloat,
        branchIndex: Int,
        depth: Int,
        constants: LayoutConstants
    ) -> PositionedNode {
        let actualSize: CGSize
        if depth == 0 {
            actualSize = CGSize(
                width: node.nodeSize.width + constants.rootExtraPad * 2,
                height: node.nodeSize.height + constants.rootExtraPad
            )
        } else {
            actualSize = node.nodeSize
        }

        let x = subtreeLeft + (node.subtreeWidth - actualSize.width) / 2
        let rect = CGRect(origin: CGPoint(x: x, y: y), size: actualSize)
        let childY = y + actualSize.height + constants.vSpacing * 2
        var childLeft = subtreeLeft

        let positionedChildren = node.children.enumerated().map { index, child in
            let childBranch = depth == 0 ? index : branchIndex
            defer { childLeft += child.subtreeWidth + constants.hSpacing }
            return positionTidy(
                child,
                subtreeLeft: childLeft,
                y: childY,
                branchIndex: childBranch,
                depth: depth + 1,
                constants: constants
            )
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

    /// Draws a node, then its connectors, then its children, so every
    /// connector sits above its parent and below its child.
    private static func drawTree(
        _ node: PositionedNode,
        in ctx: CGContext,
        at origin: CGPoint,
        constants: LayoutConstants,
        font: CTFont,
        theme: RenderTheme,
        layout: RenderLayout
    ) {
        let nodeRect = node.rect.offsetBy(dx: origin.x, dy: origin.y)
        drawNodeShape(node, rect: nodeRect, theme: theme, in: ctx, constants: constants)
        drawLabel(node.label, in: nodeRect, fontSize: constants.fontSize, font: font, theme: theme, in: ctx)

        switch layout {
        case .horizontal, .tidyTree:
            for child in node.children {
                drawConnection(
                    from: nodeRect,
                    to: child.rect.offsetBy(dx: origin.x, dy: origin.y),
                    branchIndex: child.branchIndex,
                    theme: theme,
                    horizontal: layout == .horizontal,
                    in: ctx
                )
            }
        case .outline:
            drawOutlineConnectors(node, origin: origin, constants: constants, theme: theme, in: ctx)
        }

        for child in node.children {
            drawTree(child, in: ctx, at: origin, constants: constants, font: font, theme: theme, layout: layout)
        }
    }

    // MARK: - Connection drawing

    /// Outline connectors: a trunk down from the parent with a rounded
    /// elbow into each child. Each child's piece starts where the previous
    /// one turned, so pieces in different branch colors never overlap.
    private static func drawOutlineConnectors(
        _ node: PositionedNode,
        origin: CGPoint,
        constants: LayoutConstants,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        guard !node.children.isEmpty else { return }
        let parentRect = node.rect.offsetBy(dx: origin.x, dy: origin.y)
        let trunkX = parentRect.minX + min(constants.outlineIndent / 2, parentRect.width / 2)
        var startY = parentRect.maxY
        ctx.saveGState()
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.butt)
        for child in node.children {
            let childRect = child.rect.offsetBy(dx: origin.x, dy: origin.y)
            let radius = min(constants.outlineIndent / 4, max(childRect.midY - startY, 0))
            ctx.setStrokeColor(branchColor(index: max(0, child.branchIndex), theme: theme, alpha: 0.6))
            ctx.move(to: CGPoint(x: trunkX, y: startY))
            ctx.addLine(to: CGPoint(x: trunkX, y: childRect.midY - radius))
            ctx.addQuadCurve(
                to: CGPoint(x: trunkX + radius, y: childRect.midY),
                control: CGPoint(x: trunkX, y: childRect.midY)
            )
            ctx.addLine(to: CGPoint(x: childRect.minX, y: childRect.midY))
            ctx.strokePath()
            startY = childRect.midY - radius
        }
        ctx.restoreGState()
    }

    private static func drawConnection(
        from parentRect: CGRect,
        to childRect: CGRect,
        branchIndex: Int,
        theme: RenderTheme,
        horizontal: Bool,
        in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(branchColor(index: max(0, branchIndex), theme: theme, alpha: 0.6))
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.round)

        if horizontal {
            let startX = parentRect.maxX
            let startY = parentRect.midY
            let endX = childRect.minX
            let endY = childRect.midY
            let controlOffset = (endX - startX) * 0.5
            ctx.move(to: CGPoint(x: startX, y: startY))
            ctx.addCurve(
                to: CGPoint(x: endX, y: endY),
                control1: CGPoint(x: startX + controlOffset, y: startY),
                control2: CGPoint(x: endX - controlOffset, y: endY)
            )
        } else {
            let startX = parentRect.midX
            let startY = parentRect.maxY
            let endX = childRect.midX
            let endY = childRect.minY
            let controlOffset = (endY - startY) * 0.5
            ctx.move(to: CGPoint(x: startX, y: startY))
            ctx.addCurve(
                to: CGPoint(x: endX, y: endY),
                control1: CGPoint(x: startX, y: startY + controlOffset),
                control2: CGPoint(x: endX, y: endY - controlOffset)
            )
        }
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
            path = bangPath(rect)
        case .cloud:
            path = cloudPath(rect)
        case .hexagon:
            path = hexagonPath(rect)
        }

        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    /// Bang shape — compact jagged badge approximating Mermaid's bang marker.
    private static func bangPath(_ rect: CGRect) -> CGPath {
        let r = rect.insetBy(dx: 2, dy: 2)
        let notch = min(r.width, r.height) * 0.18
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX + notch, y: r.minY))
        path.addLine(to: CGPoint(x: r.midX, y: r.minY + notch * 0.7))
        path.addLine(to: CGPoint(x: r.maxX - notch, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - notch * 0.7, y: r.midY))
        path.addLine(to: CGPoint(x: r.maxX - notch, y: r.maxY))
        path.addLine(to: CGPoint(x: r.midX, y: r.maxY - notch * 0.7))
        path.addLine(to: CGPoint(x: r.minX + notch, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + notch * 0.7, y: r.midY))
        path.closeSubpath()
        return path
    }

    /// Cloud shape — rounded bumpy outline resembling a thought bubble.
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
        MermaidTextUtils.hexagonPath(rect)
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
