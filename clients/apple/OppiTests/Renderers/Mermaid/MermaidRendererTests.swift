import CoreGraphics
import CoreText
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

    @Test func markdownNodeBoxUsesFormattedWidth() {
        let markdown = parser.parse("""
        flowchart TD
          M["`**bold** and _italic_`"]
        """)
        let formatted = parser.parse("""
        flowchart TD
          M[bold and italic]
        """)
        let rawMarkers = parser.parse("""
        flowchart TD
          M["**bold** and _italic_"]
        """)
        let markdownWidth = renderer.layout(markdown, configuration: config).graphResult.nodePositions["M"]?.width ?? 0
        let formattedWidth = renderer.layout(formatted, configuration: config).graphResult.nodePositions["M"]?.width ?? 0
        let rawWidth = renderer.layout(rawMarkers, configuration: config).graphResult.nodePositions["M"]?.width ?? 0
        #expect(
            abs(markdownWidth - formattedWidth) < abs(markdownWidth - rawWidth),
            "Markdown box \(markdownWidth) should be closer to formatted \(formattedWidth) than raw markers \(rawWidth)"
        )
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
                    if edgeEntersOrLeaves(path, subgraph: frame, positions: layout.graphResult.nodePositions) {
                        continue
                    }
                    #expect(
                        !segmentIntersectsInterior(first, second, rect: titleBand),
                        "Edge \(path.from)->\(path.to) crosses unrelated subgraph title \(subgraphId)"
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

    // MARK: - Shared trunks and subgraph entry

    static let denseFanOutFanIn = """
        flowchart TD
            Root[Session event stream] --> Decode[Decode protocol envelope]
            Decode --> Type{Event type}

            Type --> Message[Message delta]
            Type --> Tool[Tool lifecycle]
            Type --> Ask[Ask request]
            Type --> Goal[Goal update]
            Type --> Metrics[Usage metrics]
            Type --> Files[Changed files]
            Type --> Status[Session status]
            Type --> Error[Recoverable error]

            Message --> Reduce[Timeline reducer]
            Tool --> Reduce
            Ask --> Reduce
            Goal --> Reduce
            Metrics --> Reduce
            Files --> Reduce
            Status --> Reduce
            Error --> Reduce

            Reduce --> Snapshot[Observable session snapshot]
            Snapshot --> Chat[Chat timeline]
            Snapshot --> Dock[Extension dock]
            Snapshot --> Sidebar[Workspace sidebar]
            Snapshot --> Activity[Live Activity]
        """

    static let subgraphEntryFlowchart = """
        flowchart TD
            Start([Incoming request]) --> Validate{Payload valid?}

            subgraph Gateway [API Gateway]
                Validate -->|yes| Authenticate[Authenticate token]
                Validate -->|no| Reject[Return 400 with validation details]
                Authenticate --> Authorized{Authorized?}
                Authorized -->|no| Deny[Return 403]
            end

            subgraph Processing [Background processing]
                Authorized -->|yes| Queue[Enqueue durable job]
                Queue --> WorkerA[Worker A]
                Queue --> WorkerB[Worker B]
                WorkerA --> Merge[Combine partial results]
                WorkerB --> Merge
                Merge --> Success{Persisted successfully?}
                Success -->|no — retry with exponential backoff| Queue
            end

            Success -->|yes| Notify[Send notification 🔔]
            Notify --> Done([Complete])
            Reject --> Done
            Deny --> Done
        """

    @Test func denseFanOutSharesTrunkNearEndpoints() {
        let layout = renderer.layout(parser.parse(Self.denseFanOutFanIn), configuration: config)
        let fanIds = ["Message", "Tool", "Ask", "Goal", "Metrics", "Files", "Status", "Error"]
        let paths = layout.graphResult.edgePaths.filter { $0.from == "Type" && fanIds.contains($0.to) }
        #expect(paths.count == 8)
        #expect(paths.allSatisfy { $0.points.count >= 2 })

        guard let source = layout.graphResult.nodePositions["Type"],
              let trunk = sharedOverlappingTrunk(of: paths, horizontal: true)
        else {
            Issue.record("Expected a shared overlapping horizontal trunk from Event type")
            return
        }
        let busY = trunk.coord
        let targetTop = fanIds.compactMap { layout.graphResult.nodePositions[$0]?.minY }.min() ?? source.maxY
        #expect(busY > source.maxY + 2, "Trunk must leave the source before splitting, busY=\(busY) source=\(source)")
        #expect(busY < targetTop - 2, "Trunk must split near the targets, busY=\(busY) targetTop=\(targetTop)")
        #expect(
            trunk.overlap.upperBound - trunk.overlap.lowerBound >= 0,
            "Fan-out trunk segments must share an overlapping interval, overlap=\(trunk.overlap)"
        )

        for path in paths {
            guard let target = layout.graphResult.nodePositions[path.to] else { continue }
            #expect(abs((path.points.last?.x ?? 0) - target.midX) < 1.2)
            #expect(abs((path.points.last?.y ?? 0) - target.minY) < 1.2)
        }
    }

    @Test func denseFanInSharesTrunkNearDestination() {
        let layout = renderer.layout(parser.parse(Self.denseFanOutFanIn), configuration: config)
        let fanIds = ["Message", "Tool", "Ask", "Goal", "Metrics", "Files", "Status", "Error"]
        let paths = layout.graphResult.edgePaths.filter { fanIds.contains($0.from) && $0.to == "Reduce" }
        #expect(paths.count == 8)

        guard let dest = layout.graphResult.nodePositions["Reduce"],
              let trunk = sharedOverlappingTrunk(of: paths, horizontal: true)
        else {
            Issue.record("Expected a shared overlapping horizontal trunk into Timeline reducer")
            return
        }
        let busY = trunk.coord
        let sourceBottom = fanIds.compactMap { layout.graphResult.nodePositions[$0]?.maxY }.max() ?? dest.minY
        #expect(busY > sourceBottom + 2, "Fan-in trunk must leave sources before merging, busY=\(busY)")
        #expect(busY < dest.minY - 2, "Fan-in trunk must merge near the destination, busY=\(busY) dest=\(dest)")
        #expect(paths.allSatisfy { abs(($0.points.last?.x ?? 0) - dest.midX) < 1.2 })
    }

    @Test func unrelatedEdgesStayIndependentlyRouted() {
        let diagram = parser.parse("""
            flowchart TD
                Source[Source] --> One[One]
                Source --> Two[Two]
                Other[Other] --> Lonely[Lonely]
            """)
        let layout = renderer.layout(diagram, configuration: config)
        let related = layout.graphResult.edgePaths.filter { $0.from == "Source" }
        let unrelated = layout.graphResult.edgePaths.first { $0.from == "Other" && $0.to == "Lonely" }
        #expect(related.count == 2)
        #expect(unrelated != nil)
        guard let unrelated, let trunk = sharedOverlappingTrunk(of: related, horizontal: true) else {
            Issue.record("Expected related overlapping trunk and unrelated edge")
            return
        }
        let busY = trunk.coord
        let relatedXs = related.flatMap { horizontalSegmentXs(at: busY, path: $0) }
        let unrelatedXs = horizontalSegmentXs(at: busY, path: unrelated)
        let relatedSpan = (relatedXs.min() ?? 0)...(relatedXs.max() ?? 0)
        let overlapsTrunk = unrelatedXs.contains { relatedSpan.contains($0) }
        #expect(
            !overlapsTrunk,
            "Unrelated Other->Lonely must not ride Source's shared trunk at y=\(busY)"
        )
        #expect(Set(related.map { $0.points.description }).count == 2)
        #expect(unrelated.points != related[0].points)
    }

    @Test func subgraphEntryDoesNotDetourAroundTitle() {
        let layout = renderer.layout(parser.parse(Self.subgraphEntryFlowchart), configuration: config)
        guard let gateway = layout.subgraphFrames["Gateway"],
              let start = layout.graphResult.nodePositions["Start"],
              let validate = layout.graphResult.nodePositions["Validate"],
              let path = layout.graphResult.edgePaths.first(where: { $0.from == "Start" && $0.to == "Validate" })
        else {
            Issue.record("Expected Gateway entry edge")
            return
        }
        #expect(path.points.count >= 2, "Entry edge must remain visible")
        let pathMinX = path.points.map(\.x).min() ?? 0
        let pathMaxX = path.points.map(\.x).max() ?? 0
        #expect(
            pathMinX > gateway.minX - 8 && pathMaxX < gateway.maxX + 8,
            "Start->Validate detoured around Gateway (path x=\(pathMinX)...\(pathMaxX), frame=\(gateway))"
        )
        let manhattan = abs(validate.midX - start.midX) + abs(validate.minY - start.maxY)
        #expect(
            pathLength(path) < manhattan * 2.2 + gateway.width * 0.35,
            "Entry edge took a perimeter route, length=\(pathLength(path)) manhattan=\(manhattan)"
        )
        let titleBand = CGRect(
            x: gateway.minX,
            y: gateway.minY,
            width: gateway.width,
            height: min(config.fontSize * 1.7 + 4, gateway.height)
        )
        let crossesTitle = zip(path.points, path.points.dropFirst()).contains { first, second in
            segmentCrossesBand(first, second, rect: titleBand)
        }
        #expect(
            crossesTitle || path.points.contains { titleBand.insetBy(dx: 1, dy: 1).contains($0) },
            "Direct subgraph entry should cross the title band instead of skirting it"
        )
    }

    @Test func mixedRankFanOutDoesNotShareATrunk() {
        let layout = renderer.layout(
            parser.parse("""
                flowchart TD
                    A[Source] --> NearL[Near left]
                    A --> NearR[Near right]
                    NearL --> Far[Far]
                    A --> Far
            """),
            configuration: config
        )
        let near = layout.graphResult.edgePaths.filter {
            $0.from == "A" && ($0.to == "NearL" || $0.to == "NearR")
        }
        let far = layout.graphResult.edgePaths.first { $0.from == "A" && $0.to == "Far" }
        #expect(near.count == 2)
        guard let far, let trunk = sharedOverlappingTrunk(of: near, horizontal: true) else {
            Issue.record("Expected same-rank fan-out trunk")
            return
        }
        let farAtBus = axisSegmentRange(far, horizontal: true, coord: trunk.coord)
        let overlaps = farAtBus.map { rangesOverlap($0, trunk.overlap) } ?? false
        #expect(
            !overlaps,
            "Mixed-rank A->Far must not ride the near-rank trunk at y=\(trunk.coord) overlap=\(trunk.overlap)"
        )
    }

    @Test func mixedRankFanInDoesNotShareATrunk() {
        let layout = renderer.layout(
            parser.parse("""
                flowchart TD
                    Far[Far] --> MidL[Mid left]
                    Far --> MidR[Mid right]
                    MidL --> Sink[Sink]
                    MidR --> Sink
                    Far --> Sink
            """),
            configuration: config
        )
        let near = layout.graphResult.edgePaths.filter {
            ($0.from == "MidL" || $0.from == "MidR") && $0.to == "Sink"
        }
        let far = layout.graphResult.edgePaths.first { $0.from == "Far" && $0.to == "Sink" }
        #expect(near.count == 2)
        guard let far, let trunk = sharedOverlappingTrunk(of: near, horizontal: true) else {
            Issue.record("Expected same-rank fan-in trunk")
            return
        }
        let farAtBus = axisSegmentRange(far, horizontal: true, coord: trunk.coord)
        let overlaps = farAtBus.map { rangesOverlap($0, trunk.overlap) } ?? false
        #expect(
            !overlaps,
            "Mixed-rank Far->Sink must not ride the mid-rank fan-in trunk at y=\(trunk.coord)"
        )
    }

    @Test func nestedSubgraphDirectionUsesLocalTrunkAxis() {
        let layout = renderer.layout(
            parser.parse("""
                flowchart TD
                    subgraph cluster [Cluster]
                        direction LR
                        B[Begin] --> C[Child C]
                        B --> D[Child D]
                        C --> E[End]
                        D --> E
                    end
            """),
            configuration: config
        )
        let fanOut = layout.graphResult.edgePaths.filter {
            $0.from == "B" && ($0.to == "C" || $0.to == "D")
        }
        let fanIn = layout.graphResult.edgePaths.filter {
            ($0.from == "C" || $0.from == "D") && $0.to == "E"
        }
        #expect(fanOut.count == 2)
        #expect(fanIn.count == 2)
        let verticalOut = sharedOverlappingTrunk(of: fanOut, horizontal: false)
        let verticalIn = sharedOverlappingTrunk(of: fanIn, horizontal: false)
        #expect(verticalOut != nil, "LR nested fan-out should share a vertical trunk, paths=\(fanOut.map(\.points))")
        #expect(verticalIn != nil, "LR nested fan-in should share a vertical trunk, paths=\(fanIn.map(\.points))")
        if let verticalOut {
            #expect(
                verticalOut.overlap.upperBound - verticalOut.overlap.lowerBound > 8,
                "LR nested fan-out trunk must have a real vertical overlap, overlap=\(verticalOut.overlap)"
            )
        }
    }

    @Test func labeledFanOutAndFanInKeepLabelAndArrowheadClearance() {
        let layout = renderer.layout(
            parser.parse("""
                flowchart TD
                    A[Source] -->|left| L[Left]
                    A -->|center| C[Center]
                    A -->|right| R[Right]
                    L -->|in-L| Z[Sink]
                    C -->|in-C| Z
                    R -->|in-R| Z
            """),
            configuration: config
        )
        let fanOut = layout.graphResult.edgePaths.filter { $0.from == "A" }
        let fanIn = layout.graphResult.edgePaths.filter { $0.to == "Z" }
        #expect(fanOut.count == 3)
        #expect(fanIn.count == 3)
        #expect(sharedOverlappingTrunk(of: fanOut, horizontal: true) != nil)
        #expect(sharedOverlappingTrunk(of: fanIn, horizontal: true) != nil)

        assertEveryPathClearsOtherLabelsAndArrowheads(layout, among: fanOut, expectedLabelCount: 3)
        assertEveryPathClearsOtherLabelsAndArrowheads(layout, among: fanIn, expectedLabelCount: 3)
        assertEveryPathClearsOtherLabelsAndArrowheads(layout)
    }

    @Test func laterUnlabeledSharedRoutesClearEarlierLabelsAndArrowheads() {
        let layout = renderer.layout(
            parser.parse("""
                flowchart TD
                    A[Source] -->|one| T1[One]
                    A -->|two| T2[Two]
                    A --> T3[Three]
                    A --> T4[Four]
                    T1 -->|in-1| Z[Sink]
                    T2 -->|in-2| Z
                    T3 --> Z
                    T4 --> Z
            """),
            configuration: config
        )
        let fanOut = layout.graphResult.edgePaths.filter { $0.from == "A" }
        let fanIn = layout.graphResult.edgePaths.filter { $0.to == "Z" }
        #expect(fanOut.count == 4)
        #expect(fanIn.count == 4)
        let unlabeledFanOut = fanOut.filter { $0.to == "T3" || $0.to == "T4" }
        let unlabeledFanIn = fanIn.filter { $0.from == "T3" || $0.from == "T4" }
        #expect(unlabeledFanOut.count == 2)
        #expect(unlabeledFanIn.count == 2)
        #expect(
            sharedOverlappingTrunk(of: unlabeledFanOut, horizontal: true) != nil,
            "Unlabeled same-rank fan-out must still share a trunk"
        )
        #expect(
            sharedOverlappingTrunk(of: unlabeledFanIn, horizontal: true) != nil,
            "Unlabeled same-rank fan-in must still share a trunk"
        )
        assertEveryPathClearsOtherLabelsAndArrowheads(layout, expectedLabelCount: 4)
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

    private struct OverlappingTrunk {
        let coord: CGFloat
        let overlap: ClosedRange<CGFloat>
    }

    private func sharedOverlappingTrunk(
        of paths: [GraphLayoutEdgePath],
        horizontal: Bool
    ) -> OverlappingTrunk? {
        guard let first = paths.first else { return nil }
        for candidate in axisSegments(first, horizontal: horizontal) {
            let ranges = paths.compactMap { path -> ClosedRange<CGFloat>? in
                axisSegments(path, horizontal: horizontal)
                    .first { abs($0.coord - candidate.coord) < 1 }?
                    .range
            }
            guard ranges.count == paths.count, let overlap = connectedUnion(ranges) else { continue }
            return OverlappingTrunk(coord: candidate.coord, overlap: overlap)
        }
        return nil
    }

    private func axisSegments(
        _ path: GraphLayoutEdgePath,
        horizontal: Bool
    ) -> [(coord: CGFloat, range: ClosedRange<CGFloat>)] {
        zip(path.points, path.points.dropFirst()).compactMap { first, second in
            if horizontal {
                guard abs(first.y - second.y) < 0.6, abs(first.x - second.x) > 2 else { return nil }
                return (first.y, ClosedRange(uncheckedBounds: (min(first.x, second.x), max(first.x, second.x))))
            }
            guard abs(first.x - second.x) < 0.6, abs(first.y - second.y) > 2 else { return nil }
            return (first.x, ClosedRange(uncheckedBounds: (min(first.y, second.y), max(first.y, second.y))))
        }
    }

    private func connectedUnion(_ ranges: [ClosedRange<CGFloat>]) -> ClosedRange<CGFloat>? {
        guard !ranges.isEmpty else { return nil }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var start = sorted[0].lowerBound
        var end = sorted[0].upperBound
        for range in sorted.dropFirst() {
            if range.lowerBound > end + 0.5 { return nil }
            start = min(start, range.lowerBound)
            end = max(end, range.upperBound)
        }
        return start...end
    }

    private func axisSegmentRange(
        _ path: GraphLayoutEdgePath,
        horizontal: Bool,
        coord: CGFloat
    ) -> ClosedRange<CGFloat>? {
        axisSegments(path, horizontal: horizontal).first { abs($0.coord - coord) < 1 }?.range
    }

    private func rangesOverlap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
        a.lowerBound <= b.upperBound + 0.5 && b.lowerBound <= a.upperBound + 0.5
    }

    private func horizontalSegmentXs(at y: CGFloat, path: GraphLayoutEdgePath) -> [CGFloat] {
        guard let range = axisSegmentRange(path, horizontal: true, coord: y) else { return [] }
        return [range.lowerBound, range.upperBound]
    }

    private struct EdgeDecoration {
        let path: GraphLayoutEdgePath
        let label: String?
        let labelRect: CGRect?
        let arrowRect: CGRect
    }

    private func assertEveryPathClearsOtherLabelsAndArrowheads(
        _ layout: MermaidFlowchartRenderer.FlowchartLayout,
        among paths: [GraphLayoutEdgePath]? = nil,
        expectedLabelCount: Int? = nil
    ) {
        let decorations = layout.graphResult.edgePaths.enumerated().compactMap { index, path -> EdgeDecoration? in
            guard path.points.count >= 2 else { return nil }
            if let paths, !paths.contains(where: {
                $0.from == path.from && $0.to == path.to && $0.points == path.points
            }) {
                return nil
            }
            let key = index < layout.edgeKeys.count ? layout.edgeKeys[index] : "\(path.from)->\(path.to)"
            let label = layout.edgeLabels[key]
            return EdgeDecoration(
                path: path,
                label: label,
                labelRect: label.map {
                    edgeLabelRect(
                        $0,
                        path: path,
                        fontSize: layout.fontSize,
                        among: layout.graphResult.edgePaths
                    )
                },
                arrowRect: arrowheadRect(path, fontSize: layout.fontSize)
            )
        }
        if let expectedLabelCount {
            #expect(decorations.compactMap(\.label).count == expectedLabelCount)
        }
        for (index, decoration) in decorations.enumerated() {
            if let label = decoration.label, let rect = decoration.labelRect {
                #expect(
                    !rect.intersects(decoration.arrowRect.insetBy(dx: -1, dy: -1)),
                    "Label '\(label)' overlaps arrowhead of \(decoration.path.from)->\(decoration.path.to)"
                )
                for (nodeId, nodeRect) in layout.graphResult.nodePositions
                    where nodeId != decoration.path.from && nodeId != decoration.path.to {
                    #expect(
                        !rect.intersects(nodeRect.insetBy(dx: 2, dy: 2)),
                        "Label '\(label)' overlaps node \(nodeId)"
                    )
                }
            }
            for (otherIndex, other) in decorations.enumerated() where otherIndex != index {
                if let label = other.label, let rect = other.labelRect {
                    #expect(
                        !pathCrossesInterior(decoration.path, rect: rect),
                        "Path \(decoration.path.from)->\(decoration.path.to) crosses label '\(label)' of \(other.path.from)->\(other.path.to)"
                    )
                    if let ownRect = decoration.labelRect {
                        #expect(
                            !ownRect.intersects(rect.insetBy(dx: 1, dy: 1)),
                            "Labels overlap at \(ownRect) vs \(rect)"
                        )
                    }
                }
                let tip = decoration.path.points.last ?? .zero
                let otherTip = other.path.points.last ?? .zero
                let sameDestinationTip = abs(tip.x - otherTip.x) < 0.6 && abs(tip.y - otherTip.y) < 0.6
                if !sameDestinationTip {
                    #expect(
                        !pathCrossesInterior(decoration.path, rect: other.arrowRect),
                        "Path \(decoration.path.from)->\(decoration.path.to) crosses arrowhead of \(other.path.from)->\(other.path.to)"
                    )
                }
            }
        }
    }

    private func pathCrossesInterior(_ path: GraphLayoutEdgePath, rect: CGRect) -> Bool {
        zip(path.points, path.points.dropFirst()).contains {
            segmentCrossesInterior($0.0, $0.1, rect: rect)
        }
    }

    private func segmentCrossesInterior(_ first: CGPoint, _ second: CGPoint, rect: CGRect) -> Bool {
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
        return segmentCrossesBand(first, second, rect: rect)
    }

    private func edgeLabelRect(
        _ text: String,
        path: GraphLayoutEdgePath,
        fontSize: CGFloat,
        among others: [GraphLayoutEdgePath]
    ) -> CGRect {
        let anchor = labelAnchor(on: path, fontSize: fontSize, among: others)
        let labelFontSize = fontSize * 0.85
        let font = CTFontCreateWithName("Helvetica" as CFString, labelFontSize, nil)
        let textSize = MermaidTextUtils.measureText(text, font: font, fontSize: labelFontSize)
        return CGRect(
            x: anchor.x - textSize.width / 2 - 3,
            y: anchor.y - textSize.height / 2 - 2,
            width: textSize.width + 6,
            height: textSize.height + 4
        )
    }

    private func labelAnchor(
        on path: GraphLayoutEdgePath,
        fontSize: CGFloat,
        among others: [GraphLayoutEdgePath]
    ) -> CGPoint {
        let points = path.points
        guard points.count >= 2 else { return .zero }
        let tip = points[points.count - 1]
        let prev = points[points.count - 2]
        let lastDX = tip.x - prev.x
        let lastDY = tip.y - prev.y
        let lastLen = hypot(lastDX, lastDY)
        let inset = max(fontSize * 1.7, 22)
        let peers = others.filter {
            $0.from != path.from || $0.to != path.to || $0.points != path.points
        }
        if points.count >= 3 {
            let firstLen = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
            let firstShared = peers.filter {
                pathSharesSegment($0, from: points[0], to: points[1])
            }.count
            let lastShared = peers.filter {
                pathSharesSegment($0, from: prev, to: tip)
            }.count
            if lastLen > 8, firstShared > lastShared {
                if lastLen > inset + 4 {
                    let t = 1 - inset / lastLen
                    return CGPoint(x: prev.x + lastDX * t, y: prev.y + lastDY * t)
                }
                return CGPoint(x: (prev.x + tip.x) / 2, y: (prev.y + tip.y) / 2)
            }
            if firstLen > 8, lastShared > firstShared {
                return CGPoint(
                    x: (points[0].x + points[1].x) / 2,
                    y: (points[0].y + points[1].y) / 2
                )
            }
            let candidates = zip(points, points.dropFirst()).dropLast()
            if let best = candidates.max(by: {
                hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) < hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
            }) {
                let length = hypot(best.1.x - best.0.x, best.1.y - best.0.y)
                if length > 8 {
                    return CGPoint(x: (best.0.x + best.1.x) / 2, y: (best.0.y + best.1.y) / 2)
                }
            }
        }
        if lastLen > inset + 4 {
            let t = 1 - inset / lastLen
            return CGPoint(x: prev.x + lastDX * t, y: prev.y + lastDY * t)
        }
        return CGPoint(x: (prev.x + tip.x) / 2, y: (prev.y + tip.y) / 2)
    }

    private func pathSharesSegment(
        _ path: GraphLayoutEdgePath,
        from first: CGPoint,
        to second: CGPoint
    ) -> Bool {
        let epsilon: CGFloat = 0.6
        return zip(path.points, path.points.dropFirst()).contains { start, end in
            if abs(first.y - second.y) < epsilon,
               abs(start.y - end.y) < epsilon,
               abs(first.y - start.y) < epsilon {
                return max(first.x, second.x) > min(start.x, end.x) + 1
                    && min(first.x, second.x) < max(start.x, end.x) - 1
            }
            if abs(first.x - second.x) < epsilon,
               abs(start.x - end.x) < epsilon,
               abs(first.x - start.x) < epsilon {
                return max(first.y, second.y) > min(start.y, end.y) + 1
                    && min(first.y, second.y) < max(start.y, end.y) - 1
            }
            return false
        }
    }

    private func arrowheadRect(_ path: GraphLayoutEdgePath, fontSize: CGFloat) -> CGRect {
        let size = fontSize * 0.6
        let tip = path.points.last ?? .zero
        return CGRect(x: tip.x - size, y: tip.y - size, width: size * 2, height: size * 2)
    }

    private func pathLength(_ path: GraphLayoutEdgePath) -> CGFloat {
        zip(path.points, path.points.dropFirst()).reduce(0) {
            $0 + abs($1.0.x - $1.1.x) + abs($1.0.y - $1.1.y)
        }
    }

    private func segmentCrossesBand(_ first: CGPoint, _ second: CGPoint, rect: CGRect) -> Bool {
        let samples = max(4, Int(hypot(second.x - first.x, second.y - first.y) / 2))
        for step in 1..<samples {
            let t = CGFloat(step) / CGFloat(samples)
            let point = CGPoint(
                x: first.x + (second.x - first.x) * t,
                y: first.y + (second.y - first.y) * t
            )
            if point.x > rect.minX + 0.1 && point.x < rect.maxX - 0.1
                && point.y > rect.minY + 0.1 && point.y < rect.maxY - 0.1 {
                return true
            }
        }
        return false
    }

    private func edgeEntersOrLeaves(
        _ path: GraphLayoutEdgePath,
        subgraph: CGRect,
        positions: [String: CGRect]
    ) -> Bool {
        guard let from = positions[path.from], let to = positions[path.to] else { return false }
        let fromInside = subgraph.insetBy(dx: 1, dy: 1).contains(CGPoint(x: from.midX, y: from.midY))
        let toInside = subgraph.insetBy(dx: 1, dy: 1).contains(CGPoint(x: to.midX, y: to.midY))
        return fromInside != toInside
    }
}
