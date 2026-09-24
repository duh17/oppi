import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Semantic annotation")
struct SemanticAnnotationTests {
    @Test func polylineHitIgnoresBoundingBoxCorners() {
        let map = SemanticAnnotationMap(
            sourceRevision: "rev",
            targets: [
                SemanticTarget(
                    id: "edge:1",
                    kind: "flowchart.edge",
                    label: "A to B",
                    displayKey: "A → B",
                    spans: [],
                    sourceOrigin: .source,
                    sourceRevision: "rev"
                )
            ],
            regions: [
                SemanticRegion(
                    targetID: "edge:1",
                    geometry: .polyline(
                        points: [
                            CGPoint(x: 0, y: 0),
                            CGPoint(x: 40, y: 0),
                            CGPoint(x: 40, y: 40),
                        ],
                        strokeWidth: 2
                    ),
                    precedence: 1
                )
            ]
        )

        let corner = map.hitTest(point: CGPoint(x: 2, y: 38), tolerance: 1)
        let stroke = map.hitTest(point: CGPoint(x: 40, y: 20), tolerance: 1)

        #expect(corner.targets.isEmpty)
        #expect(stroke.targets.map(\.id) == ["edge:1"])
    }

    @Test func strokedQuadraticDoesNotSelectInteriorBetweenCurveAndChord() {
        let path = SemanticPath(elements: [
            .move(CGPoint(x: 0, y: 0)),
            .quad(to: CGPoint(x: 100, y: 0), control: CGPoint(x: 50, y: 100)),
        ])
        let geometry = SemanticGeometry.strokedPath(path, strokeWidth: 2)
        let interior = CGPoint(x: 50, y: 25)
        let onCurve = CGPoint(x: 50, y: 50)

        #expect(geometry.contains(interior, tolerance: 0) == false)
        #expect(geometry.contains(onCurve, tolerance: 1))
    }

    @Test func overlappingTargetsStayAmbiguousInsteadOfGuessing() {
        let map = SemanticAnnotationMap(
            sourceRevision: "rev",
            targets: [
                target("node:A", label: "A"),
                target("node:B", label: "B"),
            ],
            regions: [
                SemanticRegion(targetID: "node:A", geometry: .rectangle(CGRect(x: 0, y: 0, width: 20, height: 20)), precedence: 2),
                SemanticRegion(targetID: "node:B", geometry: .ellipse(CGRect(x: 10, y: 0, width: 20, height: 20)), precedence: 2),
            ]
        )

        let hit = map.hitTest(point: CGPoint(x: 15, y: 10), tolerance: 0)

        #expect(hit.isAmbiguous)
        #expect(Set(hit.targets.map(\.id)) == ["node:A", "node:B"])
    }

    @Test func repeatedRegionsResolveToOneTarget() {
        let shared = target("slice:1", label: "Cats")
        let map = SemanticAnnotationMap(
            sourceRevision: "rev",
            targets: [shared],
            regions: [
                SemanticRegion(
                    targetID: "slice:1",
                    geometry: .sector(center: CGPoint(x: 0, y: 0), radius: 10, startAngle: 0, endAngle: .pi),
                    precedence: 3
                ),
                SemanticRegion(
                    targetID: "slice:1",
                    geometry: .rectangle(CGRect(x: 30, y: 0, width: 20, height: 10)),
                    precedence: 2
                ),
            ]
        )

        let sector = map.hitTest(point: CGPoint(x: 4, y: 4), tolerance: 0)
        let legend = map.hitTest(point: CGPoint(x: 35, y: 4), tolerance: 0)
        let outsideWedge = map.hitTest(point: CGPoint(x: 4, y: -4), tolerance: 0)

        #expect(sector.targets.map(\.id) == ["slice:1"])
        #expect(legend.targets.map(\.id) == ["slice:1"])
        #expect(!sector.isAmbiguous)
        #expect(outsideWedge.targets.isEmpty)
    }

    @Test func zoomConvertsScreenToleranceIntoLayoutSpace() {
        let point = SemanticCoordinateTransform.layoutPoint(
            viewPoint: CGPoint(x: 100, y: 80),
            contentOrigin: CGPoint(x: 20, y: 10),
            zoomScale: 2
        )
        #expect(point == CGPoint(x: 40, y: 35))
        #expect(SemanticCoordinateTransform.layoutTolerance(screenTolerance: 12, zoomScale: 2) == 6)
        #expect(SemanticCoordinateTransform.layoutTolerance(screenTolerance: 12, zoomScale: 0.5) == 24)
    }

    @Test func sourceRevisionDistinguishesIdenticalTargetIDsAndDoesNotReanchor() {
        let original = ReviewCommentSemanticAnchor(
            sourceRevision: SemanticSourceRevision.hash(of: "flowchart TD\nA-->B"),
            targetID: "node:A",
            kind: "flowchart.node",
            label: "A",
            displayKey: "A",
            sourceOrigin: .source,
            spans: [],
            isStale: false
        )
        let edited = SemanticSourceRevision.hash(of: "flowchart TD\nA-->C")
        let resolved = original.markedStaleAgainst(currentRevision: edited)

        #expect(original.sourceRevision != edited)
        #expect(resolved.targetID == "node:A")
        #expect(resolved.label == "A")
        #expect(resolved.isStale)
        #expect(resolved.sourceRevision == original.sourceRevision)
    }

