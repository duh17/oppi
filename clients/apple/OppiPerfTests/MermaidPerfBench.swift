import CoreGraphics
import Foundation
import Testing
@testable import Oppi

/// Benchmarks for the Mermaid diagram pipeline:
/// MermaidParser.parse → MermaidFlowchartRenderer.layout → draw
///
/// Covers all four diagram types at small, medium, and large scales.
/// The pipeline runs on a background thread during streaming; any single
/// diagram taking >16ms risks frame drops in the chat timeline.
///
/// Output format: METRIC name=number (microseconds)
/// Budget: <1ms parse, <5ms layout+draw for typical LLM-emitted diagrams.
@Suite("MermaidPerfBench", .tags(.perf))
struct MermaidPerfBench {

    private let parser = MermaidParser()
    private let renderer = MermaidRenderer()
    private let config = RenderConfiguration.default()

    // MARK: - Fixtures

    /// Small flowchart: 5 nodes, 4 edges. Typical LLM "explain this flow" response.
    private static let smallFlowchart = """
    flowchart TD
        A[User Request] --> B{Auth?}
        B -->|Yes| C[Process]
        B -->|No| D[Reject]
        C --> E[Response]
    """

    /// Medium flowchart: 15 nodes, subgraphs, mixed shapes. Typical architecture diagram.
    private static let mediumFlowchart = """
    flowchart LR
        subgraph Client
            A[iOS App] --> B([API Client])
        end
        subgraph Server
            C[WebSocket] --> D{Router}
            D --> E[Auth]
            D --> F[Session]
            D --> G[Workspace]
            F --> H[(Database)]
            F --> I[[Agent Runner]]
            I --> J{{LLM API}}
        end
        subgraph Infra
            K[Tailscale] --> L[WireGuard]
            L --> M((Mesh))
        end
        B --> C
        A --> K
    """

    /// Large flowchart: 30 nodes, deep chains. Stress test.
    private static let largeFlowchart: String = {
        var lines = ["flowchart TD"]
        for i in 0..<30 {
            lines.append("    N\(i)[Node \(i)]")
        }
        for i in 0..<29 {
            lines.append("    N\(i) --> N\(i + 1)")
        }
        // Add some cross-edges
        for i in stride(from: 0, to: 25, by: 5) {
            lines.append("    N\(i) -.-> N\(i + 4)")
        }
        return lines.joined(separator: "\n")
    }()

    /// Sequence diagram: typical LLM "explain this interaction" response.
    private static let mediumSequence = """
    sequenceDiagram
        autonumber
        participant Client
        participant Server
        participant DB
        participant LLM
        Client->>Server: sendPrompt(text)
        activate Server
        Server->>DB: createSession()
        DB-->>Server: session
        Server->>LLM: messages
        loop Streaming
            LLM--)Server: delta
            Server--)Client: delta
        end
        Note over Server,LLM: Streaming complete
        Server->>DB: saveTranscript()
        deactivate Server
        Server-->>Client: done
    """

    /// Large sequence diagram: 8 participants, 20 messages.
    private static let largeSequence: String = {
        var lines = ["sequenceDiagram"]
        let actors = ["Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Heidi"]
        for a in actors {
            lines.append("    participant \(a)")
        }
        for i in 0..<20 {
            let from = actors[i % actors.count]
            let to = actors[(i + 1) % actors.count]
            lines.append("    \(from)->>\(to): Message \(i)")
        }
        lines.append("    Note over Alice,Heidi: Complete")
        return lines.joined(separator: "\n")
    }()

    /// Gantt chart: typical project timeline.
    private static let mediumGantt = """
    gantt
        title Project Plan
        dateFormat YYYY-MM-DD
        axisFormat %m/%d
        tickInterval 1week
        excludes weekends
        section Design
            Research           :done, des1, 2024-01-01, 2024-01-05
            Prototyping        :active, des2, after des1, 5d
            Review             :des3, after des2, 3d
        section Implementation
            Backend            :crit, impl1, after des3, 10d
            Frontend           :impl2, after des3, 8d
            Integration        :impl3, after impl1, 5d
        section Testing
            Unit tests         :test1, after impl2, 5d
            E2E tests          :test2, after impl3, 3d
            Deploy             :milestone, after test2, 0d
    """

