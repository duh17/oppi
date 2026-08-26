import CoreGraphics
import Testing
@testable import Oppi

// SPEC: https://mermaid.js.org/syntax/gitgraph.html
//
// COVERAGE:
// [x] gitGraph / gitGraph LR: / TB: / BT:
// [x] commit, branch, checkout/switch, merge, cherry-pick
// [x] commit/merge attrs id, type NORMAL/REVERSE/HIGHLIGHT, tag
// [x] branch order and quoted branch names
// [x] frontmatter: showBranches, showCommitLabel, mainBranchName,
//     mainBranchOrder, rotateCommitLabel, parallelCommits
// [x] default branch is main unless mainBranchName says otherwise
// [x] cherry-pick rules (existing id, other branch, current has a commit,
//     merge needs parent)
// [x] leftover orientation fails visibly
// [x] gallery fixture layouts inside 360pt
// [x] tag pills stay below the top padding
// [x] cross-lane branch/merge/cherry-pick joins are cubic curves
// [x] cross-lane cubics travel in the lane gutter and clear other commits
// [x] parent joins stroke before commits/tags/labels so nodes paint over edges
// [x] mermaid theme does not paint a page
// [x] malformed input does not crash
//
// DEFERRED:
// [ ] commit msg: string (labels still use id)
// [ ] git0-git7 mermaid theme variables (Oppi accents instead)

@Suite("GitGraph Conformance — Mermaid gitGraph")
struct MermaidGitGraphConformanceTests {

    private static let gallery = """
        gitGraph
          commit id: "init"
          commit id: "docs" tag: "v0.1"
          branch develop
          checkout develop
          commit id: "wip"
          commit id: "fix" type: HIGHLIGHT
          commit id: "chore" type: REVERSE
          checkout main
          merge develop id: "merge" tag: "v1.0"
          commit id: "release"
          cherry-pick id: "fix"
        """