    private func target(_ id: String, label: String) -> SemanticTarget {
        SemanticTarget(
            id: id,
            kind: "test",
            label: label,
            displayKey: label,
            spans: [],
            sourceOrigin: .source,
            sourceRevision: "rev"
        )
    }
}

@Suite("Mermaid semantic selection")
struct MermaidSemanticSelectionTests {
    private let config = RenderConfiguration(
        fontSize: 14,
        maxWidth: 800,
        theme: .fallback,
        displayMode: .document
    )

    @Test func flowchartSelectsNodesEdgesChainsAndDuplicateEdges() throws {
        let source = """
        flowchart LR
        A[Start] --> B[End]
        A --> B
        A[Start] --> B[End] --> C[Next]
        """
        let map = try #require(renderedMap(source))
        let node = try #require(map.target(id: "node:A"))
        let nodeHit = map.hitTest(point: samplePoint(for: "node:A", in: map), tolerance: 0)
        #expect(nodeHit.targets.map(\.id).contains("node:A"))
        #expect(node.spans.contains { $0.role == .declaration && $0.excerpt.contains("A[Start]") })

        let edges = map.targets.filter { $0.kind == "flowchart.edge" }
        #expect(edges.count >= 4)
        #expect(Set(edges.map(\.id)).count == edges.count)

        let chained = edges.filter { $0.spans.contains { $0.startLine == lineNumber(containing: "A[Start] --> B[End] --> C[Next]", in: source) } }
        #expect(chained.count >= 2)
        let columns = chained.compactMap { $0.spans.first { $0.role == .declaration }?.startColumn }
        #expect(Set(columns).count >= 2)

        let duplicate = edges.filter { $0.displayKey.hasPrefix("A → B") }
        #expect(duplicate.count >= 2)
        let firstDuplicate = try #require(duplicate.first)
        let duplicateHit = map.hitTest(point: samplePoint(for: firstDuplicate.id, in: map), tolerance: 2)
        #expect(duplicateHit.targets.map(\.id).contains(firstDuplicate.id))
    }

    @Test func pieSliceAndLegendShareTargetWhileDuplicateLabelsStayDistinct() throws {
        let source = """
        pie showData
        title Pets
        "Cats" : 10
        "Cats" : 30
        "Dogs" : 20
        """
        let map = try #require(renderedMap(source))
        let slices = map.targets.filter { $0.kind == "pie.slice" }
        #expect(slices.count == 3)
        #expect(Set(slices.map(\.id)) == ["slice:1", "slice:2", "slice:3"])
        let cats = slices.filter { $0.label == "Cats" }
        #expect(cats.count == 2)
        #expect(cats[0].id != cats[1].id)

        let first = map.hitTest(point: samplePoint(for: "slice:1", in: map, prefer: .sector), tolerance: 0)
        let legend = map.hitTest(point: samplePoint(for: "slice:1", in: map, prefer: .rectangle), tolerance: 0)
        #expect(first.targets.map(\.id) == ["slice:1"])
        #expect(legend.targets.map(\.id) == ["slice:1"])
        let second = map.hitTest(point: samplePoint(for: "slice:2", in: map, prefer: .sector), tolerance: 0)
        #expect(second.targets.map(\.id) == ["slice:2"])
    }

    @Test func sequenceSelectsParticipantsMessagesAndSelfMessageStroke() throws {
        let source = """
        sequenceDiagram
        participant Alice as 你好
        participant Bob
        Alice->>Alice: loop
        Alice->>Bob: hi
        Alice->>Bob: hi
        """
        let map = try #require(renderedMap(source))
        let alice = try #require(map.target(id: "participant:Alice"))
        #expect(alice.label == "你好" || alice.spans.contains { $0.excerpt.contains("你好") })
        #expect(map.hitTest(point: samplePoint(for: "participant:Alice", in: map), tolerance: 0).targets.map(\.id).contains("participant:Alice"))

        let messages = map.targets.filter { $0.kind == "sequence.message" }
        #expect(messages.count == 3)
        let repeated = messages.filter { $0.label == "hi" }
        #expect(repeated.count == 2)
        #expect(repeated[0].id != repeated[1].id)

        let selfMessage = try #require(messages.first { $0.displayKey.contains("Alice → Alice") })
        guard case .polyline(let points, _) = map.regions.first(where: { $0.targetID == selfMessage.id && isPolyline($0) })?.geometry else {
            Issue.record("Expected self-message polyline")
            return
        }
        #expect(points.count >= 4)
        let interior = CGPoint(
            x: (points[0].x + points[1].x) / 2,
            y: points[0].y + (points[2].y - points[0].y) / 2
        )
        let stroke = CGPoint(x: points[1].x, y: (points[1].y + points[2].y) / 2)
        #expect(map.hitTest(point: interior, tolerance: 0).targets.map(\.id).contains(selfMessage.id) == false)
        #expect(map.hitTest(point: stroke, tolerance: 1).targets.map(\.id).contains(selfMessage.id))
        let labelHit = map.hitTest(point: samplePoint(for: selfMessage.id, in: map, prefer: .rectangle), tolerance: 0)
        #expect(labelHit.targets.map(\.id) == [selfMessage.id])
    }

