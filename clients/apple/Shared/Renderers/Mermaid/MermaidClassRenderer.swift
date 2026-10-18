import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid class diagrams (`classDiagram`).
///
/// Draws three-compartment UML class boxes (name / attributes / methods)
/// connected by relations with UML end markers. Node placement reuses the
/// shared `SugiyamaLayout` engine; this renderer owns only class-specific
/// measuring and drawing.
///
/// Uses the `FlowchartLayout` container with `customDraw`/`customSize`, the
/// same pattern as the ER and gantt renderers. Until the integrator hook
/// lands, callers reach this through `MermaidClassRenderer.layout(_:configuration:)`
/// directly.
///
/// Spec source (pinned): https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.0/packages/mermaid/src/docs/syntax/classDiagram.md
enum MermaidClassRenderer {

    // MARK: - Layout constants

    private struct LayoutConstants: Sendable {
        let fontSize: CGFloat
        let rowPaddingH: CGFloat
        let rowPaddingV: CGFloat
        let headerPaddingV: CGFloat
        let outerMargin: CGFloat
        let nodeSpacing: CGFloat
        let rankSpacing: CGFloat
        let minBoxWidth: CGFloat
        let maxBoxWidth: CGFloat
        let minCompartmentHeight: CGFloat
        /// Space between the text of two relationship labels in neighboring
        /// lanes. Natural spacing leaves the chips apart; the tight variant
        /// packs lanes closer, so it adds both chips' padding to keep a
        /// visible gap between them.
        let labelLaneGap: CGFloat

        /// `tight` is the fit-to-width variant: half the sibling gap, and
        /// three quarters of the rank gap when ranks run across (`tightRanks`),
        /// the only case where rank gaps add width.
        init(fontSize: CGFloat, maxWidth: CGFloat, tight: Bool = false, tightRanks: Bool = false) {
            self.fontSize = fontSize
            self.rowPaddingH = fontSize * 0.7
            self.rowPaddingV = fontSize * 0.25
            self.headerPaddingV = fontSize * 0.4
            self.outerMargin = fontSize * 1.5
            self.nodeSpacing = fontSize * 3.2 * (tight ? 0.5 : 1)
            self.rankSpacing = fontSize * 5.0 * (tight && tightRanks ? 0.75 : 1)
            self.minBoxWidth = fontSize * 8
            // Leave room for the outer margin; wide diagrams may still exceed
            // the bubble and scale to fit inline (fullscreen zoom is the
            // inspection path, per the fidelity contract).
            self.maxBoxWidth = max(maxWidth - fontSize * 3, fontSize * 12)
            self.minCompartmentHeight = fontSize * 0.9
            self.labelLaneGap = fontSize * 0.5 + (tight ? MermaidClassRenderer.labelChipPadding(fontSize) * 2 : 0)
        }
    }

    // MARK: - Prepared drawing model

    private struct PreparedRow: Sendable {
        let text: String
        let height: CGFloat
        let top: CGFloat
        let isAbstract: Bool
        let isStatic: Bool
    }

    private struct PreparedBox: Sendable {
        let id: String
        /// Wrapped `<<stereotype>>` display text, or nil. Same string is measured and drawn.
        let stereotype: String?
        let title: String
        let rect: CGRect
        let headerHeight: CGFloat
        let attributes: [PreparedRow]
        let attributeHeight: CGFloat
        let methods: [PreparedRow]
        let methodHeight: CGFloat
    }

    private struct PreparedEdge: Sendable {
        let points: [CGPoint]
        let fromEnd: ClassRelationEnd
        let toEnd: ClassRelationEnd
        let line: ClassLineStyle
        let label: String?
        /// Cross-axis label center. Nil means “no label”; otherwise may differ from the arc midpoint.
        let labelCenter: CGPoint?
        let fromCardinality: String?
        let toCardinality: String?
    }

    /// Typeset text for one box, built once for the chosen arrangement.
    private struct BoxText: Sendable {
        let stereotype: MermaidPreparedText?
        let title: MermaidPreparedText
        let attributes: [RowText]
        let methods: [RowText]
    }

    private struct RowText: Sendable {
        let text: MermaidPreparedText
        /// Static members: underline width and baseline-relative top per line.
        let underlines: [(width: CGFloat, top: CGFloat)]
    }

    private struct EdgeText: Sendable {
        let label: MermaidPreparedText?
        let fromCardinality: MermaidPreparedText?
        let toCardinality: MermaidPreparedText?
    }

    /// One placement of the diagram, before any text is typeset for drawing.
    private struct Arrangement {
        let constants: LayoutConstants
        let graphResult: GraphLayoutResult
        let boxes: [PreparedBox]
        let edges: [PreparedEdge]
        let size: CGSize
    }