    @Test func detectsGitGraphKeyword() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .gitGraph = result else {
            Issue.record("Expected gitGraph, got \(result)")
            return
        }
    }

    @Test func parsesOrientations() {
        let lr = MermaidGitGraphParser.parse(lines: ["gitGraph LR:", "  commit id: \"a\""])
        let tb = MermaidGitGraphParser.parse(lines: ["gitGraph TB:", "  commit id: \"a\""])
        let bt = MermaidGitGraphParser.parse(lines: ["gitGraph BT:", "  commit id: \"a\""])
        let implicit = MermaidGitGraphParser.parse(lines: ["gitGraph", "  commit id: \"a\""])
        #expect(lr.orientation == .lr)
        #expect(tb.orientation == .tb)
        #expect(bt.orientation == .bt)
        #expect(implicit.orientation == .lr)
    }

    @Test func leftoverOrientationFailsVisibly() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph XY:",
            "  commit id: \"a\"",
        ])
        #expect(diagram.orientation == .unsupported("XY"))
        let layout = layoutGit(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder)
        #expect(layout.placeholderText?.localizedCaseInsensitiveContains("orientation") == true)
    }

    @Test func defaultBranchIsMain() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph",
            "  commit id: \"a\"",
        ])
        #expect(diagram.options.mainBranchName == "main")
        #expect(diagram.commits.first?.branch == "main")
        #expect(diagram.branches.map(\.name) == ["main"])
    }

    @Test func galleryCommands() {
        let diagram = MermaidGitGraphParser.parse(lines: Self.gallery.components(separatedBy: "\n"))
        #expect(diagram.error == nil)
        #expect(diagram.commits.count == 8)
        #expect(Array(diagram.commits.prefix(7).map(\.id)) == [
            "init", "docs", "wip", "fix", "chore", "merge", "release",
        ])
        #expect(diagram.commits.first { $0.id == "docs" }?.tag == "v0.1")
        #expect(diagram.commits.first { $0.id == "fix" }?.style == .highlight)
        #expect(diagram.commits.first { $0.id == "chore" }?.style == .reverse)
        #expect(diagram.commits.first { $0.id == "merge" }?.style == .merge)
        #expect(diagram.commits.first { $0.id == "merge" }?.tag == "v1.0")
        #expect(diagram.commits.last?.style == .cherryPick)
        #expect(diagram.commits.last?.cherrySourceId == "fix")
        #expect(diagram.branches.map(\.name) == ["main", "develop"])
    }

    @Test func switchIsCheckoutAlias() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph",
            "  commit id: \"a\"",
            "  branch feature",
            "  switch main",
            "  commit id: \"b\"",
        ])
        #expect(diagram.commits.first { $0.id == "b" }?.branch == "main")
    }

    @Test func quotedBranchNameAndOrder() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph",
            "  commit id: \"a\"",
            "  branch \"cherry-pick\" order: 2",
            "  commit id: \"b\"",
        ])
        #expect(diagram.branches.contains { $0.name == "cherry-pick" && $0.order == 2 })
        #expect(diagram.commits.first { $0.id == "b" }?.branch == "cherry-pick")
    }

    @Test func frontmatterGitGraphConfig() {
        let source = """
        ---
        config:
          gitGraph:
            showBranches: false
            showCommitLabel: false
            mainBranchName: trunk
            mainBranchOrder: 2
            rotateCommitLabel: false
            parallelCommits: true
        ---
        gitGraph
          commit id: "a"
          branch feature
          commit id: "b"
        """
        let result = MermaidParser().parse(source)
        guard case .gitGraph(let diagram) = result else {
            Issue.record("Expected gitGraph, got \(result)")
            return
        }
        #expect(diagram.options.showBranches == false)
        #expect(diagram.options.showCommitLabel == false)
        #expect(diagram.options.mainBranchName == "trunk")
        #expect(diagram.options.mainBranchOrder == 2)
        #expect(diagram.options.rotateCommitLabel == false)
        #expect(diagram.options.parallelCommits == true)
        #expect(diagram.commits.first?.branch == "trunk")
    }

    @Test func cherryPickMissingIdFailsVisibly() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph",
            "  commit id: \"a\"",
            "  branch f",
            "  commit id: \"b\"",
            "  checkout main",
            "  cherry-pick id: \"nope\"",
        ])
        #expect(diagram.error?.localizedCaseInsensitiveContains("cherry") == true)
        let layout = layoutGit(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder)
    }

    @Test func cherryPickSameBranchFailsVisibly() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph",
            "  commit id: \"a\"",
            "  cherry-pick id: \"a\"",
        ])
        #expect(diagram.error?.localizedCaseInsensitiveContains("current branch") == true)
    }

    @Test func cherryPickRequiresCommitOnCurrentBranch() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph",
            "  branch empty",
            "  checkout main",
            "  commit id: \"a\"",
            "  checkout empty",
            "  cherry-pick id: \"a\"",
        ])
        #expect(diagram.error?.localizedCaseInsensitiveContains("no commits") == true)
    }

    @Test func cherryPickMergeRequiresParent() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph",
            "  commit id: \"a\"",
            "  branch f",
            "  commit id: \"b\"",
            "  checkout main",
            "  merge f id: \"m\"",
            "  branch other",
            "  commit id: \"c\"",
            "  cherry-pick id: \"m\"",
        ])
        #expect(diagram.error?.localizedCaseInsensitiveContains("parent") == true)
    }

    @Test func cherryPickMergeWithParentSucceeds() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph",
            "  commit id: \"a\"",
            "  branch f",
            "  commit id: \"b\"",
            "  checkout main",
            "  merge f id: \"m\"",
            "  branch other",
            "  commit id: \"c\"",
            "  cherry-pick id: \"m\" parent: \"a\"",
        ])
        #expect(diagram.error == nil)
        #expect(diagram.commits.last?.style == .cherryPick)
        #expect(diagram.commits.last?.cherryParentId == "a")
    }

    @Test func galleryLayoutsWithin360() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .gitGraph(let diagram) = result else {
            Issue.record("Expected gitGraph")
            return
        }
        let layout = layoutGit(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        guard let size = layout.customSize else {
            Issue.record("Expected customSize")
            return
        }
        #expect(size.width <= 360)
        #expect(size.height > 0)
        #expect(layout.graphResult.nodePositions["commit-init"] != nil)
        #expect(layout.graphResult.nodePositions["commit-merge"] != nil)
        #expect(draw(layout) != nil)
    }

    @Test func galleryTagsStayInsideTopPadding() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .gitGraph(let diagram) = result else {
            Issue.record("Expected gitGraph")
            return
        }
        let layout = layoutGit(diagram, maxWidth: 360)
        guard let size = layout.customSize else {
            Issue.record("Expected customSize")
            return
        }
        #expect(layout.isPlaceholder == false)

        let positions = layout.graphResult.nodePositions
        let tags = positions.filter { $0.key.hasPrefix("tag-") }
        #expect(tags.count >= 2, "gallery commits docs and merge carry tags")
        #expect(layout.nodeLabels["$tag-docs"] == "v0.1")
        #expect(layout.nodeLabels["$tag-merge"] == "v1.0")

        let inset: CGFloat = 8
        for (key, rect) in tags {
            #expect(rect.minY + 0.5 >= inset, "\(key) is clipped by the top of the card")
            #expect(rect.minX + 0.5 >= inset, "\(key) clips left")
            #expect(rect.maxX <= size.width - inset + 0.5, "\(key) overflows width")
            #expect(rect.maxY <= size.height - inset + 0.5, "\(key) overflows height")
        }
        if let tag = positions["tag-docs"], let commit = positions["commit-docs"] {
            #expect(tag.maxY <= commit.minY + 0.5, "tag-docs must sit above its commit")
        } else {
            Issue.record("Expected tag-docs and commit-docs frames")
        }
        if let tag = positions["tag-merge"], let commit = positions["commit-merge"] {
            #expect(tag.maxY <= commit.minY + 0.5, "tag-merge must sit above its commit")
        } else {
            Issue.record("Expected tag-merge and commit-merge frames")
        }
        #expect(draw(layout) != nil)
    }

    @Test func galleryCrossLaneJoinsAreCubicCurves() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .gitGraph(let diagram) = result else {
            Issue.record("Expected gitGraph")
            return
        }
        let layout = layoutGit(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)

        let positions = layout.graphResult.nodePositions
        let paths = layout.graphResult.edgePaths
        #expect(!paths.isEmpty, "parent joins must be inspectable as edge paths")

        func path(from: String, to: String) -> GraphLayoutEdgePath? {
            paths.first { $0.from == from && $0.to == to }
        }

        let sameLane = [
            ("init", "docs"),
            ("wip", "fix"),
            ("merge", "release"),
        ]
        for (from, to) in sameLane {
            guard let join = path(from: from, to: to) else {
                Issue.record("Expected same-lane path \(from) → \(to)")
                continue
            }
            #expect(join.points.count == 2, "same-lane \(from) → \(to) stays a straight lane")
            if join.points.count == 2 {
                #expect(abs(join.points[0].y - join.points[1].y) < 0.5)
            }
        }

        let crossLane = [
            ("docs", "wip"),
            ("chore", "merge"),
            ("fix", diagram.commits.last?.id ?? ""),
        ]
        for (from, to) in crossLane {
            guard let join = path(from: from, to: to) else {
                Issue.record("Expected cubic join \(from) → \(to)")
                continue
            }
            #expect(join.points.count == 4, "cross-lane \(from) → \(to) must be a cubic Bézier")
            guard join.points.count == 4 else { continue }
            let start = join.points[0]
            let c1 = join.points[1]
            let c2 = join.points[2]
            let end = join.points[3]
            let gutterY = start.y + (end.y - start.y) * 0.5
            #expect(abs(c1.y - gutterY) < 0.5, "\(from) → \(to) should drop into the mid-Y gutter")
            #expect(abs(c2.y - gutterY) < 0.5, "\(from) → \(to) should arrive from the mid-Y gutter")
            #expect(abs(c1.x - start.x) < 0.5, "\(from) → \(to) should leave the source commit first")
            #expect(abs(c2.x - end.x) < 0.5, "\(from) → \(to) should enter the target from the gutter")
            #expect(abs(start.y - end.y) > 1, "\(from) → \(to) must leave its lane")
        }

        if let merge = positions["commit-merge"], let size = layout.customSize {
            #expect(merge.minY >= 8)
            #expect(merge.maxY <= size.height - 8 + 0.5)
        }
        #expect(draw(layout) != nil)
    }

    @Test func galleryCrossLaneJoinsClearOtherCommits() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .gitGraph(let diagram) = result else {
            Issue.record("Expected gitGraph")
            return
        }
        assertCrossLaneJoinsClearOtherCommits(diagram, orientation: .lr)
    }

    @Test func galleryNodesPaintAfterParentEdges() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .gitGraph(let diagram) = result else {
            Issue.record("Expected gitGraph")
            return
        }
        let layout = layoutGit(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        guard let bitmap = paint(layout) else {
            Issue.record("Expected rasterized gitGraph")
            return
        }

        let positions = layout.graphResult.nodePositions
        guard let chore = positions["commit-chore"],
              let release = positions["commit-release"]
        else {
            Issue.record("Expected gallery chore and release frames")
            return
        }

        let main = sRGB(RenderTheme.fallback.diagramAccents[0])
        let radius = min(chore.width, chore.height) / 2
        // Toward the main-lane gutter, inside the disk, off the reverse slash.
        // A merge cubic that paints after this node leaves main-colored ink here.
        let choreProbe = CGPoint(x: chore.midX, y: chore.midY - radius * 0.45)
        let chorePixel = bitmap.pixel(choreProbe)
        #expect(chorePixel.a < 40, "chore interior must punch merge ink; alpha=\(chorePixel.a)")
        if let main {
            #expect(
                distance(chorePixel, main) > 0.18 || chorePixel.a < 40,
                "merge stroke must not sit on top of chore"
            )
        }

        let releasePixel = bitmap.pixel(CGPoint(x: release.midX, y: release.midY))
        #expect(releasePixel.a > 200, "release fill must cover the lane and parent join")
        if let main {
            #expect(distance(releasePixel, main) < 0.12, "release center must be the commit fill, not an overlay stroke")
        }
    }

    @Test func tbCrossLaneJoinsClearOtherCommits() {
        let source = Self.gallery.replacingOccurrences(of: "gitGraph", with: "gitGraph TB:")
        let result = MermaidParser().parse(source)
        guard case .gitGraph(let diagram) = result else {
            Issue.record("Expected gitGraph TB")
            return
        }
        #expect(diagram.orientation == .tb)
        assertCrossLaneJoinsClearOtherCommits(diagram, orientation: .tb)
    }

    @Test func tbOrientationStacksCommitsTopDown() {
        let diagram = MermaidGitGraphParser.parse(lines: [
            "gitGraph TB:",
            "  commit id: \"a\"",
            "  commit id: \"b\"",
        ])
        let layout = layoutGit(diagram, maxWidth: 360)
        guard let a = layout.graphResult.nodePositions["commit-a"],
              let b = layout.graphResult.nodePositions["commit-b"]
        else {
            Issue.record("Expected TB commit frames")
            return
        }
        #expect(a.midY < b.midY)
        #expect(draw(layout) != nil)
    }

    @Test func mermaidThemeDoesNotPaintPage() {
        let source = """
        ---
        config:
          theme: forest
        ---
        gitGraph
          commit id: "a"
        """
        let result = MermaidParser().parse(source)
        guard case .gitGraph(let diagram) = result else {
            Issue.record("Expected gitGraph, got \(result)")
            return
        }
        let layout = MermaidRenderer().layout(.gitGraph(diagram), configuration: .default(maxWidth: 360))
        #expect(layout.isPlaceholder == false)
        guard let size = layout.customSize, let drawBlock = layout.customDraw else {
            Issue.record("Expected custom draw")
            return
        }
        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        _ = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            drawBlock(ctx, .zero)
            return true
        }
        #expect(bytes[0] == 0 && bytes[3] == 0)
    }

    @Test func emptyGitGraphIsPlaceholder() {
        let layout = layoutGit(.empty, maxWidth: 360)
        #expect(layout.isPlaceholder)
    }

    @Test func malformedDoesNotCrash() {
        _ = MermaidParser().parse("gitGraph\n  merge nope")
        _ = MermaidGitGraphParser.parse(lines: ["gitGraph", "  checkout missing"])
        _ = MermaidGitGraphParser.parse(lines: ["gitGraph", "  commit type: WEIRD"])
    }
}