    @Test func sourceSpansSurviveFrontmatterCommentsBlankLinesAndUnicodeBytes() throws {
        let source = """
        ---
        title: 图表
        ---

        %% comment
        flowchart TD
            A[你好] --> B[End] %% note
        """
        let parsed = MermaidParser().parseAnnotated(source)
        let node = try #require(parsed.ledger.targets.first { $0.id == "node:A" })
        let span = try #require(node.spans.first { $0.role == .declaration })
        #expect(span.excerpt == "A[你好]")
        #expect(span.startLine > 4)
        let bytes = Array(source.utf8)
        let excerpt = String(decoding: bytes[span.startOffset..<span.endOffset], as: UTF8.self)
        #expect(excerpt == "A[你好]")
        #expect(span.endOffset - span.startOffset == "A[你好]".utf8.count)
        #expect(span.endColumn - span.startColumn == span.endOffset - span.startOffset)
        #expect(!span.excerpt.contains("%%"))
        #expect(node.sourceRevision == SemanticSourceRevision.hash(of: source))
        #expect(node.sourceRevision != SemanticSourceRevision.hash(of: source + "\nC"))
    }

    @Test func zoomedToleranceStillHitsAThinEdge() throws {
        let source = """
        flowchart LR
        A[Left] --> B[Right]
        """
        let map = try #require(renderedMap(source))
        let edge = try #require(map.targets.first { $0.kind == "flowchart.edge" })
        guard case .polyline(let points, let width) = map.regions.first(where: { $0.targetID == edge.id && isPolyline($0) })?.geometry else {
            Issue.record("Expected edge polyline")
            return
        }
        let midpoint = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        let screenOffset: CGFloat = 8
        let lowZoom = SemanticCoordinateTransform.layoutTolerance(screenTolerance: screenOffset, zoomScale: 0.5)
        let highZoom = SemanticCoordinateTransform.layoutTolerance(screenTolerance: screenOffset, zoomScale: 4)
        let justOutsideInk = CGPoint(x: midpoint.x, y: midpoint.y + width / 2 + 1)
        let beyondHighZoomSlop = CGPoint(x: midpoint.x, y: midpoint.y + width / 2 + highZoom + 2)
        #expect(map.hitTest(point: justOutsideInk, tolerance: 0).targets.isEmpty)
        #expect(map.hitTest(point: justOutsideInk, tolerance: highZoom).targets.map(\.id).contains(edge.id))
        #expect(map.hitTest(point: beyondHighZoomSlop, tolerance: highZoom).targets.isEmpty)
        #expect(map.hitTest(point: beyondHighZoomSlop, tolerance: lowZoom).targets.map(\.id).contains(edge.id))
        #expect(highZoom < lowZoom)
    }