    /// Mindmap: typical brainstorm output.
    private static let mediumMindmap = """
    mindmap
        root((Architecture))
            Client
                iOS App
                    SwiftUI
                    UIKit
                Mac App
                    AppKit
            Server
                TypeScript
                    Bun
                    Node
                WebSocket
                Agent Runner
            Infrastructure
                Tailscale
                    WireGuard
                    Mesh
                Docker
                SQLite
    """

    private static let typicalPie = """
    pie title Pets
        \"Dogs\" : 386
        \"Cats\" : 85
        \"Rats\" : 15
    """

    private static let largerPie = """
    pie showData title Slice mix
        \"A\" : 10
        \"B\" : 20
        \"C\" : 15
        \"D\" : 8
        \"E\" : 12
        \"F\" : 9
        \"G\" : 6
        \"H\" : 4
    """

    private static let typicalTimeline = """
    timeline
        title Shipping
        2024 : Design : Build
        2025 : Test : Ship
    """

    private static let largerTimeline = """
    timeline
        title Releases
        2022 : Prototype
        2023 : Alpha : Beta
        2024 : RC : 1.0 : 1.1
        2025 : 1.2 : 1.3 : 2.0
        2026 : Native mermaid : Five families
    """

    private static let typicalClass = """
    classDiagram
        Animal <|-- Duck
        Animal <|-- Fish
        Animal : +int age
        Duck : +swim()
    """

    private static let largerClass = """
    classDiagram
        class Session {
            +String id
            +start()
            +stop()
        }
        class Workspace {
            +String path
        }
        class Agent {
            +run()
        }
        Session --> Workspace : uses
        Session --> Agent : owns
        Agent --> Workspace : reads
        class Tool {
            +name: String
            +call()
        }
        Agent --> Tool : invokes
    """

    private static let typicalER = """
    erDiagram
        CUSTOMER ||--o{ ORDER : places
        ORDER ||--|{ LINE-ITEM : contains
    """

    private static let largerER = """
    erDiagram
        CUSTOMER ||--o{ ORDER : places
        CUSTOMER {
            string name
            string email
        }
        ORDER ||--|{ LINE-ITEM : contains
        ORDER {
            int id
            date created
        }
        PRODUCT ||--o{ LINE-ITEM : listed
        PRODUCT {
            string sku
            float price
        }
    """

    private static let typicalState = """
    stateDiagram-v2
        [*] --> Ready
        Ready --> Running
        Running --> Ready
        Running --> [*]
    """

    private static let largerState = """
    stateDiagram-v2
        [*] --> Idle
        Idle --> Connecting
        Connecting --> Ready
        Ready --> Streaming
        Streaming --> Ready
        Streaming --> Error
        Error --> Idle
        Ready --> [*]
    """

    private static let typicalXY = """
    xychart-beta
        title Score
        x-axis [A, B, C, D]
        y-axis 0 --> 10
        bar [2, 4, 6, 8]
        line [3, 5, 7, 9]
    """

    private static let largerXY = """
    xychart-beta
        title Sprint burn
        x-axis [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        y-axis "n" 0 --> 20
        bar [12, 11, 10, 9, 8, 6, 5, 3, 2, 1]
        line [12, 11, 10, 9, 8, 7, 6, 4, 3, 1]
    """

    private static let typicalGitGraph = """
    gitGraph
        commit id: \"a\"
        commit id: \"b\"
        branch develop
        commit id: \"c\"
        checkout main
        merge develop
    """

    private static let largerGitGraph = """
    gitGraph
        commit id: \"init\"
        branch develop
        commit id: \"wip\"
        commit id: \"fix\" type: HIGHLIGHT
        checkout main
        commit id: \"docs\"
        merge develop id: \"m\" tag: \"v1\"
        branch release
        commit id: \"rc\"
        checkout main
        cherry-pick id: \"fix\"
    """

    private static let typicalQuadrant = """
    quadrantChart
        title Reach
        x-axis Low --> High
        y-axis Low --> High
        Campaign A: [0.3, 0.6]
        Campaign B: [0.7, 0.2]
    """

    private static let largerQuadrant = """
    quadrantChart
        title Reach and engagement of campaigns
        x-axis Low Reach --> High Reach
        y-axis Low Engagement --> High Engagement
        quadrant-1 Expand
        quadrant-2 Promote
        quadrant-3 Re-evaluate
        quadrant-4 Improve
        A: [0.3, 0.6]
        B: [0.45, 0.23]
        C: [0.57, 0.69]
        D: [0.78, 0.34]
        E: [0.40, 0.34]
        F: [0.35, 0.78]
    """