private func layoutGit(
    _ diagram: GitGraphDiagram,
    maxWidth: CGFloat
) -> MermaidFlowchartRenderer.FlowchartLayout {
    MermaidGitGraphRenderer.layout(diagram, configuration: .default(maxWidth: maxWidth))
}

/// Cross-lane cubics must travel in the gutter between branch lanes so the
/// curve does not occupy the rectangle between endpoints and slice later commits.
private func assertCrossLaneJoinsClearOtherCommits(
    _ diagram: GitGraphDiagram,
    orientation: GitGraphOrientation
) {
    let layout = layoutGit(diagram, maxWidth: 360)
    #expect(layout.isPlaceholder == false)

    let positions = layout.graphResult.nodePositions
    let commits: [(id: String, center: CGPoint, radius: CGFloat)] = positions.compactMap { key, rect in
        guard key.hasPrefix("commit-") else { return nil }
        return (
            id: String(key.dropFirst("commit-".count)),
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2
        )
    }
    #expect(commits.count >= 6, "gallery needs enough commits to expose a crossing")

    let clearance = (commits.first?.radius ?? 8) + 2
    let paths = layout.graphResult.edgePaths
    var crossLane = 0
    for path in paths {
        guard path.points.count == 4 else { continue }
        let start = path.points[0]
        let control1 = path.points[1]
        let control2 = path.points[2]
        let end = path.points[3]
        let leavesLane: Bool
        switch orientation {
        case .lr:
            leavesLane = abs(start.y - end.y) > 1
            if leavesLane {
                let gutterY = start.y + (end.y - start.y) * 0.5
                #expect(abs(control1.y - gutterY) < 0.5, "\(path.from) → \(path.to) must travel in the mid-Y gutter")
                #expect(abs(control2.y - gutterY) < 0.5, "\(path.from) → \(path.to) must stay in the mid-Y gutter")
                #expect(abs(control1.x - start.x) < 0.5, "\(path.from) → \(path.to) should leave the source into the gutter")
                #expect(abs(control2.x - end.x) < 0.5, "\(path.from) → \(path.to) should enter the target from the gutter")
            }
        case .tb, .bt:
            leavesLane = abs(start.x - end.x) > 1
            if leavesLane {
                let gutterX = start.x + (end.x - start.x) * 0.5
                #expect(abs(control1.x - gutterX) < 0.5, "\(path.from) → \(path.to) must travel in the mid-X gutter")
                #expect(abs(control2.x - gutterX) < 0.5, "\(path.from) → \(path.to) must stay in the mid-X gutter")
                #expect(abs(control1.y - start.y) < 0.5, "\(path.from) → \(path.to) should leave the source into the gutter")
                #expect(abs(control2.y - end.y) < 0.5, "\(path.from) → \(path.to) should enter the target from the gutter")
            }
        case .unsupported:
            leavesLane = false
        }
        guard leavesLane else { continue }
        crossLane += 1

        let others = commits.filter { $0.id != path.from && $0.id != path.to }
        for step in 1..<20 {
            let t = CGFloat(step) / 20
            let point = cubicPoint(path.points, t: t)
            for commit in others {
                let dx = point.x - commit.center.x
                let dy = point.y - commit.center.y
                let distance = (dx * dx + dy * dy).squareRoot()
                #expect(
                    distance + 0.01 >= clearance,
                    "\(path.from) → \(path.to) at t=\(t) is \(distance) from \(commit.id); need \(clearance)"
                )
            }
        }
    }
    #expect(crossLane >= 3, "gallery branch, merge, and cherry-pick must stay inspectable")
    #expect(draw(layout) != nil)
}

