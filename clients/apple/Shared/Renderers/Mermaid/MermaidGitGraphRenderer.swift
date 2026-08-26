import CoreGraphics
import CoreText
import Foundation

/// Renderer for Mermaid `gitGraph`.
///
/// LR (default): commits left-to-right, branches stacked. TB/BT: commits
/// along Y, branches side-by-side. Theme accents color branches. No page
/// fill. Leftover orientation and illegal cherry-pick/merge fail visibly.
enum MermaidGitGraphRenderer {

    private static let outerMargin: CGFloat = 16
    private static let inset: CGFloat = 8
    private static let commitRadius: CGFloat = 8
    private static let branchGap: CGFloat = 40
    private static let minCommitGap: CGFloat = 32
    private static let tagPad: CGFloat = 8
    private static let tagGap: CGFloat = 8
    private static let tagCorner: CGFloat = 8

    nonisolated static func layout(
        _ diagram: GitGraphDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        if case .unsupported(let token) = diagram.orientation {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Unsupported gitGraph orientation: \(token)",
                configuration: configuration
            )
        }
        if let error = diagram.error {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: error,
                configuration: configuration
            )
        }
        guard !diagram.commits.isEmpty else {
            return MermaidFlowchartRenderer().placeholderLayout(
                text: "Empty git graph",
                configuration: configuration
            )
        }

        let theme = configuration.theme
        let fontSize = configuration.fontSize
        let maxWidth = max(configuration.maxWidth, 1)
        let isLR = diagram.orientation == .lr
        let branchNames = diagram.branches.map(\.name)
        let branchIndex = Dictionary(uniqueKeysWithValues: branchNames.enumerated().map { ($0.element, $0.offset) })

        let columns = commitColumns(diagram)
        let maxColumn = columns.values.max() ?? 0
        let branchCount = max(branchNames.count, 1)

        let labelExtra: CGFloat = diagram.options.showCommitLabel ? fontSize * 1.6 : 8
        let branchLabelWidth: CGFloat = diagram.options.showBranches
            ? max(branchNames.map { CGFloat($0.count) * fontSize * 0.45 }.max() ?? 40, 36)
            : 0
        let tagFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.65, nil)
        let tagFontSize = fontSize * 0.65
        let tagged = diagram.commits.compactMap(\.tag)
        let maxTagHeight: CGFloat = tagged.map {
            MermaidTextUtils.measureText($0, font: tagFont, fontSize: tagFontSize).height
        }.max() ?? 0
        let maxTagWidth: CGFloat = tagged.map {
            MermaidTextUtils.measureText($0, font: tagFont, fontSize: tagFontSize).width + tagPad
        }.max() ?? 0
        let tagReserve: CGFloat = tagged.isEmpty ? 0 : maxTagHeight + tagPad + tagGap
        let rightSlack = tagged.isEmpty
            ? commitRadius + inset
            : max(maxTagWidth / 2 + inset, commitRadius + inset)

        let commitGap: CGFloat = {
            guard isLR, maxColumn > 0 else { return minCommitGap }
            let startX = outerMargin + branchLabelWidth + inset
            let endX = max(startX + minCommitGap, maxWidth - rightSlack)
            return max(16, min(40, (endX - startX) / CGFloat(maxColumn)))
        }()

        let axisSpan = CGFloat(maxColumn) * commitGap
        let crossSpan = CGFloat(max(branchCount - 1, 0)) * branchGap
        let width: CGFloat
        let height: CGFloat
        if isLR {
            width = min(maxWidth, outerMargin + branchLabelWidth + inset + axisSpan + rightSlack)
            height = outerMargin + tagReserve + crossSpan + commitRadius + labelExtra + inset
        } else {
            width = min(maxWidth, outerMargin + crossSpan + commitRadius + branchLabelWidth + inset)
            height = outerMargin + tagReserve + axisSpan + commitRadius + labelExtra + inset
        }

        let orientation = diagram.orientation
        let position: @Sendable (Int, Int) -> CGPoint = { column, branch in
            switch orientation {
            case .lr:
                let x = outerMargin + branchLabelWidth + inset + CGFloat(column) * commitGap
                let y = outerMargin + tagReserve + CGFloat(branch) * branchGap
                return CGPoint(x: x, y: y)
            case .tb:
                let x = outerMargin + CGFloat(branch) * branchGap
                let y = outerMargin + tagReserve + CGFloat(column) * commitGap
                return CGPoint(x: x, y: y)
            case .bt:
                let x = outerMargin + CGFloat(branch) * branchGap
                let y = height - outerMargin - CGFloat(column) * commitGap
                return CGPoint(x: x, y: y)
            case .unsupported:
                return .zero
            }
        }

        var nodePositions: [String: CGRect] = [:]
        var nodeLabels: [String: String] = [:]
        var commitCenters: [String: CGPoint] = [:]
        for commit in diagram.commits {
            let b = branchIndex[commit.branch] ?? 0
            let col = columns[commit.id] ?? commit.seq
            let center = position(col, b)
            commitCenters[commit.id] = center
            nodePositions["commit-\(commit.id)"] = CGRect(
                x: center.x - commitRadius,
                y: center.y - commitRadius,
                width: commitRadius * 2,
                height: commitRadius * 2
            )
            nodeLabels["$commit-\(commit.id)"] = commit.id
            if let tag = commit.tag {
                let tagSize = MermaidTextUtils.measureText(
                    tag, font: tagFont, fontSize: tagFontSize
                )
                var tagRect = CGRect(
                    x: center.x - (tagSize.width + tagPad) / 2,
                    y: center.y - commitRadius - tagGap - tagSize.height - tagPad,
                    width: tagSize.width + tagPad,
                    height: tagSize.height + tagPad
                )
                if tagRect.minX < inset {
                    tagRect.origin.x = inset
                }
                if tagRect.maxX > width - inset {
                    tagRect.origin.x = max(inset, width - inset - tagRect.width)
                }
                if tagRect.minY < inset {
                    tagRect.origin.y = inset
                }
                nodePositions["tag-\(commit.id)"] = tagRect
                nodeLabels["$tag-\(commit.id)"] = tag
            }
        }
        if diagram.options.showBranches {
            for (i, name) in branchNames.enumerated() {
                let p = position(0, i)
                nodePositions["branch-\(name)"] = CGRect(
                    x: outerMargin,
                    y: p.y - fontSize * 0.6,
                    width: branchLabelWidth,
                    height: fontSize * 1.2
                )
                nodeLabels["$branch-\(name)"] = name
            }
        }

        var edgePaths: [GraphLayoutEdgePath] = []
        for commit in diagram.commits {
            guard let to = commitCenters[commit.id] else { continue }
            for parent in commit.parents {
                guard let from = commitCenters[parent] else { continue }
                edgePaths.append(GraphLayoutEdgePath(
                    from: parent,
                    to: commit.id,
                    points: joinPoints(from: from, to: to, orientation: orientation)
                ))
            }
        }

        let size = CGSize(width: width, height: height)
        let colors = theme.diagramAccents
        let capturedCommits = diagram.commits
        let capturedCenters = commitCenters
        let capturedOptions = diagram.options
        let capturedBranches = branchNames
        let capturedOrientation = diagram.orientation
        let capturedTagFrames = nodePositions.filter { $0.key.hasPrefix("tag-") }
        let capturedJoins = edgePaths

        let draw: @Sendable (CGContext, CGPoint) -> Void = { ctx, origin in
            let ox = origin.x
            let oy = origin.y

            // Rails, then every parent join. Commit/tag/label ink comes after so
            // merge cubics cannot sit on top of earlier nodes (`chore`, `release`).
            for (i, _) in capturedBranches.enumerated() {
                let color = colors[i % colors.count]
                ctx.setStrokeColor(color.copy(alpha: 0.7) ?? color)
                ctx.setLineWidth(2)
                let start = position(0, i)
                let end = position(maxColumn, i)
                ctx.move(to: CGPoint(x: ox + start.x, y: oy + start.y))
                ctx.addLine(to: CGPoint(x: ox + end.x, y: oy + end.y))
                ctx.strokePath()
            }

            for join in capturedJoins {
                guard join.points.count >= 2 else { continue }
                let color = colors[(branchIndex[
                    capturedCommits.first { $0.id == join.to }?.branch ?? ""
                ] ?? 0) % colors.count]
                ctx.setStrokeColor(color.copy(alpha: 0.85) ?? color)
                ctx.setLineWidth(1.5)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                let points = join.points.map { CGPoint(x: ox + $0.x, y: oy + $0.y) }
                ctx.move(to: points[0])
                if points.count == 4 {
                    ctx.addCurve(to: points[3], control1: points[1], control2: points[2])
                } else {
                    ctx.addLine(to: points[points.count - 1])
                }
                ctx.strokePath()
            }

            if capturedOptions.showBranches {
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.8, nil)
                for (i, name) in capturedBranches.enumerated() {
                    let color = colors[i % colors.count]
                    let start = position(0, i)
                    MermaidTextUtils.drawText(
                        name,
                        at: CGPoint(x: ox + outerMargin, y: oy + start.y - fontSize * 0.45),
                        width: branchLabelWidth,
                        font: font,
                        fontSize: fontSize * 0.8,
                        foregroundColor: color,
                        alignment: .left,
                        in: ctx
                    )
                }
            }

            for commit in capturedCommits {
                guard let center = capturedCenters[commit.id] else { continue }
                let p = CGPoint(x: ox + center.x, y: oy + center.y)

                let color = colors[(branchIndex[commit.branch] ?? 0) % colors.count]
                drawCommit(
                    commit,
                    at: p,
                    color: color,
                    theme: theme,
                    in: ctx
                )

                if capturedOptions.showCommitLabel {
                    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.7, nil)
                    ctx.saveGState()
                    if capturedOptions.rotateCommitLabel && capturedOrientation == .lr {
                        ctx.translateBy(x: p.x + 4, y: p.y + commitRadius + 2)
                        ctx.rotate(by: .pi / 4)
                        MermaidTextUtils.drawText(
                            commit.id,
                            at: .zero,
                            font: font,
                            fontSize: fontSize * 0.7,
                            foregroundColor: theme.foreground,
                            in: ctx
                        )
                    } else {
                        MermaidTextUtils.drawText(
                            commit.id,
                            at: CGPoint(x: p.x - 16, y: p.y + commitRadius + 2),
                            width: 40,
                            font: font,
                            fontSize: fontSize * 0.7,
                            foregroundColor: theme.foreground,
                            alignment: .center,
                            in: ctx
                        )
                    }
                    ctx.restoreGState()
                }

                if let tag = commit.tag {
                    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.65, nil)
                    let tagRect = (capturedTagFrames["tag-\(commit.id)"] ?? CGRect(
                        x: center.x - 12,
                        y: center.y - commitRadius - fontSize,
                        width: 24,
                        height: fontSize
                    )).offsetBy(dx: ox, dy: oy)
                    ctx.setFillColor(theme.accentYellow.copy(alpha: 0.25) ?? theme.accentYellow)
                    ctx.setStrokeColor(theme.accentYellow)
                    ctx.setLineWidth(1)
                    let corner = min(tagCorner, tagRect.height / 2, tagRect.width / 2)
                    ctx.addPath(CGPath(
                        roundedRect: tagRect, cornerWidth: corner, cornerHeight: corner, transform: nil
                    ))
                    ctx.drawPath(using: .fillStroke)
                    MermaidTextUtils.drawText(
                        tag,
                        at: CGPoint(x: tagRect.minX + tagPad / 2, y: tagRect.minY + tagPad / 4),
                        font: font,
                        fontSize: fontSize * 0.65,
                        foregroundColor: theme.foreground,
                        in: ctx
                    )
                }
            }
        }

        return .custom(
            size: size,
            nodePositions: nodePositions,
            nodeLabels: nodeLabels,
            configuration: configuration,
            edgePaths: edgePaths,
            draw: draw
        )
    }

    /// Sequential columns, or generation (distance from roots) when
    /// `parallelCommits` is on.
    private static func commitColumns(_ diagram: GitGraphDiagram) -> [String: Int] {
        var columns: [String: Int] = [:]
        if diagram.options.parallelCommits {
            var byId = Dictionary(uniqueKeysWithValues: diagram.commits.map { ($0.id, $0) })
            func generation(_ id: String, stack: Set<String> = []) -> Int {
                if let cached = columns[id] { return cached }
                guard !stack.contains(id), let commit = byId[id] else { return 0 }
                if commit.parents.isEmpty {
                    columns[id] = 0
                    return 0
                }
                let next = stack.union([id])
                let value = 1 + (commit.parents.map { generation($0, stack: next) }.max() ?? 0)
                columns[id] = value
                return value
            }
            for commit in diagram.commits {
                _ = generation(commit.id)
            }
        } else {
            for commit in diagram.commits {
                columns[commit.id] = commit.seq
            }
        }
        return columns
    }

    /// Same-lane parents stay a straight lane. Cross-lane branch, merge, and
    /// cherry-pick joins are cubic Béziers that leave the source, travel in the
    /// gutter between the two branch lanes, then enter the target. Mid-lane
    /// controls would occupy the rectangle between endpoints and slice later
    /// commits (gallery `chore` / `release`).
    private static func joinPoints(
        from: CGPoint,
        to: CGPoint,
        orientation: GitGraphOrientation
    ) -> [CGPoint] {
        let sameLane: Bool
        switch orientation {
        case .lr:
            sameLane = abs(from.y - to.y) < 0.5
        case .tb, .bt:
            sameLane = abs(from.x - to.x) < 0.5
        case .unsupported:
            sameLane = true
        }
        if sameLane {
            return [from, to]
        }
        switch orientation {
        case .lr:
            let midY = from.y + (to.y - from.y) * 0.5
            return [
                from,
                CGPoint(x: from.x, y: midY),
                CGPoint(x: to.x, y: midY),
                to,
            ]
        case .tb, .bt:
            let midX = from.x + (to.x - from.x) * 0.5
            return [
                from,
                CGPoint(x: midX, y: from.y),
                CGPoint(x: midX, y: to.y),
                to,
            ]
        case .unsupported:
            return [from, to]
        }
    }

    private static func drawCommit(
        _ commit: GitGraphCommit,
        at point: CGPoint,
        color: CGColor,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let r = commitRadius
        let disk = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        switch commit.style {
        case .highlight:
            ctx.setFillColor(color)
            ctx.fill(disk)
        case .reverse:
            punchCommitDisk(disk, in: ctx)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: disk)
            ctx.move(to: CGPoint(x: point.x - r * 0.6, y: point.y - r * 0.6))
            ctx.addLine(to: CGPoint(x: point.x + r * 0.6, y: point.y + r * 0.6))
            ctx.strokePath()
        case .merge:
            punchCommitDisk(disk, in: ctx)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: disk)
            ctx.strokeEllipse(in: CGRect(x: point.x - r + 3, y: point.y - r + 3, width: r * 2 - 6, height: r * 2 - 6))
        case .cherryPick:
            ctx.setFillColor(theme.accentRed)
            ctx.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(theme.accentGreen)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: point.x, y: point.y - r))
            ctx.addLine(to: CGPoint(x: point.x + 4, y: point.y - r - 6))
            ctx.strokePath()
        case .normal:
            ctx.setFillColor(color)
            ctx.fillEllipse(in: disk)
        }
    }

    /// Hollow commit styles must erase lane and parent ink so the curve cannot
    /// remain visible through `chore`-style reverse disks.
    private static func punchCommitDisk(_ disk: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: disk)
        ctx.restoreGState()
    }
}