    private static let typicalSankey = """
    sankey
        A,B,20
        B,C,12
        B,D,8
    """

    private static let largerSankey = """
    sankey-beta
        Rendered,Flowchart,10
        Rendered,Sequence,8
        Rendered,Other native,12
        Fallback,Journey,2
        Fallback,C4,5
        Other native,Pie,3
        Other native,Gantt,3
        Other native,Mindmap,3
        Other native,XY,3
    """

    private static let typicalKanban = """
    kanban
        todo[Todo]
            t1[Parse]
        doing[Doing]
            t2[Render]
    """

    private static let largerKanban = """
    kanban
        backlog[Backlog]
            t1[Collect types]@{ ticket: MD-1, priority: 'High', assigned: 'Chen' }
            t2[Check fallback]@{ ticket: MD-2 }
        doing[In progress]
            t3[Steer-test]@{ assigned: 'Chen' }
        review[Review]
            t4[Pinch zoom]
        done[Done]
            t5[Install]@{ ticket: MD-0, priority: 'Low' }
    """

    private static let typicalJourney = """
    journey
        title Day
        section Work
            Make tea: 5: Me
            Do work: 3: Me, Cat
    """

    private static let largerJourney = """
    journey
        title My working day
        section Go to work
            Make tea: 5: Me
            Go upstairs: 3: Me
            Do work: 1: Me, Cat
        section Go home
            Go downstairs: 5: Me
            Sit down: 5: Me
            Sleep: 4: Me
    """

    // MARK: - Parse-only benchmarks

    @Test("Parse — small flowchart (5 nodes)")
    func parseSmallFlowchart() {
        let ns = RendererTestSupport.medianNs {
            RendererTestSupport.consume(parser.parse(Self.smallFlowchart))
        }
        let us = RendererTestSupport.nsToUs(ns)
        print("METRIC mermaid_parse_flowchart_5n_us=\(String(format: "%.1f", us))")
        #expect(us < 500, "Small flowchart parse should be <500us, got \(String(format: "%.1f", us))us")
    }

    @Test("Parse — medium flowchart (15 nodes)")
    func parseMediumFlowchart() {
        let ns = RendererTestSupport.medianNs {
            RendererTestSupport.consume(parser.parse(Self.mediumFlowchart))
        }
        let us = RendererTestSupport.nsToUs(ns)
        print("METRIC mermaid_parse_flowchart_15n_us=\(String(format: "%.1f", us))")
        #expect(us < 1000, "Medium flowchart parse should be <1ms, got \(String(format: "%.1f", us))us")
    }

    @Test("Parse — large flowchart (30 nodes)")
    func parseLargeFlowchart() {
        let ns = RendererTestSupport.medianNs {
            RendererTestSupport.consume(parser.parse(Self.largeFlowchart))
        }
        let us = RendererTestSupport.nsToUs(ns)
        print("METRIC mermaid_parse_flowchart_30n_us=\(String(format: "%.1f", us))")
        #expect(us < 2000, "Large flowchart parse should be <2ms, got \(String(format: "%.1f", us))us")
    }

    @Test("Parse — medium sequence (6 participants, notes, loop)")
    func parseMediumSequence() {
        let ns = RendererTestSupport.medianNs {
            RendererTestSupport.consume(parser.parse(Self.mediumSequence))
        }
        let us = RendererTestSupport.nsToUs(ns)
        print("METRIC mermaid_parse_sequence_6p_us=\(String(format: "%.1f", us))")
        #expect(us < 500, "Medium sequence parse should be <500us, got \(String(format: "%.1f", us))us")
    }

    @Test("Parse — large sequence (8 participants, 20 messages)")
    func parseLargeSequence() {
        let ns = RendererTestSupport.medianNs {
            RendererTestSupport.consume(parser.parse(Self.largeSequence))
        }
        let us = RendererTestSupport.nsToUs(ns)
        print("METRIC mermaid_parse_sequence_8p_us=\(String(format: "%.1f", us))")
        #expect(us < 1000, "Large sequence parse should be <1ms, got \(String(format: "%.1f", us))us")
    }