private func cubicPoint(_ points: [CGPoint], t: CGFloat) -> CGPoint {
    let p0 = points[0], p1 = points[1], p2 = points[2], p3 = points[3]
    let u = 1 - t
    let uu = u * u
    let tt = t * t
    return CGPoint(
        x: uu * u * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + tt * t * p3.x,
        y: uu * u * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + tt * t * p3.y
    )
}

private func draw(_ layout: MermaidFlowchartRenderer.FlowchartLayout) -> Bool? {
    paint(layout) == nil ? nil : true
}

private struct GitGraphBitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func pixel(_ point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: UInt8) {
        let x = min(max(Int(point.x.rounded()), 0), width - 1)
        let y = min(max(Int(point.y.rounded()), 0), height - 1)
        let offset = (y * width + x) * 4
        return (
            r: CGFloat(bytes[offset]) / 255,
            g: CGFloat(bytes[offset + 1]) / 255,
            b: CGFloat(bytes[offset + 2]) / 255,
            a: bytes[offset + 3]
        )
    }
}

private func paint(_ layout: MermaidFlowchartRenderer.FlowchartLayout) -> GitGraphBitmap? {
    guard let size = layout.customSize, let draw = layout.customDraw else { return nil }
    let width = max(Int(ceil(size.width)), 1)
    let height = max(Int(ceil(size.height)), 1)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx, .zero)
        return true
    }
    return ok ? GitGraphBitmap(width: width, height: height, bytes: bytes) : nil
}

private func sRGB(_ color: CGColor) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
          let components = converted.components, components.count >= 3
    else { return nil }
    return (components[0], components[1], components[2])
}

private func distance(
    _ pixel: (r: CGFloat, g: CGFloat, b: CGFloat, a: UInt8),
    _ color: (r: CGFloat, g: CGFloat, b: CGFloat)
) -> CGFloat {
    let dr = pixel.r - color.r
    let dg = pixel.g - color.g
    let db = pixel.b - color.b
    return (dr * dr + dg * dg + db * db).squareRoot()
}
