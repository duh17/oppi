#if DEBUG
import Foundation
import SwiftUI

// MARK: - Mermaid Rendering Preview

struct MermaidRenderingPreview: View {
    private struct Diagram: Identifiable {
        let id: String
        let heading: String
        let markdown: String
    }

    private static let diagrams: [Diagram] = [
        Diagram(
            id: "state-fanout",
            heading: "State fan-out",
            markdown: #"""
            ```mermaid
            stateDiagram-v2
                [*] --> Unset : no asr.backend
                Unset --> ModuleReady : backend=module and model on disk
                Unset --> HttpReady : backend=http and endpoint null or /transcribe
                Unset --> ModuleMissing : backend=module, no model
                HttpReady --> PhoneOn : identity.dictationStream
                ModuleReady --> PhoneOn : identity.dictationStream
                ModuleMissing --> PhoneOff : iOS on-device only
            ```
            """#
        ),
        Diagram(
            id: "flowchart-labels",
            heading: "Flowchart labels",
            markdown: #"""
            ```mermaid
            flowchart TD
              subgraph "`**Labels**`"
                Q["text with (parens) and *stars*"]
                M["`**bold** and _italic_`"]
                E["quote:#quot; amp:#amp;"]
                U["Café — 日本語 — emoji ✅"]
                Q --> M
                M -- "`**edge**`" --> E
                E --> U
              end
            ```
            """#
        ),
        Diagram(
            id: "flowchart",
            heading: "Flowchart",
            markdown: #"""
            ```mermaid
            flowchart TD
                subgraph Review [Code review]
                    PR[Open PR] --> Decision{Approved?}
                    Decision -->|no| Fix[Fix comments]
                    Fix --> PR
                    Decision -->|yes| Checks
                end
                subgraph Pipeline [CI]
                    Checks[Run CI] --> Lint[Lint]
                    Checks --> Tests[Tests]
                    Lint --> Merge[Merge]
                    Tests --> Merge
                end
            ```
            """#
        ),
        Diagram(
            id: "sequence",
            heading: "Sequence",
            markdown: #"""
            ```mermaid
            sequenceDiagram
                Alice->>+John: Hello John, how are you?
                Note over Alice,John: A typical interaction
                alt is sick
                    John->>Alice: Not so good
                    Note right of John: Needs rest
                else is well
                    John-->>-Alice: Feeling fresh like a daisy
                    Note left of Alice: All good
                end
            ```
            """#
        ),
        Diagram(
            id: "state",
            heading: "State",
            markdown: #"""
            ```mermaid
            stateDiagram-v2
                [*] --> Ready
                Ready --> Working : start
                Working --> Ready : finish
                Working --> [*] : cancel
            ```
            """#
        ),
        Diagram(
            id: "gantt",
            heading: "Gantt",
            markdown: #"""
            ```mermaid
            gantt
                title Shipping schedule
                section Build
                    Parser :done, parser, 2026-08-01, 3d
                    Renderer :active, renderer, after parser, 4d
                section Ship
                    Validate :validate, after renderer, 2d
            ```
            """#
        ),
        Diagram(
            id: "mindmap",
            heading: "Mindmap",
            markdown: #"""
            ```mermaid
            mindmap
                root((Oppi))
                    Apple
                        Timeline
                        Files
                    Server
                        Sessions
                        Tools
            ```
            """#
        ),
        Diagram(
            id: "timeline",
            heading: "Timeline",
            markdown: #"""
            ```mermaid
            timeline
                title History of Social Media Platform
                2002 : LinkedIn
                2004 : Facebook
                     : Google
                2005 : YouTube
                2006 : Twitter
            ```
            """#
        ),
        Diagram(
            id: "pie",
            heading: "Pie",
            markdown: #"""
            ```mermaid
            pie showData title Pets adopted by volunteers
                "Dogs" : 386
                "Cats" : 85
                "Rats" : 15
            ```
            """#
        ),
        Diagram(
            id: "xy",
            heading: "XY",
            markdown: #"""
            ```mermaid
            xychart-beta
                title Oracle issues remaining (crash counted as 10)
                x-axis [B, 1, 2, 3, 4, 5, 6, 7, 8]
                y-axis "issues" 0 --> 10
                bar [10, 9, 9, 9, 6, 1, 0, 0, 0]
                line [10, 9, 9, 9, 6, 1, 0, 0, 0]
            ```
            """#
        ),
        Diagram(
            id: "class",
            heading: "Class",
            markdown: #"""
            ```mermaid
            classDiagram
                class BankAccount
                BankAccount : +String owner
                BankAccount : +BigDecimal balance
                BankAccount : +deposit(amount)
                BankAccount : +withdrawal(amount)
            ```
            """#
        ),
        Diagram(
            id: "er",
            heading: "ER",
            markdown: #"""
            ```mermaid
            erDiagram
                CUSTOMER ||--o{ ORDER : places
                ORDER ||--|{ LINE-ITEM : contains
            ```
            """#
        ),
        Diagram(
            id: "gitgraph",
            heading: "Git graph",
            markdown: #"""
            ```mermaid
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
            ```
            """#
        ),
        Diagram(
            id: "quadrant",
            heading: "Quadrant",
            markdown: #"""
            ```mermaid
            quadrantChart
              title Reach and engagement of campaigns
              x-axis Low Reach --> High Reach
              y-axis Low Engagement --> High Engagement
              quadrant-1 We should expand
              quadrant-2 Need to promote
              quadrant-3 Re-evaluate
              quadrant-4 May be improved
              Campaign A: [0.3, 0.6]
              Campaign B: [0.45, 0.23]
              Campaign C: [0.57, 0.69]
              Campaign D: [0.78, 0.34]
            ```
            """#
        ),
        Diagram(
            id: "sankey",
            heading: "Sankey",
            markdown: #"""
            ```mermaid
            sankey-beta
              Rendered,Flowchart,10
              Rendered,Sequence,8
              Rendered,Other native,12
              Fallback,Journey,2
              Fallback,Kanban,3
              Other native,Pie,3
              Other native,Gantt,3
            ```
            """#
        ),
        Diagram(
            id: "kanban",
            heading: "Kanban",
            markdown: #"""
            ```mermaid
            kanban
              backlog[Backlog]
                task1[Collect every diagram type]@{ ticket: MD-1, priority: 'Very High', assigned: 'Chen' }
                task2[Check native vs fallback]@{ ticket: MD-2, priority: 'High' }
              doing[In progress]
                task3[Steer-test on Duh Ifone]@{ ticket: MD-3, assigned: 'Chen' }
              done[Done]
                task5[Install Release build]@{ ticket: MD-0, priority: 'Low' }
            ```
            """#
        ),
        Diagram(
            id: "journey",
            heading: "Journey",
            markdown: #"""
            ```mermaid
            journey
              title My working day
              section Go to work
                Make tea: 5: Me
                Go upstairs: 3: Me
                Do work: 1: Me, Cat
              section Go home
                Go downstairs: 5: Me
                Sit down: 5: Me
            ```
            """#
        ),
    ]

    private let themeID: ThemeID

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light
            : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Production chat Mermaid rendering")
                    .font(.headline)
                    .foregroundStyle(.themeFg)

                Text("Native fenced mermaid blocks on the production markdown path")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                ForEach(Self.diagrams) { diagram in
                    Text(diagram.heading)
                        .font(.headline)
                        .foregroundStyle(.themeFg)
                    MarkdownContentViewWrapper(content: diagram.markdown, renderingMode: .export)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mermaid.preview.diagram.\(diagram.id)")
                }
            }
            .padding(20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mermaid.preview.content")
        }
        .background(Color.themeBg.ignoresSafeArea())
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .accessibilityIdentifier("screenshot.ready")
    }
}


// The architecture graph that exposed inline/expanded shelf-packing drift.
struct MermaidConsistencyPreview: View {
    let expanded: Bool
    private let themeID: ThemeID

    init(expanded: Bool) {
        self.expanded = expanded
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" ? .light : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        FullScreenCodeView(content: expanded
            ? .mermaid(content: Self.source, filePath: nil)
            : .markdown(content: Self.markdown, filePath: nil))
            .preferredColorScheme(themeID == .light ? .light : .dark)
            .accessibilityIdentifier("screenshot.ready")
    }

    static let markdown = "## Oppi architecture\n\nTap the diagram to explore its connections.\n\n```mermaid\n" + source + "\n```"
    static let source = """
    graph TD
      subgraph Apple[Apple clients]
        App[iOS and Mac apps]
        WorkspaceUI[Sessions inbox, workspace sidebar,<br/>and workspace detail]
        Timeline[iOS UIKit and Mac AppKit/SwiftUI timelines]
        Voice[Voice input and playback]
      end
      CLI[Local oppi CLI]
      subgraph Server[Oppi server]
        LocalHTTP[HTTP over owner-only Unix socket]
        HTTP[Network REST API]
        Streams[Focused session, app event,<br/>and audio streams]
        Router[Session runtime router]
        Sessions[Managed SessionManager]
        Mirror[Pi TUI mirror runtime]
        Bridge[Mirror bridge WebSocket]
        ExtensionUI[Pi extension UI relay]
        Automations[Saved Agents and schedule runner]
        Storage[SQLite session store and local-session catalog]
        Project[Shared Pi session projection]
        Pi[Pi SDK AgentSession]
      end
      subgraph Workspace[Workspace runtime]
        Files[Workspace files]
        Tools[Tools and extensions]
        Sandbox[Optional sandbox runtime]
      end
      CLI --> LocalHTTP
      LocalHTTP --> Router
      LocalHTTP --> Automations
      LocalHTTP --> Storage
      App --> HTTP
      App --> Streams
      HTTP --> Router
      HTTP --> Automations
      HTTP --> Storage
      Streams --> Router
      Router --> Sessions
      Router --> Mirror
      Bridge --> Mirror
      Automations --> Sessions
      Sessions --> ExtensionUI
      Sessions --> Pi
      Sessions --> Project
      Mirror --> Project
      Pi --> Tools
      Tools --> Files
      Project --> Storage
      Tools --> Sandbox
      HTTP --> WorkspaceUI
      Streams --> WorkspaceUI
      Streams --> Timeline
      Voice --> Streams
    """
}


// MARK: - Mermaid Fullscreen Preview

/// Production full-screen mermaid viewer at iPhone width, including fit-to-width zoom.
struct MermaidFullscreenPreview: View {
    private static let source = """
        stateDiagram-v2
            [*] --> Unset : no asr.backend
            Unset --> ModuleReady : backend=module and model on disk
            Unset --> HttpReady : backend=http and endpoint null or /transcribe
            Unset --> ModuleMissing : backend=module, no model
            HttpReady --> PhoneOn : identity.dictationStream
            ModuleReady --> PhoneOn : identity.dictationStream
            ModuleMissing --> PhoneOff : iOS on-device only
        """

    private let themeID: ThemeID

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light
            : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        FullScreenCodeView(content: .mermaid(content: Self.source, filePath: "asr.mmd"))
            .preferredColorScheme(themeID == .light ? .light : .dark)
            .accessibilityIdentifier("screenshot.ready")
    }
}


// MARK: - Mermaid Responsive Routing Preview

struct MermaidResponsiveRoutingPreview: View {
    private struct Diagram: Identifiable {
        let id: String
        let heading: String
        let markdown: String
    }

    private static let diagrams: [Diagram] = [
        Diagram(
            id: "dense-flowchart",
            heading: "Dense flowchart",
            markdown: #"""
            ```mermaid
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
            ```
            """#
        ),
        Diagram(
            id: "subgraph-entry",
            heading: "Subgraph entry",
            markdown: #"""
            ```mermaid
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
            ```
            """#
        ),
        Diagram(
            id: "sequence-stress",
            heading: "Sequence",
            markdown: #"""
            ```mermaid
            sequenceDiagram
                Alice->>+John: Hello John, how are you?
                Note over Alice,John: A typical interaction
                alt is sick
                    John->>Alice: Not so good
                    Note right of John: Needs rest
                else is well
                    John-->>-Alice: Feeling fresh like a daisy
                    Note left of Alice: All good
                end
            ```
            """#
        ),
    ]

    private let themeID: ThemeID

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light
            : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Mermaid shared trunks and responsive sequence")
                    .font(.headline)
                    .foregroundStyle(.themeFg)

                Text("Dense fan-out/fan-in, direct subgraph entry, and two-participant sequence stress")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                ForEach(Self.diagrams) { diagram in
                    Text(diagram.heading)
                        .font(.headline)
                        .foregroundStyle(.themeFg)
                    MarkdownContentViewWrapper(content: diagram.markdown, renderingMode: .export)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mermaid.routing.preview.content")
        }
        .background(Color.themeBg.ignoresSafeArea())
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
