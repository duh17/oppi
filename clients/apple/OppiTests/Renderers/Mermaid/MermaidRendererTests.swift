import CoreGraphics
import Testing
@testable import Oppi

/// Tests for the Mermaid flowchart renderer.
///
/// Validates layout integration with Sugiyama and drawing correctness.
@Suite("Mermaid Renderer")
struct MermaidRendererTests {
    let parser = MermaidParser()
    let renderer = MermaidRenderer()
    let config = RenderConfiguration.default(maxWidth: 600)

    // MARK: - Layout integration

    @Test func twoNodeGraph() {
        let diagram = parser.parse("flowchart TD\n    A --> B")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(!layout.isPlaceholder)
        #expect(layout.graphResult.nodePositions.count == 2)

        let a = layout.graphResult.nodePositions["A"]!
        let b = layout.graphResult.nodePositions["B"]!
        #expect(a.midY < b.midY) // A above B
        #expect(!a.intersects(b)) // No overlap
    }

    @Test func threeNodeChainLayering() {
        let diagram = parser.parse("flowchart TD\n    A --> B\n    B --> C")
        let layout = renderer.layout(diagram, configuration: config)
        let positions = layout.graphResult.nodePositions
        #expect(positions.count == 3)

        let a = positions["A"]!
        let b = positions["B"]!
        let c = positions["C"]!
        #expect(a.midY < b.midY)
        #expect(b.midY < c.midY)
    }

    @Test func diamondPatternLayers() {
        let source = """
            flowchart TD
                A --> B
                A --> C
                B --> D
                C --> D
            """
        let diagram = parser.parse(source)
        let layout = renderer.layout(diagram, configuration: config)
        let positions = layout.graphResult.nodePositions
        #expect(positions.count == 4)

        let a = positions["A"]!
        let b = positions["B"]!
        let c = positions["C"]!
        let d = positions["D"]!

        #expect(a.midY < b.midY)
        #expect(abs(b.midY - c.midY) < 1) // Same layer
        #expect(b.midY < d.midY)
    }

    @Test func leftToRightDirection() {
        let diagram = parser.parse("flowchart LR\n    A --> B")
        let layout = renderer.layout(diagram, configuration: config)
        let positions = layout.graphResult.nodePositions

        let a = positions["A"]!
        let b = positions["B"]!
        #expect(a.midX < b.midX) // A left of B
    }

