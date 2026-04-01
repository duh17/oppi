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
    private let renderer = MermaidFlowchartRenderer()
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
}