    // MARK: - Public entry point

    /// Lays out at the natural size; only when that is wider than `maxWidth`
    /// tries, least change first, tighter spacing, then turning a
    /// left-to-right diagram top to bottom (below
    /// `MermaidFlowchartRenderer.directionBreakpoint`), then the turned
    /// diagram with tighter spacing. `RenderFitChoice` keeps whichever shows
    /// largest on screen, counting the inline height cap.
    nonisolated static func layout(
        _ diagram: ClassDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        guard !diagram.classes.isEmpty else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty class diagram",
                configuration: configuration
            )
        }

        let limit = configuration.maxWidth
        let natural = arrange(diagram, configuration: configuration, tight: false)
        var choice = RenderFitChoice(natural: natural, size: natural.size, configuration: configuration)
        guard choice.needsFit else { return finish(natural, diagram: diagram, configuration: configuration) }

        // No arrangement is narrower than its widest box.
        let widestBox = (natural.boxes.map(\.rect.width).max() ?? 0) + natural.constants.outerMargin * 2
        let runsAcross = diagram.direction == .LR || diagram.direction == .RL
        // Across, tight spacing halves the sibling gaps that stack boxes, so it
        // can come out shorter.
        if choice.canImprove(minimumWidth: widestBox, minimumHeight: runsAcross ? 0 : nil) {
            let tight = arrange(diagram, configuration: configuration, tight: true)
            choice.consider(tight, size: tight.size)
        }
        if limit < MermaidFlowchartRenderer.directionBreakpoint, runsAcross,
           choice.canImprove(minimumWidth: widestBox) {
            let turned = ClassDiagram(direction: .TB, classes: diagram.classes, relations: diagram.relations)
            let candidate = arrange(turned, configuration: configuration, tight: false)
            choice.consider(candidate, size: candidate.size)
            if candidate.size.width > limit, choice.canImprove(minimumWidth: widestBox) {
                let tightTurned = arrange(turned, configuration: configuration, tight: true)
                choice.consider(tightTurned, size: tightTurned.size)
            }
        }
        return finish(choice.best, diagram: diagram, configuration: configuration)
    }

    private static func arrange(
        _ diagram: ClassDiagram,
        configuration: RenderConfiguration,
        tight: Bool
    ) -> Arrangement {
        let constants = LayoutConstants(
            fontSize: configuration.fontSize,
            maxWidth: configuration.maxWidth,
            tight: tight,
            tightRanks: diagram.direction == .LR || diagram.direction == .RL
        )
        let laidOut = layoutGraph(diagram, constants: constants)

        let boxes: [PreparedBox] = diagram.classes.compactMap { node in
            guard let rect = laidOut.nodePositions[node.id] else { return nil }
            return prepareBox(for: node, rect: rect, constants: constants)
        }

        let rawEdges: [PreparedEdge] = zip(diagram.relations, laidOut.edgePaths).map { relation, path in
            let label = wrappedLabel(relation.label, constants: constants)
            let mid = path.points.count >= 2 ? arcMidpoint(path.points) : path.points.first
            return PreparedEdge(
                points: path.points,
                fromEnd: relation.fromEnd,
                toEnd: relation.toEnd,
                line: relation.line,
                label: label,
                labelCenter: label == nil ? nil : mid,
                fromCardinality: relation.fromCardinality,
                toCardinality: relation.toCardinality
            )
        }
        let edges = assignLabelLanes(
            rawEdges,
            direction: diagram.direction,
            constants: constants
        )
        let fitted = fittedContentSize(graphResult: laidOut, edges: edges, constants: constants)
        let graphResult = GraphLayoutResult(
            nodePositions: laidOut.nodePositions,
            edgePaths: laidOut.edgePaths,
            totalSize: fitted
        )
        let size = CGSize(
            width: fitted.width + constants.outerMargin * 2,
            height: fitted.height + constants.outerMargin * 2
        )
        return Arrangement(
            constants: constants,
            graphResult: graphResult,
            boxes: boxes,
            edges: edges,
            size: size
        )
    }

    /// Typesets the chosen arrangement once so drawing only paints.
    private static func finish(
        _ arrangement: Arrangement,
        diagram: ClassDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        let constants = arrangement.constants
        let theme = configuration.theme
        let boxes = arrangement.boxes
        let edges = arrangement.edges
        let boxTexts = boxes.map { boxText($0, constants: constants, theme: theme) }
        let edgeTexts = edges.map { edgeText($0, constants: constants, theme: theme) }

        let drawBlock: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let offset = CGPoint(
                x: origin.x + constants.outerMargin,
                y: origin.y + constants.outerMargin
            )
            for (edge, text) in zip(edges, edgeTexts) {
                drawRelation(edge, text: text, at: offset, constants: constants, theme: theme, in: ctx)
            }
            for (box, text) in zip(boxes, boxTexts) {
                drawBox(box, text: text, at: offset, constants: constants, theme: theme, in: ctx)
            }
        }

        return MermaidFlowchartRenderer.FlowchartLayout(
            graphResult: arrangement.graphResult,
            flowchart: .empty,
            subgraphFrames: [:],
            nodeLabels: Dictionary(uniqueKeysWithValues: diagram.classes.map { ($0.id, $0.displayName) }),
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
            customSize: arrangement.size
        )
    }

    private static func boxText(_ box: PreparedBox, constants: LayoutConstants, theme: RenderTheme) -> BoxText {
        let fontSize = constants.fontSize
        func rows(_ rows: [PreparedRow]) -> [RowText] {
            rows.map { row in
                let font = row.isAbstract ? italicFont(fontSize) : bodyFont(fontSize)
                return RowText(
                    text: MermaidPreparedText(row.text, font: font, fontSize: fontSize, color: theme.foreground),
                    underlines: row.isStatic ? underlines(for: row.text, font: font, fontSize: fontSize) : []
                )
            }
        }
        return BoxText(
            stereotype: box.stereotype.map {
                MermaidPreparedText($0, font: stereoFont(fontSize), fontSize: fontSize * 0.85, color: theme.foregroundDim)
            },
            title: MermaidPreparedText(box.title, font: headerFont(fontSize), fontSize: fontSize, color: theme.foreground),
            attributes: rows(box.attributes),
            methods: rows(box.methods)
        )
    }

    private static func edgeText(_ edge: PreparedEdge, constants: LayoutConstants, theme: RenderTheme) -> EdgeText {
        let fontSize = constants.fontSize
        let cardinalityFont = bodyFont(fontSize * 0.85)
        func cardinality(_ text: String?) -> MermaidPreparedText? {
            text.map {
                MermaidPreparedText($0, font: cardinalityFont, fontSize: fontSize * 0.85, color: theme.foregroundDim)
            }
        }
        return EdgeText(
            label: edge.label.map {
                MermaidPreparedText($0, font: bodyFont(fontSize), fontSize: fontSize, color: theme.foregroundDim)
            },
            fromCardinality: cardinality(edge.fromCardinality),
            toCardinality: cardinality(edge.toCardinality)
        )
    }

    // MARK: - Graph layout

    private static func layoutGraph(
        _ diagram: ClassDiagram,
        constants: LayoutConstants
    ) -> GraphLayoutResult {
        let nodes = diagram.classes.map { node in
            GraphLayoutNode(id: node.id, size: measuredBoxSize(for: node, constants: constants))
        }
        let edges = diagram.relations.map { relation in
            GraphLayoutEdge(from: relation.from, to: relation.to)
        }
        let input = GraphLayoutInput(
            nodes: nodes,
            edges: edges,
            direction: graphLayoutDirection(for: diagram.direction),
            nodeSpacing: constants.nodeSpacing + reservedCrossAxisLabelSpace(diagram, constants: constants),
            rankSpacing: constants.rankSpacing + reservedLabelSpace(diagram, constants: constants)
        )
        return SugiyamaLayout.layout(input)
    }

    /// Extra rank gap so midpoint labels (and nearby cardinalities) sit in the corridor, not on boxes.
    private static func reservedLabelSpace(_ diagram: ClassDiagram, constants: LayoutConstants) -> CGFloat {
        let font = bodyFont(constants.fontSize)
        let isHorizontal = diagram.direction == .LR || diagram.direction == .RL
        var extra: CGFloat = 0
        for relation in diagram.relations {
            guard let wrapped = wrappedLabel(relation.label, constants: constants) else { continue }
            let size = measureText(wrapped, font: font, fontSize: constants.fontSize)
            let padding = constants.fontSize * 0.5
            let alongRank = isHorizontal ? size.width : size.height
            var needed = alongRank + padding
            if relation.fromCardinality != nil || relation.toCardinality != nil {
                needed += constants.fontSize * 1.4
            }
            extra = max(extra, needed)
        }
        return extra
    }

    /// Extra sibling gap so same-rank relationship labels can occupy separate cross-axis lanes.
    private static func reservedCrossAxisLabelSpace(
        _ diagram: ClassDiagram,
        constants: LayoutConstants
    ) -> CGFloat {
        let font = bodyFont(constants.fontSize)
        let isHorizontal = diagram.direction == .LR || diagram.direction == .RL
        let padding = constants.labelLaneGap
        var extra: CGFloat = 0
        var byFrom: [String: [ClassRelation]] = [:]
        for relation in diagram.relations {
            guard relation.label != nil, !(relation.label?.isEmpty ?? true) else { continue }
            byFrom[relation.from, default: []].append(relation)
        }
        for group in byFrom.values where group.count >= 2 {
            let crosses: [CGFloat] = group.compactMap { relation in
                guard let wrapped = wrappedLabel(relation.label, constants: constants) else { return nil }
                let size = measureText(wrapped, font: font, fontSize: constants.fontSize)
                return isHorizontal ? size.height : size.width
            }
            guard let maxCross = crosses.max(), crosses.count >= 2 else { continue }
            extra = max(extra, maxCross * 0.5 + padding)
        }
        return extra
    }

    /// Background chip padding around a relationship label.
    private static func labelChipPadding(_ fontSize: CGFloat) -> CGFloat {
        fontSize * 0.25
    }

    /// Pack labels that share a rank corridor into non-overlapping cross-axis lanes.
    private static func assignLabelLanes(
        _ edges: [PreparedEdge],
        direction: FlowDirection,
        constants: LayoutConstants
    ) -> [PreparedEdge] {
        let isHorizontal = direction == .LR || direction == .RL
        let font = bodyFont(constants.fontSize)
        let padding = constants.labelLaneGap

        struct Item {
            let index: Int
            let mid: CGPoint
            let size: CGSize
            let alongRank: CGFloat
        }

        var items: [Item] = []
        for (index, edge) in edges.enumerated() {
            guard let label = edge.label, let mid = edge.labelCenter else { continue }
            let size = measureText(label, font: font, fontSize: constants.fontSize)
            let alongRank = isHorizontal ? mid.x : mid.y
            items.append(Item(index: index, mid: mid, size: size, alongRank: alongRank))
        }

        var centers = edges.map(\.labelCenter)
        let sortedByRank = items.sorted { $0.alongRank < $1.alongRank }
        let corridorSlop = constants.fontSize * 2
        var groups: [[Item]] = []
        for item in sortedByRank {
            if var last = groups.last, let previous = last.last,
               item.alongRank - previous.alongRank <= corridorSlop {
                last.append(item)
                groups[groups.count - 1] = last
            } else {
                groups.append([item])
            }
        }
        for group in groups {
            let sorted = group.sorted { lhs, rhs in
                isHorizontal ? lhs.mid.y < rhs.mid.y : lhs.mid.x < rhs.mid.x
            }
            guard sorted.count >= 2 else { continue }
            if isHorizontal {
                var cursor = sorted[0].mid.y - sorted[0].size.height / 2
                for item in sorted {
                    let half = item.size.height / 2
                    let centerY = max(item.mid.y, cursor + half)
                    centers[item.index] = CGPoint(x: item.mid.x, y: centerY)
                    cursor = centerY + half + padding
                }
            } else {
                var cursor = sorted[0].mid.x - sorted[0].size.width / 2
                for item in sorted {
                    let half = item.size.width / 2
                    let centerX = max(item.mid.x, cursor + half)
                    centers[item.index] = CGPoint(x: centerX, y: item.mid.y)
                    cursor = centerX + half + padding
                }
            }
        }

        return zip(edges, centers).map { edge, center in
            PreparedEdge(
                points: edge.points,
                fromEnd: edge.fromEnd,
                toEnd: edge.toEnd,
                line: edge.line,
                label: edge.label,
                labelCenter: center,
                fromCardinality: edge.fromCardinality,
                toCardinality: edge.toCardinality
            )
        }
    }

    private static func fittedContentSize(
        graphResult: GraphLayoutResult,
        edges: [PreparedEdge],
        constants: LayoutConstants
    ) -> CGSize {
        var width = graphResult.totalSize.width
        var height = graphResult.totalSize.height
        let font = bodyFont(constants.fontSize)
        let padding = constants.fontSize * 0.25
        for edge in edges {
            guard let label = edge.label, let center = edge.labelCenter else { continue }
            let size = measureText(label, font: font, fontSize: constants.fontSize)
            width = max(width, center.x + size.width / 2 + padding)
            height = max(height, center.y + size.height / 2 + padding)
        }
        return CGSize(width: width, height: height)
    }

    private static func graphLayoutDirection(for direction: FlowDirection) -> GraphLayoutDirection {
        switch direction {
        case .TB, .TD: return .topToBottom
        case .BT: return .bottomToTop
        case .LR: return .leftToRight
        case .RL: return .rightToLeft
        }
    }

    // MARK: - Measuring

    private static func headerFont(_ fontSize: CGFloat) -> CTFont {
        CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    }

    private static func bodyFont(_ fontSize: CGFloat) -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    }

    private static func stereoFont(_ fontSize: CGFloat) -> CTFont {
        CTFontCreateWithName("Helvetica-Oblique" as CFString, fontSize * 0.85, nil)
    }

    /// Abstract members are italic (UML classifier `*`).
    private static func italicFont(_ fontSize: CGFloat) -> CTFont {
        CTFontCreateWithName("Helvetica-Oblique" as CFString, fontSize, nil)
    }

    private static func memberFont(_ member: ClassMember, fontSize: CGFloat) -> CTFont {
        member.isAbstract ? italicFont(fontSize) : bodyFont(fontSize)
    }

    private static func measuredBoxSize(for node: ClassNode, constants: LayoutConstants) -> CGSize {
        let width = measuredBoxWidth(for: node, constants: constants)
        let header = measuredHeaderHeight(for: node, width: width, constants: constants)
        let attributes = measuredCompartmentHeight(node.attributes, width: width, constants: constants)
        let methods = measuredCompartmentHeight(node.methods, width: width, constants: constants)
        return CGSize(width: width, height: header + attributes + methods)
    }

    private static func measuredBoxWidth(for node: ClassNode, constants: LayoutConstants) -> CGFloat {
        let titleFont = headerFont(constants.fontSize)
        let stereo = node.stereotype.map { "<<\($0)>>" }
        let titleWidth = measureText(node.displayName, font: titleFont, fontSize: constants.fontSize).width
        let stereoWidth = stereo.map {
            measureText($0, font: stereoFont(constants.fontSize), fontSize: constants.fontSize * 0.85).width
        } ?? 0
        let memberWidth = (node.attributes + node.methods).map {
            measureText($0.displayText, font: memberFont($0, fontSize: constants.fontSize), fontSize: constants.fontSize).width
        }.max() ?? 0
        let natural = max(titleWidth, stereoWidth, memberWidth) + constants.rowPaddingH * 2
        return min(max(natural, constants.minBoxWidth), constants.maxBoxWidth)
    }

    private static func measuredHeaderHeight(
        for node: ClassNode,
        width: CGFloat,
        constants: LayoutConstants
    ) -> CGFloat {
        let budget = width - constants.rowPaddingH * 2
        let title = wrapIfNeeded(node.displayName, budget: budget, font: headerFont(constants.fontSize), constants: constants)
        var height = measureText(title, font: headerFont(constants.fontSize), fontSize: constants.fontSize).height
        if let stereo = wrappedStereotype(node.stereotype, budget: budget, constants: constants) {
            height += measureText(stereo, font: stereoFont(constants.fontSize), fontSize: constants.fontSize * 0.85).height
            height += constants.fontSize * 0.1
        }
        return height + constants.headerPaddingV * 2
    }

    private static func measuredCompartmentHeight(
        _ members: [ClassMember],
        width: CGFloat,
        constants: LayoutConstants
    ) -> CGFloat {
        let budget = width - constants.rowPaddingH * 2
        if members.isEmpty {
            return constants.minCompartmentHeight + constants.rowPaddingV * 2
        }
        var total: CGFloat = constants.rowPaddingV * 2
        for member in members {
            let font = memberFont(member, fontSize: constants.fontSize)
            let wrapped = wrapIfNeeded(member.displayText, budget: budget, font: font, constants: constants)
            var rowHeight = measureText(wrapped, font: font, fontSize: constants.fontSize).height
            if member.isStatic {
                rowHeight += constants.fontSize * 0.15
            }
            total += rowHeight
        }
        return max(total, constants.minCompartmentHeight + constants.rowPaddingV * 2)
    }

    // MARK: - Box preparation

    private static func prepareBox(
        for node: ClassNode,
        rect: CGRect,
        constants: LayoutConstants
    ) -> PreparedBox {
        let budget = rect.width - constants.rowPaddingH * 2
        let title = wrapIfNeeded(
            node.displayName,
            budget: budget,
            font: headerFont(constants.fontSize),
            constants: constants
        )
        let headerHeight = measuredHeaderHeight(for: node, width: rect.width, constants: constants)
        let attributes = prepareRows(
            node.attributes,
            startTop: headerHeight,
            budget: budget,
            constants: constants
        )
        let attributeHeight = measuredCompartmentHeight(
            node.attributes,
            width: rect.width,
            constants: constants
        )
        let methods = prepareRows(
            node.methods,
            startTop: headerHeight + attributeHeight,
            budget: budget,
            constants: constants
        )
        let methodHeight = measuredCompartmentHeight(
            node.methods,
            width: rect.width,
            constants: constants
        )
        return PreparedBox(
            id: node.id,
            stereotype: wrappedStereotype(node.stereotype, budget: budget, constants: constants),
            title: title,
            rect: rect,
            headerHeight: headerHeight,
            attributes: attributes,
            attributeHeight: attributeHeight,
            methods: methods,
            methodHeight: methodHeight
        )
    }

    private static func prepareRows(
        _ members: [ClassMember],
        startTop: CGFloat,
        budget: CGFloat,
        constants: LayoutConstants
    ) -> [PreparedRow] {
        var rows: [PreparedRow] = []
        var top = startTop + constants.rowPaddingV
        for member in members {
            let font = memberFont(member, fontSize: constants.fontSize)
            let wrapped = wrapIfNeeded(member.displayText, budget: budget, font: font, constants: constants)
            var height = measureText(wrapped, font: font, fontSize: constants.fontSize).height
            if member.isStatic {
                height += constants.fontSize * 0.15
            }
            rows.append(
                PreparedRow(
                    text: wrapped,
                    height: height,
                    top: top,
                    isAbstract: member.isAbstract,
                    isStatic: member.isStatic
                )
            )
            top += height
        }
        return rows
    }

    private static func wrappedStereotype(
        _ stereotype: String?,
        budget: CGFloat,
        constants: LayoutConstants
    ) -> String? {
        guard let stereotype, !stereotype.isEmpty else { return nil }
        return wrapIfNeeded(
            "<<\(stereotype)>>",
            budget: budget,
            font: stereoFont(constants.fontSize),
            constants: constants
        )
    }

    private static func wrappedLabel(_ label: String?, constants: LayoutConstants) -> String? {
        guard let label, !label.isEmpty else { return nil }
        let budget = max(constants.fontSize * 10, constants.maxBoxWidth * 0.7)
        return wrapIfNeeded(label, budget: budget, font: bodyFont(constants.fontSize), constants: constants)
    }

    private static func wrapIfNeeded(
        _ text: String,
        budget: CGFloat,
        font: CTFont,
        constants _: LayoutConstants
    ) -> String {
        guard budget > 0 else { return text }
        if lineWidth(text, font: font) <= budget { return text }
        return wrap(text, to: budget, font: font)
    }

    /// Greedy wrap. Oversized tokens are broken so they stay inside `maxWidth`.
    private static func wrap(_ text: String, to maxWidth: CGFloat, font: CTFont) -> String {
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = paragraph.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if words.isEmpty {
                lines.append("")
                continue
            }
            var current = ""
            for word in words {
                let pieces = breakToken(word, to: maxWidth, font: font)
                for (index, piece) in pieces.enumerated() {
                    if current.isEmpty {
                        current = piece
                        continue
                    }
                    let candidate = current + " " + piece
                    if index == 0, lineWidth(candidate, font: font) <= maxWidth {
                        current = candidate
                    } else {
                        lines.append(current)
                        current = piece
                    }
                }
            }
            if !current.isEmpty {
                lines.append(current)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Split an unbroken identifier so each piece fits `maxWidth`.
    private static func breakToken(_ token: String, to maxWidth: CGFloat, font: CTFont) -> [String] {
        if lineWidth(token, font: font) <= maxWidth { return [token] }
        var pieces: [String] = []
        var current = ""
        for character in token {
            let candidate = current + String(character)
            if !current.isEmpty, lineWidth(candidate, font: font) > maxWidth {
                pieces.append(current)
                current = String(character)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces.isEmpty ? [token] : pieces
    }

    private static func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        return CTLineGetBoundsWithOptions(line, []).width
    }

    // MARK: - Box drawing

    private static func drawBox(
        _ box: PreparedBox,
        text: BoxText,
        at offset: CGPoint,
        constants: LayoutConstants,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let rect = box.rect.offsetBy(dx: offset.x, dy: offset.y)
        let fontSize = constants.fontSize

        ctx.saveGState()
        ctx.setFillColor(theme.background)
        ctx.setStrokeColor(theme.accentBlue)
        ctx.setLineWidth(1.4)
        ctx.addRect(rect)
        ctx.drawPath(using: .fillStroke)

        // Header band.
        let headerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: box.headerHeight)
        if let headerTint = theme.accentBlue.copy(alpha: 0.16) {
            ctx.setFillColor(headerTint)
            ctx.fill(headerRect)
        }

        // Compartment separators — three-compartment UML box.
        ctx.setStrokeColor(theme.accentBlue)
        ctx.setLineWidth(1.0)
        let attributeY = rect.minY + box.headerHeight
        ctx.move(to: CGPoint(x: rect.minX, y: attributeY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: attributeY))
        ctx.strokePath()
        let methodY = attributeY + box.attributeHeight
        ctx.move(to: CGPoint(x: rect.minX, y: methodY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: methodY))
        ctx.strokePath()
        ctx.restoreGState()

        // Stereotype + name in the top compartment. Stereotype is already wrapped.
        var headerCursor = headerRect.minY + constants.headerPaddingV
        if let stereotype = text.stereotype {
            stereotype.draw(
                centeredIn: CGRect(
                    x: headerRect.minX + constants.rowPaddingH,
                    y: headerCursor,
                    width: headerRect.width - constants.rowPaddingH * 2,
                    height: stereotype.size.height
                ),
                in: ctx
            )
            headerCursor += stereotype.size.height + fontSize * 0.1
        }
        text.title.draw(
            centeredIn: CGRect(
                x: headerRect.minX + constants.rowPaddingH,
                y: headerCursor,
                width: headerRect.width - constants.rowPaddingH * 2,
                height: text.title.size.height
            ),
            in: ctx
        )

        for (row, rowText) in zip(box.attributes + box.methods, text.attributes + text.methods) {
            let origin = CGPoint(x: rect.minX + constants.rowPaddingH, y: rect.minY + row.top)
            rowText.text.draw(at: origin, in: ctx)
            drawUnderlines(rowText.underlines, at: origin, color: theme.foreground, in: ctx)
        }
    }

    /// UML static classifier: underline each painted line of the member.
    /// Measured once at layout; `top` is relative to the row origin.
    private static func underlines(
        for text: String,
        font: CTFont,
        fontSize: CGFloat
    ) -> [(width: CGFloat, top: CGFloat)] {
        let spacing = fontSize * 0.3
        var y: CGFloat = 0
        var result: [(width: CGFloat, top: CGFloat)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let lineHeight = max(
                measureText(line, font: font, fontSize: fontSize).height,
                fontSize * 1.4
            )
            if !line.isEmpty {
                // drawCTLine places the baseline at origin.y + fontSize.
                result.append((max(lineWidth(line, font: font), fontSize * 0.8), y + fontSize + 1.5))
            }
            y += lineHeight + spacing
        }
        return result
    }

    private static func drawUnderlines(
        _ underlines: [(width: CGFloat, top: CGFloat)],
        at origin: CGPoint,
        color: CGColor,
        in ctx: CGContext
    ) {
        guard !underlines.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.0)
        ctx.setLineCap(.round)
        for underline in underlines {
            ctx.move(to: CGPoint(x: origin.x, y: origin.y + underline.top))
            ctx.addLine(to: CGPoint(x: origin.x + underline.width, y: origin.y + underline.top))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Relation drawing

    private static func drawRelation(
        _ edge: PreparedEdge,
        text: EdgeText,
        at offset: CGPoint,
        constants: LayoutConstants,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        guard edge.points.count >= 2 else { return }
        let points = edge.points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }

        ctx.saveGState()
        ctx.setStrokeColor(theme.foreground)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if edge.line == .dashed {
            let dash = constants.fontSize * 0.45
            ctx.setLineDash(phase: 0, lengths: [dash, dash * 0.7])
        }
        ctx.move(to: points[0])
        for point in points.dropFirst() {
            ctx.addLine(to: point)
        }
        ctx.strokePath()
        ctx.restoreGState()

        drawEndMarker(
            edge.fromEnd,
            at: points[0],
            away: points[1],
            theme: theme,
            constants: constants,
            in: ctx
        )
        drawEndMarker(
            edge.toEnd,
            at: points[points.count - 1],
            away: points[points.count - 2],
            theme: theme,
            constants: constants,
            in: ctx
        )

        if let card = text.fromCardinality {
            drawCardinality(card, at: points[0], away: points[1], theme: theme, constants: constants, in: ctx)
        }
        if let card = text.toCardinality {
            drawCardinality(
                card,
                at: points[points.count - 1],
                away: points[points.count - 2],
                theme: theme,
                constants: constants,
                in: ctx
            )
        }

        if let label = text.label {
            let center = edge.labelCenter.map {
                CGPoint(x: $0.x + offset.x, y: $0.y + offset.y)
            } ?? arcMidpoint(points)
            drawLabel(label, at: center, theme: theme, constants: constants, in: ctx)
        }
    }

    /// UML marker at a class boundary.
    ///
    /// `point` sits on the class edge; `away` is the next polyline vertex,
    /// so the marker extends back along the line, away from the class.
    private static func drawEndMarker(
        _ end: ClassRelationEnd,
        at point: CGPoint,
        away: CGPoint,
        theme: RenderTheme,
        constants: LayoutConstants,
        in ctx: CGContext
    ) {
        guard end != .none else { return }
        let dx = away.x - point.x
        let dy = away.y - point.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }
        let u = CGPoint(x: dx / length, y: dy / length) // away from class
        let v = CGPoint(x: -u.y, y: u.x)
        let size = constants.fontSize * 0.85

        func at(_ distance: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(
                x: point.x + u.x * distance + v.x * side,
                y: point.y + u.y * distance + v.y * side
            )
        }

        ctx.saveGState()
        ctx.setStrokeColor(theme.foreground)
        ctx.setFillColor(theme.foreground)
        ctx.setLineWidth(1.2)
        ctx.setLineJoin(.miter)
        ctx.setLineCap(.round)

        switch end {
        case .none:
            break
        case .inheritance:
            // Hollow triangle pointing at the parent class.
            let tip = point
            let left = at(size, size * 0.55)
            let right = at(size, -size * 0.55)
            ctx.move(to: tip)
            ctx.addLine(to: left)
            ctx.addLine(to: right)
            ctx.closePath()
            ctx.setFillColor(theme.background)
            ctx.drawPath(using: .fillStroke)
        case .composition, .aggregation:
            // Diamond: filled for composition, hollow for aggregation.
            let tip = point
            let midLeft = at(size * 0.7, size * 0.45)
            let midRight = at(size * 0.7, -size * 0.45)
            let far = at(size * 1.4, 0)
            ctx.move(to: tip)
            ctx.addLine(to: midLeft)
            ctx.addLine(to: far)
            ctx.addLine(to: midRight)
            ctx.closePath()
            if end == .composition {
                ctx.drawPath(using: .fillStroke)
            } else {
                ctx.setFillColor(theme.background)
                ctx.drawPath(using: .fillStroke)
            }
        case .association:
            // Open arrowhead pointing at the class.
            let left = at(size, size * 0.45)
            let right = at(size, -size * 0.45)
            ctx.move(to: left)
            ctx.addLine(to: point)
            ctx.addLine(to: right)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    private static func drawCardinality(
        _ text: MermaidPreparedText,
        at point: CGPoint,
        away: CGPoint,
        theme: RenderTheme,
        constants: LayoutConstants,
        in ctx: CGContext
    ) {
        let dx = away.x - point.x
        let dy = away.y - point.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }
        let u = CGPoint(x: dx / length, y: dy / length)
        let v = CGPoint(x: -u.y, y: u.x)
        let size = text.size
        let anchor = CGPoint(
            x: point.x + u.x * constants.fontSize * 1.6 + v.x * constants.fontSize * 0.85,
            y: point.y + u.y * constants.fontSize * 1.6 + v.y * constants.fontSize * 0.85
        )
        let rect = CGRect(
            x: anchor.x - size.width / 2,
            y: anchor.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        ctx.saveGState()
        ctx.setFillColor(theme.background)
        ctx.fill(rect.insetBy(dx: -2, dy: -1))
        ctx.restoreGState()
        text.draw(centeredIn: rect, in: ctx)
    }

    private static func drawLabel(
        _ label: MermaidPreparedText,
        at mid: CGPoint,
        theme: RenderTheme,
        constants: LayoutConstants,
        in ctx: CGContext
    ) {
        let textSize = label.size
        let padding = labelChipPadding(constants.fontSize)
        let background = CGRect(
            x: mid.x - textSize.width / 2 - padding,
            y: mid.y - textSize.height / 2 - padding,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        ctx.saveGState()
        ctx.setFillColor(theme.background)
        ctx.fill(background)
        ctx.restoreGState()
        label.draw(centeredIn: background, in: ctx)
    }

    private static func arcMidpoint(_ points: [CGPoint]) -> CGPoint {
        guard points.count >= 2 else { return points.first ?? .zero }
        var total: CGFloat = 0
        for index in 0..<(points.count - 1) {
            total += hypot(
                points[index + 1].x - points[index].x,
                points[index + 1].y - points[index].y
            )
        }
        guard total > 0 else { return points[0] }
        var remaining = total / 2
        for index in 0..<(points.count - 1) {
            let dx = points[index + 1].x - points[index].x
            let dy = points[index + 1].y - points[index].y
            let length = hypot(dx, dy)
            if length >= remaining {
                let t = length > 0 ? remaining / length : 0
                return CGPoint(
                    x: points[index].x + dx * t,
                    y: points[index].y + dy * t
                )
            }
            remaining -= length
        }
        return points[points.count - 1]
    }

    // MARK: - Text helpers

    private static func measureText(_ text: String, font: CTFont, fontSize: CGFloat) -> CGSize {
        MermaidTextUtils.measureText(text, font: font, fontSize: fontSize)
    }
}