    @Test func explicitEdgeIDsDoNotCollideWithOrdinalsOrEachOther() throws {
        let laterNumeric = """
        flowchart LR
        A --> B
        C 1@--> D
        """
        let later = MermaidParser().parseAnnotated(laterNumeric).ledger.targets.filter { $0.kind == "flowchart.edge" }
        #expect(later.count == 2)
        #expect(Set(later.map(\.id)).count == 2)
        #expect(later.map(\.id).contains("edge:1") == false)

        let explicitFirst = """
        flowchart LR
        A 2@--> B
        C --> D
        """
        let first = MermaidParser().parseAnnotated(explicitFirst).ledger.targets.filter { $0.kind == "flowchart.edge" }
        #expect(first.count == 2)
        #expect(Set(first.map(\.id)).count == 2)

        let repeated = """
        flowchart LR
        A 1@--> B
        C 1@--> D
        """
        let copies = MermaidParser().parseAnnotated(repeated).ledger.targets.filter { $0.kind == "flowchart.edge" }
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.id)).count == 2)

        let rendered = try #require(renderedMap(laterNumeric))
        let edgeTargets = rendered.targets.filter { $0.kind == "flowchart.edge" }
        #expect(edgeTargets.count == 2)
        #expect(Set(edgeTargets.map(\.id)) == Set(later.map(\.id)))
        for edge in edgeTargets {
            let hit = rendered.hitTest(point: samplePoint(for: edge.id, in: rendered), tolerance: 1)
            #expect(hit.targets.map(\.id).contains(edge.id))
            #expect(hit.targets.filter { $0.kind == "flowchart.edge" }.count == 1)
        }
    }

    @Test func laterExplicitNodeLabelReplacesRawIdentifier() throws {
        let source = """
        flowchart TD
        A --> B[End]
        A[Start]
        """
        let parsed = MermaidParser().parseAnnotated(source)
        let node = try #require(parsed.ledger.targets.first { $0.id == "node:A" })
        #expect(node.label == "Start")
        #expect(node.displayKey == "A")
        #expect(node.spans.contains { $0.role == .declaration && $0.excerpt.contains("A[Start]") })
        let rendered = try #require(renderedMap(source))
        #expect(rendered.target(id: "node:A")?.label == "Start")

        let firstExplicitWins = """
        flowchart TD
        A[Start] --> B
        A[Other]
        """
        let kept = try #require(MermaidParser().parseAnnotated(firstExplicitWins).ledger.targets.first { $0.id == "node:A" })
        #expect(kept.label == "Start")
    }

    @Test func participantLabelsFollowParserInsteadOfLaterAliases() throws {
        let declaredFirst = """
        sequenceDiagram
        participant Alice as 你好
        Alice->>Bob: hi
        """
        let alice = try #require(MermaidParser().parseAnnotated(declaredFirst).ledger.targets.first { $0.id == "participant:Alice" })
        #expect(alice.label == "你好")
        #expect(alice.displayKey == "Alice")

        let referencedFirst = """
        sequenceDiagram
        Alice->>Bob: hi
        participant Alice as 你好
        """
        let firstSeen = try #require(MermaidParser().parseAnnotated(referencedFirst).ledger.targets.first { $0.id == "participant:Alice" })
        #expect(firstSeen.label == "Alice")
        #expect(firstSeen.spans.contains { $0.excerpt.contains("你好") })
    }

    @Test func actorNameAndActivationEndpointsUseDrawnGeometry() throws {
        let actorSource = """
        sequenceDiagram
        actor Alice
        participant Bob
        Alice->>Bob: hi
        """
        let actorMap = try #require(renderedMap(actorSource))
        let actorRects = actorMap.regions.filter { $0.targetID == "participant:Alice" }.map(regionBounds)
        let topY = try #require(actorRects.map(\.minY).min())
        let nameY = topY + config.fontSize * 2.2 + 6
        let namePoint = CGPoint(x: actorRects[0].midX, y: nameY)
        #expect(actorMap.hitTest(point: namePoint, tolerance: 0).targets.map(\.id).contains("participant:Alice"))

        let plain = """
        sequenceDiagram
        participant Alice
        participant Bob
        Alice->>Bob: hi
        """
        let plainMap = try #require(renderedMap(plain))
        let plainEnds = try messageEnds("message:1", in: plainMap)
        let aliceX = try participantMidX("participant:Alice", in: plainMap)
        let bobX = try participantMidX("participant:Bob", in: plainMap)
        #expect(abs(plainEnds.from - aliceX) < 0.75)
        #expect(abs(plainEnds.to - bobX) < 0.75)

        let activated = """
        sequenceDiagram
        participant Alice
        participant Bob
        Alice->>+Bob: hi
        """
        let activatedMap = try #require(renderedMap(activated))
        let ends = try messageEnds("message:1", in: activatedMap)
        let activatedAlice = try participantMidX("participant:Alice", in: activatedMap)
        let activatedBob = try participantMidX("participant:Bob", in: activatedMap)
        let inset = config.fontSize * 0.75 / 2 + 1
        #expect(abs(ends.from - activatedAlice) < 0.75)
        #expect(abs(abs(ends.to - activatedBob) - inset) < 0.75)
        #expect(abs(ends.to - ends.from) < abs(activatedBob - activatedAlice) - 1)
    }

    @Test func flowchartEdgeLabelAndStrokeMatchDrawing() throws {
        let source = """
        flowchart LR
        A[Left] -->|go| B[Right]
        C[One] ==> D[Two]
        """
        let map = try #require(renderedMap(source))
        let labeled = try #require(map.targets.first { $0.kind == "flowchart.edge" && $0.label == "go" })
        let labelRegion = try #require(map.regions.first { $0.targetID == labeled.id && isRectangle($0) })
        let labelBounds = regionBounds(labelRegion)
        let labelTop = CGPoint(x: labelBounds.midX, y: labelBounds.minY + 1)
        #expect(map.hitTest(point: labelTop, tolerance: 0).targets.map(\.id).contains(labeled.id))
        let highZoom = SemanticCoordinateTransform.layoutTolerance(screenTolerance: 12, zoomScale: 4)
        guard case .polyline(let points, let width) = map.regions.first(where: { $0.targetID == labeled.id && isPolyline($0) })?.geometry else {
            Issue.record("Expected labeled edge stroke")
            return
        }
        let midpoint = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        let strokeSlop = width / 2 + highZoom
        if abs(labelTop.y - midpoint.y) > strokeSlop {
            #expect(map.hitTest(point: labelTop, tolerance: highZoom).targets.map(\.id).contains(labeled.id))
        }
        #expect(width == 1.5)

        let thick = try #require(map.targets.first { $0.kind == "flowchart.edge" && $0.displayKey.contains("C → D") })
        guard case .polyline(_, let thickWidth) = map.regions.first(where: { $0.targetID == thick.id && isPolyline($0) })?.geometry else {
            Issue.record("Expected thick edge stroke")
            return
        }
        #expect(thickWidth == 3)
    }

    @Test func shapedNodesMissBoundingBoxCorners() throws {
        let source = """
        flowchart LR
        A([Stadium]) --> B{{Hex}}
        C[(Cylinder)] --> D[/Trapezoid\\]
        """
        let map = try #require(renderedMap(source))
        for id in ["node:A", "node:B", "node:C", "node:D"] {
            let region = try #require(map.regions.first { $0.targetID == id })
            let bounds = regionBounds(region)
            let corner = CGPoint(x: bounds.minX + 0.5, y: bounds.minY + 0.5)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            #expect(map.hitTest(point: center, tolerance: 0).targets.map(\.id).contains(id))
            #expect(map.hitTest(point: corner, tolerance: 0).targets.map(\.id).contains(id) == false)
        }
    }

    @Test func sourceSpansSurviveCRLFUnicodeHeaderFrontmatterAndStatements() throws {
        let source = "---\r\ntitle: 图表 A --> B\r\n---\r\n\r\n%% comment\r\nflowchart TD leftover\r\n    A[你好] --> B[End]; C[Next] --> D[Last] %% note\r\n"
        let parsed = MermaidParser().parseAnnotated(source)
        #expect(parsed.ledger.targets.contains { $0.id == "node:A" && $0.spans.contains { $0.excerpt.contains("A --> B") } } == false)
        let node = try #require(parsed.ledger.targets.first { $0.id == "node:A" })
        let span = try #require(node.spans.first { $0.role == .declaration })
        #expect(span.excerpt == "A[你好]")
        let bytes = Array(source.utf8)
        #expect(String(decoding: bytes[span.startOffset..<span.endOffset], as: UTF8.self) == "A[你好]")
        #expect(span.startLine > 4)
        let next = try #require(parsed.ledger.targets.first { $0.id == "node:C" })
        let nextSpan = try #require(next.spans.first { $0.role == .declaration })
        #expect(nextSpan.excerpt == "C[Next]")
        #expect(nextSpan.startLine == span.startLine)
        #expect(nextSpan.startColumn > span.endColumn)
        #expect(nextSpan.startOffset > span.endOffset)
    }

    @Test func layoutCacheHitKeepsTargetsAndGeometry() {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let source = """
        flowchart TD
        A[One] --> B[Two]
        """
        let config = DocumentRenderPipeline.mermaidConfiguration(theme: .fallback)
        let first = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: source,
            config: config
        )
        let layoutsAfterFirst = DocumentRenderPipeline.debugLayoutCountForTesting
        let second = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: source,
            config: config
        )
        #expect(DocumentRenderPipeline.debugLayoutCountForTesting == layoutsAfterFirst)
        #expect(first.semanticMap == second.semanticMap)
        #expect(first.semanticMap?.targets.contains { $0.id == "node:A" } == true)
        #expect(first.semanticMap?.regions.isEmpty == false)
    }

    @MainActor @Test func outgoingPromptUsesReadableLabelAndSourceWithoutRawIdentity() throws {
        let source = """
        flowchart TD
        A[Start] --> B[End]
        """
        let map = try #require(renderedMap(source))
        let target = try #require(map.target(id: "node:A"))
        let anchor = target.semanticAnchor()
        let comment = ReviewComment(
            id: "c1",
            workspaceId: "w",
            sessionId: "s",
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: "Rename this.",
            attachments: nil,
            reference: ReviewCommentReference(
                source: .file,
                label: "diagram",
                path: "flow.mmd",
                selectedText: target.label,
                semanticAnchor: anchor
            ),
            createdAt: 1,
            updatedAt: 1,
            sentAt: nil
        )
        let block = ReviewCommentStore.reviewBlock(for: [comment])
        #expect(block.contains("Start"))
        #expect(block.contains("**Diagram object:** Start · A"))
        #expect(block.contains("A[Start]"))
        #expect(block.contains("**Source context:**"))
        #expect(!block.contains("node:A"))
        #expect(!block.contains(anchor.sourceRevision))
        #expect(!block.contains("utf8-byte"))
        let stale = anchor.markedStaleAgainst(currentRevision: "different")
        #expect(stale.isStale)
        #expect(stale.targetID == anchor.targetID)
        #expect(stale.spans == anchor.spans)
    }

    @MainActor @Test func pickModeRetainsPanAndPinchWhileBrowseClearsSelection() throws {
        let source = """
        flowchart TD
        A[Start] --> B[End]
        """
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: source,
            config: DocumentRenderPipeline.mermaidConfiguration(theme: .fallback)
        )
        let view = ZoomableGraphicalView(size: layout.size, draw: layout.draw)
        var comments: [String] = []
        view.configureSemanticPick(map: layout.semanticMap) { target in
            comments.append(target.id)
        }
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        view.debugEnterPickForTesting()
        let banner = try #require(view.subviews.first { $0.accessibilityIdentifier == "semantic-pick.banner" })
        #expect(!banner.isHidden)
        #expect(view.debugPickModeEnabledForTesting)
        #expect(view.debugPickScrollEnabledForTesting)
        #expect(view.debugPickPinchEnabledForTesting)
        let point = samplePoint(for: "node:A", in: try #require(layout.semanticMap))
        view.debugSelectForTesting(at: point)
        #expect(view.debugSelectedTargetIDForTesting == "node:A")
        #expect(banner.isHidden)
        view.debugLeavePickForTesting()
        #expect(comments.isEmpty)
        #expect(view.debugPickScrollEnabledForTesting)
        #expect(view.debugSelectedTargetIDForTesting == nil)
    }

    @MainActor @Test func sendPathMarksStaleWhenCurrentSourceHashDiffers() throws {
        let source = """
        flowchart TD
        A[Start] --> B[End]
        """
        let map = try #require(renderedMap(source))
        let target = try #require(map.target(id: "node:A"))
        let comment = ReviewComment(
            id: "c1",
            workspaceId: "w",
            sessionId: "s",
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: "Rename this.",
            attachments: nil,
            reference: ReviewCommentReference(
                source: .timelineText,
                label: "diagram",
                timelineItemId: "item-1",
                semanticAnchor: target.semanticAnchor()
            ),
            createdAt: 1,
            updatedAt: 1,
            sentAt: nil
        )
        let fresh = ReviewCommentStore.reviewBlock(
            for: [comment],
            currentSourceRevision: { _ in target.sourceRevision }
        )
        #expect(fresh.contains("stale") == false)
        #expect(fresh.contains("**Diagram object:** Start · A"))
        let stale = ReviewCommentStore.reviewBlock(
            for: [comment],
            currentSourceRevision: { _ in SemanticSourceRevision.hash(of: source + "\nC") }
        )
        #expect(stale.contains("**Status:** stale"))
        #expect(stale.contains("**Diagram object:** Start · A"))
        #expect(!stale.contains(target.sourceRevision))
        #expect(stale.contains("was not re-anchored"))

        let fence = "```mermaid\n\(source)\n```"
        let changedFence = "```mermaid\nflowchart TD\nA[Changed] --> B[End]\n```"
        let freshItem = SemanticCommentFreshness.currentRevision(
            for: comment,
            timelineItems: [.assistantMessage(id: "item-1", text: fence, timestamp: Date(timeIntervalSince1970: 1))]
        )
        #expect(freshItem == target.sourceRevision)
        let changedItem = SemanticCommentFreshness.currentRevision(
            for: comment,
            timelineItems: [.assistantMessage(id: "item-1", text: changedFence, timestamp: Date(timeIntervalSince1970: 1))]
        )
        #expect(changedItem != nil)
        #expect(changedItem != target.sourceRevision)
    }

    @MainActor @Test func chooserUsesLabelAndControlsMeetHitHeight() throws {
        #expect(SemanticChooserTitle.text(label: "Cats", displayKey: "slice 1") == "Cats · slice 1")
        #expect(SemanticChooserTitle.text(label: "A", displayKey: "A") == "A")
        #expect(SemanticHighlightStyle.lineWidth(for: .polyline(points: [], strokeWidth: 3)) == 3)

        let source = """
        flowchart TD
        A[Start] --> B[End]
        """
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: source,
            config: DocumentRenderPipeline.mermaidConfiguration(theme: .fallback)
        )
        let view = ZoomableGraphicalView(size: layout.size, draw: layout.draw)
        view.configureSemanticPick(map: layout.semanticMap) { _ in }
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        view.debugEnterPickForTesting()
        #expect(view.debugMinimumControlHeightForTesting >= 44)
        let overlapping = SemanticAnnotationMap(
            sourceRevision: "rev",
            targets: [
                SemanticTarget(id: "slice:1", kind: "pie.slice", label: "Cats", displayKey: "slice 1", spans: [], sourceOrigin: .source, sourceRevision: "rev"),
                SemanticTarget(id: "slice:2", kind: "pie.slice", label: "Cats", displayKey: "slice 2", spans: [], sourceOrigin: .source, sourceRevision: "rev"),
            ],
            regions: [
                SemanticRegion(targetID: "slice:1", geometry: .rectangle(CGRect(x: 0, y: 0, width: 40, height: 40)), precedence: 2),
                SemanticRegion(targetID: "slice:2", geometry: .rectangle(CGRect(x: 0, y: 0, width: 40, height: 40)), precedence: 2),
            ]
        )
        view.configureSemanticPick(map: overlapping) { _ in }
        view.debugEnterPickForTesting()
        view.debugSelectForTesting(at: CGPoint(x: 10, y: 10))
        #expect(view.debugChooserTitlesForTesting == ["Cats · slice 1", "Cats · slice 2"] || view.debugChooserTitlesForTesting == ["Cats · slice 2", "Cats · slice 1"])
    }

    @Test func curvedDiamondEdgeUsesTheDrawnQuadraticForHits() throws {
        let source = """
        flowchart TD
        A{Decision} --> B[Left]
        A --> C[Right]
        """
        let map = try #require(renderedMap(source))
        let curved = try #require(map.regions.first { region in
            guard case .strokedPath(let path, _) = region.geometry else { return false }
            return path.elements.contains { element in
                if case .quad = element { return true }
                return false
            }
        })
        guard case .strokedPath(let path, _) = curved.geometry,
              path.elements.count >= 2,
              case .move(let start) = path.elements[0],
              case .quad(let end, let control) = path.elements[1] else {
            Issue.record("Expected one quadratic semantic edge path")
            return
        }
        let highZoomTolerance = SemanticCoordinateTransform.layoutTolerance(screenTolerance: 8, zoomScale: 4)
        for t in [CGFloat(0.2), 0.5, 0.8] {
            let oneMinusT = 1 - t
            let point = CGPoint(
                x: oneMinusT * oneMinusT * start.x + 2 * oneMinusT * t * control.x + t * t * end.x,
                y: oneMinusT * oneMinusT * start.y + 2 * oneMinusT * t * control.y + t * t * end.y
            )
            #expect(map.hitTest(point: point, tolerance: highZoomTolerance).targets.map(\.id).contains(curved.targetID))
        }
        #expect(
            map.hitTest(point: control, tolerance: highZoomTolerance).targets.map(\.id).contains(curved.targetID) == false,
            "The control-polygon corner is not painted by the quadratic"
        )
        let curveMid = CGPoint(
            x: start.x * 0.25 + control.x * 0.5 + end.x * 0.25,
            y: start.y * 0.25 + control.y * 0.5 + end.y * 0.25
        )
        let chordMid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let interior = CGPoint(
            x: (curveMid.x + chordMid.x) / 2,
            y: (curveMid.y + chordMid.y) / 2
        )
        let distanceToCurve = hypot(interior.x - curveMid.x, interior.y - curveMid.y)
        #expect(distanceToCurve > 4, "Quadratic is too flat to prove a chord-interior miss")
        #expect(
            map.hitTest(point: interior, tolerance: 0).targets.map(\.id).contains(curved.targetID) == false,
            "The unpainted region between the quadratic and its chord is not a hit"
        )
    }

    @Test func sequenceMessageLabelUsesActivationAdjustedMidpoint() throws {
        let source = """
        sequenceDiagram
        participant Alice
        participant Bob
        Alice->>+Bob: activate
        Alice->>Bob: adjusted label
        """
        let map = try #require(renderedMap(source))
        guard case .polyline(let points, _) = map.regions.first(where: {
            $0.targetID == "message:2" && isPolyline($0)
        })?.geometry,
        points.count >= 2 else {
            Issue.record("Expected second message stroke")
            return
        }
        let label = try #require(map.regions.first {
            $0.targetID == "message:2" && isRectangle($0)
        })
        let rect = regionBounds(label)
        #expect(abs(rect.midX - (points[0].x + points[1].x) / 2) < 0.01)
    }

    @MainActor @Test func ambiguityChooserKeepsTwentyReachableChoicesOnIPhoneSize() throws {
        let targets = (1...20).map {
            SemanticTarget(
                id: "slice:\($0)",
                kind: "pie.slice",
                label: "Slice \($0)",
                displayKey: "choice \($0)",
                spans: [],
                sourceOrigin: .source,
                sourceRevision: "rev"
            )
        }
        let map = SemanticAnnotationMap(
            sourceRevision: "rev",
            targets: targets,
            regions: targets.map {
                SemanticRegion(
                    targetID: $0.id,
                    geometry: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 40)),
                    precedence: 1
                )
            }
        )
        let view = ZoomableGraphicalView(size: CGSize(width: 300, height: 500), draw: { _, _ in })
        view.configureSemanticPick(map: map) { _ in }
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        view.debugEnterPickForTesting()
        view.debugSelectForTesting(at: CGPoint(x: 20, y: 20))
        view.layoutIfNeeded()

        let chooser = try #require(findView("semantic-pick.chooser-scroll", in: view) as? UIScrollView)
        #expect(chooser.bounds.height > 0)
        #expect(chooser.bounds.height <= 320)
        #expect(chooser.contentSize.height > chooser.bounds.height)
        let first = try #require(findView("semantic-pick.choice.slice:1", in: chooser) as? UIButton)
        let last = try #require(findView("semantic-pick.choice.slice:20", in: chooser) as? UIButton)
        #expect(first.isDescendant(of: chooser))
        chooser.setContentOffset(
            CGPoint(x: 0, y: max(0, chooser.contentSize.height - chooser.bounds.height)),
            animated: false
        )
        chooser.layoutIfNeeded()
        #expect(chooser.contentOffset.y > 0)
        last.sendActions(for: .touchUpInside)
        #expect(view.debugSelectedTargetIDForTesting == "slice:20")
        #expect(view.debugCommentButtonHiddenForTesting == false)
    }

    @MainActor @Test func bothAnchorTypesPersistReloadAndFormatWithoutBreakingLegacyComments() throws {
        let suite = "SemanticAnchorPersistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: suite)
        let controller = ChatReviewCommentsController(store: store)
        controller.load(localScopeId: "workspace", sessionId: "session")
        let source = ReviewCommentSourceContext(
            sessionId: "session",
            surface: .fullScreenSource,
            filePath: "diagram.mmd",
            lineRange: 2...2,
            languageHint: "mermaid"
        )
        let semantic = ReviewCommentSemanticAnchor(
            sourceRevision: "semantic-rev",
            targetID: "node:A",
            kind: "flowchart.node",
            label: "Start",
            displayKey: "A",
            sourceOrigin: .source,
            spans: []
        )
        #expect(controller.save(
            body: "Semantic comment",
            request: ReviewCommentSelectionRequest(selectedText: "Start", source: source, semanticAnchor: semantic),
            localScopeId: "workspace",
            sessionId: "session"
        ) == nil)
        let dom = HTMLDOMElementAnchor(
            sourceSHA256: "dom-rev",
            navigationGeneration: 1,
            sessionId: "session",
            filePath: "page.html",
            readableLabel: "button#save",
            sanitizedText: "Save",
            locatorDescription: "html:0 > body:1 > button:0",
            fingerprint: "fingerprint",
            limitation: nil,
            lookupScope: HTMLDOMElementAnchor.mainFrameAndOpenShadowScope
        )
        #expect(controller.save(
            body: "DOM comment",
            request: ReviewCommentSelectionRequest(selectedText: "button#save", source: source, htmlDOMAnchor: dom),
            localScopeId: "workspace",
            sessionId: "session"
        ) == nil)
        #expect(controller.save(
            body: "Legacy-style comment",
            request: ReviewCommentSelectionRequest(selectedText: "plain", source: source),
            localScopeId: "workspace",
            sessionId: "session"
        ) == nil)

        let reloaded = ReviewCommentStore(defaults: defaults, keyPrefix: suite)
        reloaded.load(workspaceId: "workspace", sessionId: "session")
        #expect(reloaded.stagedComments.count == 3)
        #expect(reloaded.stagedComments[0].reference.semanticAnchor == semantic)
        #expect(reloaded.stagedComments[0].reference.htmlDOMAnchor == nil)
        #expect(reloaded.stagedComments[1].reference.htmlDOMAnchor == dom)
        #expect(reloaded.stagedComments[1].reference.semanticAnchor == nil)
        #expect(reloaded.stagedComments[2].reference.htmlDOMAnchor == nil)
        #expect(reloaded.stagedComments[2].reference.semanticAnchor == nil)
        let outgoing = reloaded.appendReviewBlock(to: "")
        #expect(outgoing.contains("**Diagram object:** Start · A"))
        #expect(outgoing.contains("button#save"))
        #expect(outgoing.contains("Legacy-style comment"))
    }

    @Test func oldReviewCommentsDecodeWithoutSemanticAnchor() throws {
        let json = """
        {"source":"file","path":"a.swift","selectedText":"x"}
        """
        let decoded = try JSONDecoder().decode(ReviewCommentReference.self, from: Data(json.utf8))
        #expect(decoded.semanticAnchor == nil)
        #expect(decoded.path == "a.swift")
        #expect(decoded.selectedText == "x")
    }

    private func renderedMap(_ source: String) -> SemanticAnnotationMap? {
        DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: source,
            config: config
        ).semanticMap
    }

    private enum PreferredGeometry {
        case any
        case sector
        case rectangle
    }

    private func samplePoint(
        for targetID: String,
        in map: SemanticAnnotationMap,
        prefer: PreferredGeometry = .any
    ) -> CGPoint {
        let regions = map.regions.filter { $0.targetID == targetID }
        let region = regions.first { matches($0, prefer) } ?? regions[0]
        switch region.geometry {
        case .rectangle(let rect), .ellipse(let rect):
            return CGPoint(x: rect.midX, y: rect.midY)
        case .sector(let center, let radius, let startAngle, let endAngle):
            let mid = startAngle + (endAngle - startAngle) / 2
            return CGPoint(x: center.x + cos(mid) * radius * 0.5, y: center.y + sin(mid) * radius * 0.5)
        case .polyline(let points, _):
            guard points.count >= 2 else { return points[0] }
            return CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        case .polygon(let points):
            let x = points.map(\.x).reduce(0, +) / CGFloat(points.count)
            let y = points.map(\.y).reduce(0, +) / CGFloat(points.count)
            return CGPoint(x: x, y: y)
        case .path(let path), .strokedPath(let path, _):
            return CGPoint(x: path.bounds.midX, y: path.bounds.midY)
        }
    }

    private func matches(_ region: SemanticRegion, _ prefer: PreferredGeometry) -> Bool {
        switch (prefer, region.geometry) {
        case (.any, _): return true
        case (.sector, .sector): return true
        case (.rectangle, .rectangle): return true
        default: return false
        }
    }

    private func isPolyline(_ region: SemanticRegion) -> Bool {
        if case .polyline = region.geometry { return true }
        return false
    }

    private func isRectangle(_ region: SemanticRegion) -> Bool {
        if case .rectangle = region.geometry { return true }
        return false
    }

    private func regionBounds(_ region: SemanticRegion) -> CGRect {
        switch region.geometry {
        case .rectangle(let rect), .ellipse(let rect):
            return rect
        case .sector(let center, let radius, _, _):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .polyline(let points, _):
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return CGRect(
                x: xs.min() ?? 0,
                y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0)
            )
        case .polygon(let points):
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return CGRect(
                x: xs.min() ?? 0,
                y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0)
            )
        case .path(let path), .strokedPath(let path, _):
            return path.bounds
        }
    }

    private func participantMidX(_ id: String, in map: SemanticAnnotationMap) throws -> CGFloat {
        let region = try #require(map.regions.first { $0.targetID == id && isRectangle($0) })
        return regionBounds(region).midX
    }

    private func messageEnds(_ id: String, in map: SemanticAnnotationMap) throws -> (from: CGFloat, to: CGFloat) {
        guard case .polyline(let points, _) = map.regions.first(where: { $0.targetID == id && isPolyline($0) })?.geometry,
              points.count >= 2 else {
            Issue.record("Expected message polyline for \(id)")
            throw TestMessageGeometryError.missing
        }
        return (points[0].x, points[1].x)
    }

    @MainActor
    private func findView(_ identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for subview in root.subviews {
            if let found = findView(identifier, in: subview) { return found }
        }
        return nil
    }

    private func lineNumber(containing needle: String, in source: String) -> Int {
        let lines = source.components(separatedBy: "\n")
        return (lines.firstIndex { $0.contains(needle) } ?? -1) + 1
    }
}

private enum TestMessageGeometryError: Error {
    case missing
}