    @Test func edgePathsPresent() {
        let diagram = parser.parse("flowchart TD\n    A --> B")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.graphResult.edgePaths.count == 1)
        #expect(layout.graphResult.edgePaths[0].from == "A")
        #expect(layout.graphResult.edgePaths[0].to == "B")
        #expect(layout.graphResult.edgePaths[0].points.count >= 2)
    }

    @Test func cycleDoesNotCrash() {
        let diagram = parser.parse("flowchart TD\n    A --> B\n    B --> A")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.graphResult.nodePositions.count == 2)
    }

    @Test func emptyFlowchart() {
        let diagram = parser.parse("flowchart TD")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.graphResult.totalSize == .zero)
    }

    @Test func singleNode() {
        let diagram = parser.parse("flowchart TD\n    A[Hello]")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.graphResult.nodePositions.count == 1)
        let a = layout.graphResult.nodePositions["A"]!
        #expect(a.width > 0)
        #expect(a.height > 0)
    }

    @Test func subgraphBoundingBoxIncludesContainerMargins() {
        let diagram = parser.parse("""
            flowchart TD
                subgraph group [Group]
                    A[Alpha] --> B[Beta]
                end
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let box = renderer.boundingBox(layout)
        let frame = layout.subgraphFrames["group"]

        #expect(frame != nil)
        #expect(box.width > (frame?.width ?? 0))
        #expect(box.height > (frame?.height ?? 0))
    }

    @Test func nestedSubgraphsStayDisjointAndRouteUsingChildDirection() {
        let diagram = parser.parse("""
            flowchart TB
                subgraph outer [Outer]
                    subgraph left [Left]
                        direction LR
                        A[Alpha] --> B[Beta]
                    end
                    subgraph right [Right]
                        C[Gamma] --> D[Delta]
                    end
                end
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let positions = layout.graphResult.nodePositions

        #expect(layout.subgraphFrames["left"] != nil)
        #expect(layout.subgraphFrames["right"] != nil)
        #expect(layout.subgraphFrames["left"]?.intersects(layout.subgraphFrames["right"]!) == false)
        #expect(positions["A"]!.midX < positions["B"]!.midX)

        let path = layout.graphResult.edgePaths.first { $0.from == "A" && $0.to == "B" }
        #expect(path?.points.first?.x == positions["A"]?.maxX)
        #expect(path?.points.last?.x == positions["B"]?.minX)
        #expect(path?.points.first?.y == positions["A"]?.midY)
        #expect(path?.points.last?.y == positions["B"]?.midY)
    }

    @Test func nestedChildDirectionIsIgnoredWhenMemberLinksOutside() {
        let diagram = parser.parse("""
            flowchart TB
                outside[Outside] --> A
                subgraph outer [Outer]
                    subgraph child [Child]
                        direction LR
                        A[Alpha] --> B[Beta]
                    end
                end
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let positions = layout.graphResult.nodePositions

        #expect(positions["A"]!.midY < positions["B"]!.midY)
        let path = layout.graphResult.edgePaths.first { $0.from == "A" && $0.to == "B" }
        #expect(path?.points.first?.x == positions["A"]?.midX)
        #expect(path?.points.last?.x == positions["B"]?.midX)
        #expect(path?.points.first?.y == positions["A"]?.maxY)
        #expect(path?.points.last?.y == positions["B"]?.minY)
    }

    @Test func architectureGraphKeepsTopLevelSubgraphsDisjoint() {
        let diagram = parser.parse("""
            graph TD
              Client[Apple clients]
              Terminal[Terminal Pi extension]
              CLI[Local oppi CLI]

              subgraph Entry[Server entry]
                Root[server.ts<br/>composition root]
              end

              subgraph Boundaries[Boundary adapters]
                LocalHTTP[HTTP over Unix socket<br/>owner-only local control plane]
                REST[Network REST routes<br/>routes/*]
                AppEvents[Global app event stream<br/>app-event-stream.ts]
                Live[Focused session and audio streams<br/>stream.ts + ws-message-handler.ts]
                MirrorWS[Mirror bridge WS<br/>/mirror/v1/bridge]
              end

              subgraph Services[Application services]
                Lifecycle[SessionLifecycleService]
                Lists[SessionListService]
                Trace[SessionTraceService]
                PiModel[PiModelAuthService]
                AgentLaunch[AgentLaunchService]
                ScheduleRunner[AgentScheduleRunner]
              end

              subgraph Runtime[Session runtime]
                Router[SessionRuntimes<br/>runtime-router.ts]
                Sessions[SessionManager<br/>sessions.ts]
                Mirror[PiTuiMirrorRuntime<br/>pi-tui-mirror-runtime.ts]
                Flow[session-* coordinators]
                Project[Shared Pi session projection<br/>session-events.ts + session-agent-events.ts<br/>+ session-protocol.ts]
                Pi[Pi SDK bridge<br/>sdk-backend.ts]
              end

              subgraph ReadModel[Read models and catalogs]
                Sqlite[session-sqlite-store.ts]
                LocalCatalog[local-sessions.ts]
              end

              subgraph Infrastructure[Shared infrastructure]
                ExtensionRelay[Extension UI relay<br/>sdk-ui-bridge.ts]
                Ops[Search, metrics,<br/>push, live activity]
              end

              Client --> Root
              Terminal --> Root
              CLI --> LocalHTTP
              LocalHTTP --> Root
              Root --> REST
              Root --> AppEvents
              Root --> Live
              Root --> MirrorWS
              REST --> Lifecycle
              REST --> Lists
              REST --> Trace
              REST --> AppEvents
              REST --> AgentLaunch
              ScheduleRunner --> AgentLaunch
              Live --> Lifecycle
              Lifecycle --> Router
              Lifecycle --> Sessions
              Lists --> Sqlite
              Lists --> LocalCatalog
              Trace --> Sqlite
              Trace --> LocalCatalog
              Project --> PiModel
              Live --> Router
              MirrorWS --> Mirror
              Router --> Sessions
              Router --> Mirror
              Sessions --> Flow
              Flow --> Project
              Mirror --> Project
              Flow --> Pi
              AgentLaunch --> Sessions
              AgentLaunch --> AppEvents
              Sessions --> AppEvents
              Mirror --> AppEvents
              Sessions --> ExtensionRelay
              Sessions --> Ops
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let expectedSubgraphs = [
            "Entry", "Boundaries", "Services", "Runtime", "ReadModel", "Infrastructure",
        ]
        let frames = expectedSubgraphs.compactMap { layout.subgraphFrames[$0] }

        #expect(frames.count == expectedSubgraphs.count)
        for firstIndex in frames.indices {
            for secondIndex in frames.indices where secondIndex > firstIndex {
                #expect(
                    !frames[firstIndex].intersects(frames[secondIndex]),
                    "Top-level Mermaid subgraphs must not overlap: \(expectedSubgraphs[firstIndex]) and \(expectedSubgraphs[secondIndex])"
                )
            }
        }

        func segmentIntersectsInterior(_ first: CGPoint, _ second: CGPoint, rect: CGRect) -> Bool {
            let epsilon: CGFloat = 0.1
            if abs(first.y - second.y) < epsilon {
                return first.y > rect.minY + epsilon && first.y < rect.maxY - epsilon
                    && max(first.x, second.x) > rect.minX + epsilon
                    && min(first.x, second.x) < rect.maxX - epsilon
            }
            if abs(first.x - second.x) < epsilon {
                return first.x > rect.minX + epsilon && first.x < rect.maxX - epsilon
                    && max(first.y, second.y) > rect.minY + epsilon
                    && min(first.y, second.y) < rect.maxY - epsilon
            }
            return true
        }

        for path in layout.graphResult.edgePaths {
            #expect(path.points.count >= 2, "Architecture edge \(path.from)->\(path.to) must remain visible")
            let unrelatedNodes = layout.graphResult.nodePositions.filter {
                $0.key != path.from && $0.key != path.to
            }
            if path.points.count >= 2,
               let sourceRect = layout.graphResult.nodePositions[path.from],
               let targetRect = layout.graphResult.nodePositions[path.to] {
                #expect(
                    !segmentIntersectsInterior(path.points[0], path.points[1], rect: sourceRect),
                    "Edge \(path.from)->\(path.to) reverses through its source"
                )
                #expect(
                    !segmentIntersectsInterior(
                        path.points[path.points.count - 2],
                        path.points[path.points.count - 1],
                        rect: targetRect
                    ),
                    "Edge \(path.from)->\(path.to) reverses through its target"
                )
            }
            for (first, second) in zip(path.points, path.points.dropFirst()) {
                for (nodeId, rect) in unrelatedNodes {
                    #expect(
                        !segmentIntersectsInterior(first, second, rect: rect),
                        "Edge \(path.from)->\(path.to) crosses unrelated node \(nodeId)"
                    )
                }
                for (subgraphId, frame) in layout.subgraphFrames {
                    let titleBand = CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: frame.width,
                        height: min(config.fontSize * 1.7 + 4, frame.height)
                    )
                    #expect(
                        !segmentIntersectsInterior(first, second, rect: titleBand),
                        "Edge \(path.from)->\(path.to) crosses subgraph title \(subgraphId)"
                    )
                }
            }
        }

        let box = renderer.boundingBox(layout)
        #expect(box.width > 0)
        #expect(box.height > 0)
        #expect(box.width <= config.maxWidth * 2)

        let phoneInlineConfig = RenderConfiguration(
            fontSize: 13,
            maxWidth: 390,
            theme: config.theme,
            displayMode: .inline
        )
        let phoneInlineLayout = renderer.layout(diagram, configuration: phoneInlineConfig)
        let phoneInlineBox = renderer.boundingBox(phoneInlineLayout)
        let inlinePixelCountAt2x = phoneInlineBox.width * phoneInlineBox.height * 4
        #expect(phoneInlineBox.width <= phoneInlineConfig.maxWidth * 2.5)
        #expect(inlinePixelCountAt2x <= 8_000_000)
    }

    @Test func subgraphEndpointClippingStaysOrthogonal() {
        let diagram = parser.parse("""
            flowchart LR
                before[Before] --> group
                group --> after[After]
                subgraph group [Asymmetric group title]
                    direction TB
                    A[Alpha] --> B[Beta with a longer label]
                end
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let frame = layout.subgraphFrames["group"]!
        let incoming = layout.graphResult.edgePaths.first { $0.from == "before" }!
        let outgoing = layout.graphResult.edgePaths.first { $0.to == "after" }!

        func liesOnBoundary(_ point: CGPoint, of rect: CGRect) -> Bool {
            abs(point.x - rect.minX) < 0.1 || abs(point.x - rect.maxX) < 0.1
                || abs(point.y - rect.minY) < 0.1 || abs(point.y - rect.maxY) < 0.1
        }
        func isOrthogonal(_ path: GraphLayoutEdgePath) -> Bool {
            zip(path.points, path.points.dropFirst()).allSatisfy {
                abs($0.0.x - $0.1.x) < 0.1 || abs($0.0.y - $0.1.y) < 0.1
            }
        }

        #expect(liesOnBoundary(incoming.points.last!, of: frame))
        #expect(liesOnBoundary(outgoing.points.first!, of: frame))
        #expect(isOrthogonal(incoming))
        #expect(isOrthogonal(outgoing))
    }

    @Test func directionalPortsDoNotReverseThroughEndpointNodes() {
        for direction in ["TB", "BT", "LR", "RL"] {
            let diagram = parser.parse("flowchart \(direction)\n A[Alpha] --> B[Beta]")
            let layout = renderer.layout(diagram, configuration: config)
            let path = layout.graphResult.edgePaths[0]
            let source = layout.graphResult.nodePositions["A"]!
            let target = layout.graphResult.nodePositions["B"]!

            func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
                CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
            }
            #expect(!source.contains(midpoint(path.points[0], path.points[1])))
            #expect(!target.contains(midpoint(
                path.points[path.points.count - 2],
                path.points[path.points.count - 1]
            )))
        }

        let cycle = renderer.layout(
            parser.parse("flowchart TB\n A[Alpha] --> B[Beta]\n B --> A"),
            configuration: config
        )
        let backedge = cycle.graphResult.edgePaths.first { $0.from == "B" && $0.to == "A" }!
        #expect(backedge.points[1].y < backedge.points[0].y)
        #expect(backedge.points[backedge.points.count - 2].y > backedge.points.last!.y)
    }

    @Test func parallelEdgesUseSeparateRoutes() {
        let diagram = parser.parse("""
            flowchart TB
                A[Alpha] e1@--> B[Beta]
                A e2@--> B
                A e3@--> B
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let paths = layout.graphResult.edgePaths

        #expect(paths.count == 3)
        #expect(Set(paths.map { $0.points.description }).count == 3)
        #expect(paths.allSatisfy { $0.points.first == paths[0].points.first })
        #expect(paths.allSatisfy { $0.points.last == paths[0].points.last })
    }

    @Test func emptySubgraphEdgePreservesFollowingMetadataAlignment() {
        let diagram = parser.parse("""
            flowchart TB
                empty --> A[Alpha]
                subgraph empty [Empty]
                end
                A e1@-->|one| B[Beta]
                A e2@==>|two| B
            """)
        let layout = renderer.layout(diagram, configuration: config)

        #expect(layout.graphResult.edgePaths.count == 3)
        #expect(layout.edgeKeys.count == layout.graphResult.edgePaths.count)
        #expect(layout.graphResult.edgePaths[0].points.isEmpty)
        #expect(layout.edgeKeys == ["empty->A#0", "A->B#1", "A->B#2"])
        #expect(layout.edgeLabels[layout.edgeKeys[1]] == "one")
        #expect(layout.edgeLabels[layout.edgeKeys[2]] == "two")
        #expect(layout.edgeStyles[layout.edgeKeys[1]] == .arrow)
        #expect(layout.edgeStyles[layout.edgeKeys[2]] == .thick)
    }

    @Test func longOuterEdgeLabelExpandsBounds() {
        let diagram = parser.parse("""
            flowchart TB
                A[Alpha] -->|This is a deliberately very long outer edge label that must not clip| B[Beta]
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let nodeWidth = layout.graphResult.nodePositions.values
            .reduce(CGRect.null) { $0.union($1) }
            .width
        let box = renderer.boundingBox(layout)

        #expect(box.width > nodeWidth + 200)
    }

    // MARK: - Render output

    @Test func renderProducesNonZeroSize() {
        let diagram = parser.parse("flowchart TD\n    A --> B")
        let output = renderer.render(diagram, configuration: config)
        guard case .graphical(let result) = output else {
            Issue.record("Expected graphical output")
            return
        }
        #expect(result.boundingBox.width > 0)
        #expect(result.boundingBox.height > 0)
    }

    @Test func drawDoesNotCrash() {
        let diagram = parser.parse("""
            flowchart TD
                A[Rectangle] --> B(Rounded)
                B --> C([Stadium])
                C --> D{Diamond}
                D --> E{{Hexagon}}
                E --> F((Circle))
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let box = renderer.boundingBox(layout)

        // Create a bitmap context and draw into it.
        let ctx = CGContext(
            data: nil,
            width: Int(box.width),
            height: Int(box.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Should not crash.
        renderer.draw(layout, in: ctx, at: .zero)
    }

    // MARK: - All node shapes

    @Test func allShapesRender() {
        let shapes: [(String, String)] = [
            ("A[Rectangle]", "rectangle"),
            ("B(Rounded)", "rounded"),
            ("C([Stadium])", "stadium"),
            ("D{Diamond}", "diamond"),
            ("E{{Hexagon}}", "hexagon"),
            ("F((Circle))", "circle"),
            ("G[(Cylindrical)]", "cylindrical"),
            ("H[[Subroutine]]", "subroutine"),
            ("I>Asymmetric]", "asymmetric"),
        ]

        for (node, shapeName) in shapes {
            let diagram = parser.parse("flowchart TD\n    \(node)")
            let layout = renderer.layout(diagram, configuration: config)
            #expect(!layout.isPlaceholder, "Shape \(shapeName) should not produce placeholder")
            #expect(layout.graphResult.nodePositions.count == 1,
                    "Shape \(shapeName) should have one positioned node")
        }
    }

    // MARK: - Edge styles

    @Test func allEdgeStylesRender() {
        let source = """
            flowchart TD
                A -->|arrow| B
                B --- C
                C -.-> D
                D ==> E
            """
        let diagram = parser.parse(source)
        let layout = renderer.layout(diagram, configuration: config)

        // All edges should be present.
        #expect(layout.graphResult.edgePaths.count == 4)

        // Arrow edge label should be captured.
        #expect(layout.edgeLabels["A->B"] == "arrow")
    }

    // MARK: - Style directives

    @Test func styleDirectivesCaptured() {
        let source = """
            flowchart TD
                A[Node] --> B[Other]
                style A fill:#f9f,stroke:#333
            """
        let diagram = parser.parse(source)
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.styleDirectives["A"]?["fill"] == "#f9f")
        #expect(layout.styleDirectives["A"]?["stroke"] == "#333")
    }

    @Test func classDefCaptured() {
        let source = """
            flowchart TD
                A[Node]:::highlight --> B[Other]
                classDef highlight fill:#ff0,stroke:#000
            """
        let diagram = parser.parse(source)
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.classDefs["highlight"]?["fill"] == "#ff0")
    }

    // MARK: - Sequence diagram placeholder

    @Test func sequenceDiagramRendersWithoutCrash() {
        let diagram = parser.parse("sequenceDiagram\n    A->>B: Hello")
        let layout = renderer.layout(diagram, configuration: config)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func unsupportedDiagramPlaceholder() {
        let diagram = parser.parse("journey\n    title Test")
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.isPlaceholder)
        #expect(layout.placeholderText?.contains("journey") == true)
    }

    // MARK: - Pie / timeline / class / ER dispatch

    @Test func pieDiagramRendersThroughSharedDispatcher() {
        let source = """
            pie title Pets adopted by volunteers
                "Dogs" : 386
                "Cats" : 85
                "Rats" : 15
            """
        let diagram = parser.parse(source)
        guard case .pie = diagram else {
            Issue.record("Expected pie diagram, got \(diagram)")
            return
        }
        let layout = renderer.layout(diagram, configuration: config)
        #expect(!layout.isPlaceholder)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func timelineDiagramRendersThroughSharedDispatcher() {
        let source = """
            timeline
            title History of Social Media Platform
            2002 : LinkedIn
            2004 : Facebook
                 : Google
            2005 : YouTube
            2006 : Twitter
            """
        let diagram = parser.parse(source)
        guard case .timeline = diagram else {
            Issue.record("Expected timeline diagram, got \(diagram)")
            return
        }
        let layout = renderer.layout(diagram, configuration: config)
        #expect(!layout.isPlaceholder)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func classDiagramRendersThroughSharedDispatcher() {
        let source = """
            classDiagram
                class Animal
                Vehicle <|-- Car
            """
        let diagram = parser.parse(source)
        guard case .classDiagram = diagram else {
            Issue.record("Expected classDiagram, got \(diagram)")
            return
        }
        let layout = renderer.layout(diagram, configuration: config)
        #expect(!layout.isPlaceholder)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func erDiagramRendersThroughSharedDispatcher() {
        let source = """
            erDiagram
                CUSTOMER ||--o{ ORDER : places
                ORDER ||--|{ LINE-ITEM : contains
                CUSTOMER }|..|{ DELIVERY-ADDRESS : uses
            """
        let diagram = parser.parse(source)
        guard case .erDiagram = diagram else {
            Issue.record("Expected erDiagram, got \(diagram)")
            return
        }
        let layout = renderer.layout(diagram, configuration: config)
        #expect(!layout.isPlaceholder)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    // MARK: - Render with complex diagram

    @Test func complexDiagramDoesNotCrash() {
        let source = """
            flowchart TD
                Start[Start] --> Decision{Is it?}
                Decision -->|Yes| Action1([Do thing])
                Decision -->|No| Action2([Do other])
                Action1 --> End((End))
                Action2 --> End
                style Start fill:#0f0,stroke:#000
                style End fill:#f00,stroke:#000
            """
        let diagram = parser.parse(source)
        let output = renderer.render(diagram, configuration: config)
        guard case .graphical(let result) = output else {
            Issue.record("Expected graphical output")
            return
        }
        #expect(result.boundingBox.width > 0)
        #expect(result.boundingBox.height > 0)

        // Draw it.
        let ctx = CGContext(
            data: nil,
            width: max(1, Int(result.boundingBox.width)),
            height: max(1, Int(result.boundingBox.height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        result.draw(ctx, .zero)
    }
}