    @Test("Parse — medium gantt (3 sections, 9 tasks)")
    func parseMediumGantt() {
        let ns = RendererTestSupport.medianNs {
            RendererTestSupport.consume(parser.parse(Self.mediumGantt))
        }
        let us = RendererTestSupport.nsToUs(ns)
        print("METRIC mermaid_parse_gantt_9t_us=\(String(format: "%.1f", us))")
        #expect(us < 500, "Medium gantt parse should be <500us, got \(String(format: "%.1f", us))us")
    }

    @Test("Parse — medium mindmap (15 nodes)")
    func parseMediumMindmap() {
        let ns = RendererTestSupport.medianNs {
            RendererTestSupport.consume(parser.parse(Self.mediumMindmap))
        }
        let us = RendererTestSupport.nsToUs(ns)
        print("METRIC mermaid_parse_mindmap_15n_us=\(String(format: "%.1f", us))")
        #expect(us < 500, "Medium mindmap parse should be <500us, got \(String(format: "%.1f", us))us")
    }

    // MARK: - Full pipeline benchmarks (parse + layout + draw)

    @Test("Pipeline — small flowchart (5 nodes)")
    func pipelineSmallFlowchart() {
        RendererTestSupport.benchParseAndRender(
            parser: parser,
            renderer: renderer,
            input: Self.smallFlowchart,
            config: config,
            prefix: "mermaid",
            label: "flowchart_5n",
            totalBudgetUs: 5000
        )
    }

    @Test("Pipeline — medium flowchart (15 nodes)")
    func pipelineMediumFlowchart() {
        RendererTestSupport.benchParseAndRender(
            parser: parser,
            renderer: renderer,
            input: Self.mediumFlowchart,
            config: config,
            prefix: "mermaid",
            label: "flowchart_15n",
            totalBudgetUs: 10000
        )
    }

    @Test("Pipeline — large flowchart (30 nodes)")
    func pipelineLargeFlowchart() {
        RendererTestSupport.benchParseAndRender(
            parser: parser,
            renderer: renderer,
            input: Self.largeFlowchart,
            config: config,
            prefix: "mermaid",
            label: "flowchart_30n",
            totalBudgetUs: 16000
        )
    }

    @Test("Pipeline — medium sequence diagram")
    func pipelineMediumSequence() {
        RendererTestSupport.benchParseAndRender(
            parser: parser,
            renderer: renderer,
            input: Self.mediumSequence,
            config: config,
            prefix: "mermaid",
            label: "sequence_6p",
            totalBudgetUs: 5000
        )
    }

    @Test("Pipeline — large sequence diagram")
    func pipelineLargeSequence() {
        RendererTestSupport.benchParseAndRender(
            parser: parser,
            renderer: renderer,
            input: Self.largeSequence,
            config: config,
            prefix: "mermaid",
            label: "sequence_8p",
            totalBudgetUs: 10000
        )
    }

    @Test("Pipeline — medium gantt chart")
    func pipelineMediumGantt() {
        RendererTestSupport.benchParseAndRender(
            parser: parser,
            renderer: renderer,
            input: Self.mediumGantt,
            config: config,
            prefix: "mermaid",
            label: "gantt_9t",
            totalBudgetUs: 5000
        )
    }

    @Test("Pipeline — medium mindmap")
    func pipelineMediumMindmap() {
        RendererTestSupport.benchParseAndRender(
            parser: parser,
            renderer: renderer,
            input: Self.mediumMindmap,
            config: config,
            prefix: "mermaid",
            label: "mindmap_15n",
            totalBudgetUs: 5000
        )
    }

    // MARK: - Remaining native families (typical parse + larger pipeline)

    @Test("Parse — typical pie")
    func parseTypicalPie() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalPie, prefix: "mermaid",
            label: "pie_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger pie")
    func pipelineLargerPie() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerPie,
            config: config, prefix: "mermaid", label: "pie_larger", totalBudgetUs: 5000
        )
    }

    @Test("Parse — typical timeline")
    func parseTypicalTimeline() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalTimeline, prefix: "mermaid",
            label: "timeline_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger timeline")
    func pipelineLargerTimeline() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerTimeline,
            config: config, prefix: "mermaid", label: "timeline_larger", totalBudgetUs: 5000
        )
    }

    @Test("Parse — typical class")
    func parseTypicalClass() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalClass, prefix: "mermaid",
            label: "class_typical", budgetUs: 1000
        )
    }

    @Test("Pipeline — larger class")
    func pipelineLargerClass() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerClass,
            config: config, prefix: "mermaid", label: "class_larger", totalBudgetUs: 10000
        )
    }

    @Test("Parse — typical er")
    func parseTypicalER() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalER, prefix: "mermaid",
            label: "er_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger er")
    func pipelineLargerER() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerER,
            config: config, prefix: "mermaid", label: "er_larger", totalBudgetUs: 10000
        )
    }

    @Test("Parse — typical state")
    func parseTypicalState() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalState, prefix: "mermaid",
            label: "state_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger state")
    func pipelineLargerState() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerState,
            config: config, prefix: "mermaid", label: "state_larger", totalBudgetUs: 10000
        )
    }

    @Test("Parse — typical xychart")
    func parseTypicalXY() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalXY, prefix: "mermaid",
            label: "xychart_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger xychart")
    func pipelineLargerXY() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerXY,
            config: config, prefix: "mermaid", label: "xychart_larger", totalBudgetUs: 5000
        )
    }

    @Test("Parse — typical gitGraph")
    func parseTypicalGitGraph() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalGitGraph, prefix: "mermaid",
            label: "gitgraph_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger gitGraph")
    func pipelineLargerGitGraph() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerGitGraph,
            config: config, prefix: "mermaid", label: "gitgraph_larger", totalBudgetUs: 5000
        )
    }

    @Test("Parse — typical quadrantChart")
    func parseTypicalQuadrant() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalQuadrant, prefix: "mermaid",
            label: "quadrant_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger quadrantChart")
    func pipelineLargerQuadrant() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerQuadrant,
            config: config, prefix: "mermaid", label: "quadrant_larger", totalBudgetUs: 5000
        )
    }

    @Test("Parse — typical sankey")
    func parseTypicalSankey() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalSankey, prefix: "mermaid",
            label: "sankey_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger sankey")
    func pipelineLargerSankey() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerSankey,
            config: config, prefix: "mermaid", label: "sankey_larger", totalBudgetUs: 5000
        )
    }

    @Test("Parse — typical kanban")
    func parseTypicalKanban() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalKanban, prefix: "mermaid",
            label: "kanban_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger kanban")
    func pipelineLargerKanban() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerKanban,
            config: config, prefix: "mermaid", label: "kanban_larger", totalBudgetUs: 5000
        )
    }

    @Test("Parse — typical journey")
    func parseTypicalJourney() {
        RendererTestSupport.benchParse(
            parser: parser, input: Self.typicalJourney, prefix: "mermaid",
            label: "journey_typical", budgetUs: 500
        )
    }

    @Test("Pipeline — larger journey")
    func pipelineLargerJourney() {
        RendererTestSupport.benchParseAndRender(
            parser: parser, renderer: renderer, input: Self.largerJourney,
            config: config, prefix: "mermaid", label: "journey_larger", totalBudgetUs: 5000
        )
    }

    @Test("Pipeline cache — 1pt width retry does not reparse")
    func pipelineCachedWidthRetryDoesNotReparse() {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let source = Self.smallFlowchart
        let base = RenderConfiguration(
            fontSize: 13,
            maxWidth: 320,
            theme: config.theme,
            displayMode: .inline
        )
        let retry = RenderConfiguration(
            fontSize: 13,
            maxWidth: 321,
            theme: config.theme,
            displayMode: .inline
        )
        #expect(
            DocumentRenderPipeline.renderInlineGraphicalImage(
                parser: parser,
                renderer: renderer,
                text: source,
                config: base
            ) != nil
        )
        let parses = DocumentRenderPipeline.debugParseCountForTesting
        #expect(parses == 1)

        let start = DispatchTime.now().uptimeNanoseconds
        let retried = DocumentRenderPipeline.renderInlineGraphicalImage(
            parser: parser,
            renderer: renderer,
            text: source,
            config: retry
        )
        let us = RendererTestSupport.nsToUs(
            Double(DispatchTime.now().uptimeNanoseconds &- start)
        )
        print("METRIC mermaid_pipeline_width_retry_us=\(String(format: "%.1f", us))")
        #expect(retried != nil)
        #expect(
            DocumentRenderPipeline.debugParseCountForTesting == parses,
            "1 pt width retry must reuse the cached Mermaid AST"
        )
    }
}
