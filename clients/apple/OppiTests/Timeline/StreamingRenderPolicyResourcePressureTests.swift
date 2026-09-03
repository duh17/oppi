import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("StreamingRenderPolicy resource-pressure admission")
@MainActor
struct ResourcePressurePolicyTests {

    // MARK: - Work admission matrix

    @Test("nominal and fair keep current full finalized admission")
    func nominalAndFairAdmitFullFinalizedWork() {
        for pressure in [
            StreamingRenderPolicy.ResourcePressure.nominal,
            StreamingRenderPolicy.ResourcePressure.fair,
        ] {
            #expect(StreamingRenderPolicy.workAdmission(for: pressure) == .nominal)
            #expect(StreamingRenderPolicy.admitsSpeculativeRunwayWork(for: pressure))
            #expect(StreamingRenderPolicy.imageDetailScale(for: pressure) == 1)
            #expect(
                StreamingRenderPolicy.decision(
                    for: .syntaxHighlight,
                    pressure: pressure,
                    consumer: .visible
                ) == .allow
            )
            #expect(
                StreamingRenderPolicy.decision(
                    for: .mermaidDiagram,
                    pressure: pressure,
                    consumer: .visible
                ) == .allow
            )
            #expect(
                StreamingRenderPolicy.decision(
                    for: .latexDiagram,
                    pressure: pressure,
                    consumer: .visible
                ) == .allow
            )
            #expect(
                StreamingRenderPolicy.decision(
                    for: .rasterImage,
                    pressure: pressure,
                    consumer: .visible
                ) == .allow
            )
            #expect(
                StreamingRenderPolicy.decision(
                    for: .offscreenMarkdownParse,
                    pressure: pressure,
                    consumer: .speculative
                ) == .allow
            )
            #expect(
                StreamingRenderPolicy.tier(
                    isStreaming: false,
                    contentKind: .markdown,
                    byteCount: 200,
                    lineCount: 8,
                    pressure: pressure
                ) == .full
            )
            #expect(
                StreamingRenderPolicy.tier(
                    isStreaming: false,
                    contentKind: .code(language: .known),
                    byteCount: 200,
                    lineCount: 8,
                    maxLineByteCount: 20,
                    pressure: pressure
                ) == .full
            )
        }
    }

    @Test("serious refuses speculative work and defers decorative upgrades")
    func seriousRefusesSpeculativeAndDefersDecoration() {
        let pressure = StreamingRenderPolicy.ResourcePressure.serious
        #expect(StreamingRenderPolicy.workAdmission(for: pressure) == .serious)
        #expect(!StreamingRenderPolicy.admitsSpeculativeRunwayWork(for: pressure))
        #expect(StreamingRenderPolicy.imageDetailScale(for: pressure) < 1)
        #expect(
            StreamingRenderPolicy.decision(
                for: .offscreenMarkdownParse,
                pressure: pressure,
                consumer: .speculative
            ) == .refuse
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .rasterImage,
                pressure: pressure,
                consumer: .speculative
            ) == .refuse
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .rasterImage,
                pressure: pressure,
                consumer: .visible
            ) == .reducedDetail
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .syntaxHighlight,
                pressure: pressure,
                consumer: .visible
            ) == .deferToPlain
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .mermaidDiagram,
                pressure: pressure,
                consumer: .visible
            ) == .deferToPlain
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .latexDiagram,
                pressure: pressure,
                consumer: .visible
            ) == .deferToPlain
        )
        #expect(
            StreamingRenderPolicy.tier(
                isStreaming: false,
                contentKind: .code(language: .known),
                byteCount: 200,
                lineCount: 8,
                maxLineByteCount: 20,
                pressure: pressure
            ) == .cheap
        )
        #expect(
            StreamingRenderPolicy.tier(
                isStreaming: false,
                contentKind: .markdown,
                byteCount: 200,
                lineCount: 8,
                pressure: pressure
            ) == .cheap
        )
        #expect(
            StreamingRenderPolicy.tier(
                isStreaming: true,
                contentKind: .markdown,
                byteCount: 200,
                lineCount: 8,
                pressure: pressure
            ) == .cheap
        )
    }

    @Test("critical keeps chrome and text unless the consumer is explicit")
    func criticalDefaultsToReadableText() {
        let pressure = StreamingRenderPolicy.ResourcePressure.critical
        #expect(StreamingRenderPolicy.workAdmission(for: pressure) == .critical)
        #expect(!StreamingRenderPolicy.admitsSpeculativeRunwayWork(for: pressure))
        #expect(
            StreamingRenderPolicy.decision(
                for: .rasterImage,
                pressure: pressure,
                consumer: .visible
            ) == .refuse
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .syntaxHighlight,
                pressure: pressure,
                consumer: .visible
            ) == .refuse
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .mermaidDiagram,
                pressure: pressure,
                consumer: .visible
            ) == .refuse
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .latexDiagram,
                pressure: pressure,
                consumer: .visible
            ) == .refuse
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .offscreenMarkdownParse,
                pressure: pressure,
                consumer: .speculative
            ) == .refuse
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .mermaidDiagram,
                pressure: pressure,
                consumer: .explicit
            ) == .allow
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .rasterImage,
                pressure: pressure,
                consumer: .explicit
            ) == .reducedDetail
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .syntaxHighlight,
                pressure: pressure,
                consumer: .explicit
            ) == .deferToPlain
        )
        #expect(
            StreamingRenderPolicy.tier(
                isStreaming: false,
                contentKind: .code(language: .known),
                byteCount: 200,
                lineCount: 8,
                maxLineByteCount: 20,
                pressure: pressure
            ) == .cheap
        )
        #expect(
            StreamingRenderPolicy.tier(
                isStreaming: false,
                contentKind: .code(language: .known),
                byteCount: 200,
                lineCount: 8,
                maxLineByteCount: 20,
                pressure: pressure,
                consumer: .explicit
            ) == .full
        )
    }

    @Test("Low Power Mode applies at least serious admission")
    func lowPowerModeAppliesSeriousAdmission() {
        for thermal in [
            ProcessInfo.ThermalState.nominal,
            .fair,
            .serious,
        ] {
            let pressure = StreamingRenderPolicy.ResourcePressure(
                thermalState: thermal,
                isLowPowerModeEnabled: true
            )
            let admission = StreamingRenderPolicy.workAdmission(for: pressure)
            #expect(admission >= .serious)
            #expect(!StreamingRenderPolicy.admitsSpeculativeRunwayWork(for: pressure))
            #expect(StreamingRenderPolicy.imageDetailScale(for: pressure) < 1)
            #expect(
                StreamingRenderPolicy.decision(
                    for: .syntaxHighlight,
                    pressure: pressure,
                    consumer: .visible
                ) == .deferToPlain
            )
        }

        let criticalLowPower = StreamingRenderPolicy.ResourcePressure(
            thermalState: .critical,
            isLowPowerModeEnabled: true
        )
        #expect(StreamingRenderPolicy.workAdmission(for: criticalLowPower) == .critical)
        #expect(
            StreamingRenderPolicy.decision(
                for: .rasterImage,
                pressure: criticalLowPower,
                consumer: .visible
            ) == .refuse
        )
        #expect(
            MarkdownChunkSettleMotionGate.allows(
                reduceMotion: false,
                lowPower: true,
                thermalState: .nominal
            ) == false
        )
    }

    @Test("unknown future thermal states fail closed to critical")
    func unknownThermalStatesFailClosed() {
        let unknown = ProcessInfo.ThermalState(rawValue: 99) ?? .critical
        let pressure = StreamingRenderPolicy.ResourcePressure(
            thermalState: unknown,
            isLowPowerModeEnabled: false
        )
        #expect(StreamingRenderPolicy.workAdmission(for: pressure) == .critical)
        #expect(!StreamingRenderPolicy.admitsSpeculativeRunwayWork(for: pressure))
        #expect(
            StreamingRenderPolicy.decision(
                for: .rasterImage,
                pressure: pressure,
                consumer: .visible
            ) == .refuse
        )
        #expect(
            StreamingRenderPolicy.decision(
                for: .offscreenMarkdownParse,
                pressure: pressure,
                consumer: .speculative
            ) == .refuse
        )
    }
}

@Suite("Live markdown decorative work under resource pressure")
@MainActor
struct ResourcePressureMarkdownSurfaceTests {
    @Test func seriousPressureShowsMermaidAndLatexAsCodeInsteadOfRendering() {
        let markdown = AssistantMarkdownContentView()
        markdown.bounds = CGRect(x: 0, y: 0, width: 320, height: 600)
        markdown.apply(configuration: .make(
            content: """
            ```mermaid
            graph TD
                A-->B
            ```

            $$
            x^2 + y^2 = z^2
            $$
            """,
            isStreaming: false,
            themeID: .dark,
            resourcePressure: .serious
        ))
        markdown.layoutIfNeeded()

        let mermaid = timelineFirstView(ofType: NativeMermaidBlockView.self, in: markdown)
        let latex = timelineFirstView(ofType: NativeLatexBlockView.self, in: markdown)
        #expect(mermaid != nil)
        #expect(latex != nil)
        #expect(mermaid?.debugApplyAsDiagramCallCountForTesting == 0)
        #expect(mermaid?.debugIsShowingDiagramForTesting == false)
        #expect(latex?.debugRenderCountForTesting == 0)
        #expect(latex?.debugIsShowingFormulaForTesting == false)
    }

    @Test func alreadyRenderedMermaidStaysWhenPressureBecomesSerious() async {
        let markdown = AssistantMarkdownContentView()
        markdown.bounds = CGRect(x: 0, y: 0, width: 320, height: 400)
        let source = """
        ```mermaid
        graph TD
            A-->B
        ```
        """
        markdown.apply(configuration: .make(
            content: source,
            isStreaming: false,
            themeID: .dark,
            resourcePressure: .nominal
        ))
        markdown.layoutIfNeeded()
        let mermaid = timelineFirstView(ofType: NativeMermaidBlockView.self, in: markdown)
        #expect((mermaid?.debugApplyAsDiagramCallCountForTesting ?? 0) > 0)
        var diagramShown = false
        for _ in 0..<200 {
            if mermaid?.debugIsShowingDiagramForTesting == true {
                diagramShown = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(diagramShown)

        markdown.apply(configuration: .make(
            content: source,
            isStreaming: false,
            themeID: .dark,
            resourcePressure: .serious
        ))
        markdown.layoutIfNeeded()
        #expect(mermaid?.debugIsShowingDiagramForTesting == true)
    }

    @Test func seriousPressureDoesNotScheduleSyntaxHighlight() {
        let markdown = AssistantMarkdownContentView()
        markdown.bounds = CGRect(x: 0, y: 0, width: 320, height: 400)
        markdown.apply(configuration: .make(
            content: """
            ```swift
            let answer = 42
            ```
            """,
            isStreaming: false,
            themeID: .dark,
            resourcePressure: .serious
        ))
        markdown.layoutIfNeeded()
        let code = timelineFirstView(ofType: NativeCodeBlockView.self, in: markdown)
        #expect(code != nil)
        #expect(code?.debugHasHighlightedTextForTesting == false)
    }
}

@Suite("Resource pressure notification delivery")
@MainActor
struct ResourcePressureNotificationTests {
    @Test func notificationFromBackgroundAppliesOnMainActorWithoutLiveOverride() async {
        let harness = makeTimelineHarness(sessionId: "session-pressure-notify")
        let items = (0..<4).map { index in
            ChatItem.assistantMessage(
                id: "notify-\(index)",
                text: "# Row \(index)\n\nBody",
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        harness.applyAndLayout(items: items)
        let runway = harness.coordinator.debugPreparationRunwayForTesting
        harness.coordinator.collectionView(
            harness.collectionView,
            prefetchItemsAt: [IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0)]
        )
        #expect(!runway.debugPrefetchRequestedItemIDs.isEmpty)

        harness.coordinator.debugInstallResourcePressureSnapshotForTesting(.nominal)
        let baselineCancel = runway.debugCancelAllPrefetchCount
        harness.coordinator.debugNextNotificationPressureForTesting = .serious
        harness.coordinator.debugLastResourcePressureAppliedOnMainActorForTesting = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                NotificationCenter.default.post(
                    name: ProcessInfo.thermalStateDidChangeNotification,
                    object: nil
                )
                continuation.resume()
            }
        }

        #expect(await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            harness.coordinator.resourcePressure == .serious
                && harness.coordinator.debugLastResourcePressureAppliedOnMainActorForTesting
                && runway.debugCancelAllPrefetchCount == baselineCancel + 1
        })
        #expect(harness.coordinator.resourcePressure == .serious)
        #expect(harness.coordinator.debugLastResourcePressureAppliedOnMainActorForTesting)
        #expect(runway.debugCancelAllPrefetchCount == baselineCancel + 1)
        #expect(runway.resourcePressure == .serious)

        harness.coordinator.debugNextNotificationPressureForTesting = nil
        NotificationCenter.default.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        #expect(harness.coordinator.resourcePressure == .serious)
        #expect(runway.debugCancelAllPrefetchCount == baselineCancel + 1)
    }
}

@Suite("Live image decode under resource pressure")
@MainActor
struct ResourcePressureImageSurfaceTests {
    @Test func streamingNoContextSeriousAndCriticalPathsDoNotStartCanonicalDecode() async throws {
        NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
        defer { NativeMarkdownImageView.debugResetPreparedArtifactsForTesting() }

        let png = try #require(Self.makeTestPNG())
        for pressure in [
            StreamingRenderPolicy.ResourcePressure.serious,
            .critical,
        ] {
            NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
            let fetchCount = ResourcePressureWorkCounter()
            let view = NativeMarkdownImageView()
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
            let url = try #require(WorkspaceFileURL.make(
                baseURL: URL(string: "https://oppi.example")!,
                workspaceID: "workspace-pressure",
                filePath: "images/\(pressure.thermalState.rawValue).png"
            ))
            view.apply(
                url: url,
                alt: "Pressure raster",
                fetchWorkspaceFile: { _, _ in
                    fetchCount.value += 1
                    return png
                },
                fetchSessionFile: nil,
                resourcePressure: pressure
            )

            let startedCanonicalWork = await waitForTimelineCondition(timeoutMs: 400) { @MainActor in
                fetchCount.value > 0 || NativeMarkdownImageView.debugPreparedOperationCountForTesting > 0
            }
            #expect(
                !startedCanonicalWork,
                "\(pressure.thermalState.rawValue) no-context path started canonical fetch/decode"
            )
            #expect(fetchCount.value == 0)
            #expect(NativeMarkdownImageView.debugPreparedOperationCountForTesting == 0)
            #expect(!view.debugHasRasterPreviewForTesting)
        }
    }

    @Test func alreadyDisplayedSVGSurvivesPressureDrivenTargetIdentityChange() async throws {
        NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
        defer { NativeMarkdownImageView.debugResetPreparedArtifactsForTesting() }

        let svgData = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10">
          <rect x="0" y="0" width="20" height="10" fill="red"/>
        </svg>
        """.utf8)
        let fetchCount = ResourcePressureWorkCounter()
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-pressure",
            filePath: "images/keep.svg"
        ))
        let reducedTarget = ChatTimelinePreparationRunway.ImageTarget(
            pointWidth: 320,
            displayScale: 3,
            screenHeight: 844,
            detailScale: StreamingRenderPolicy.imageDetailScale(for: .critical)
        )
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, _ in
                fetchCount.value += 1
                return svgData
            }
        )
        let broker = TimelineImagePreparationBroker()

        view.apply(
            url: url,
            alt: "Keep SVG",
            fetchWorkspaceFile: { _, _ in
                fetchCount.value += 1
                return svgData
            },
            fetchSessionFile: nil,
            resourcePressure: .nominal
        )

        let loaded = await waitForTimelineCondition(timeoutMs: 5_000) { @MainActor in
            view.debugIsSVGArtifactForTesting
        }
        #expect(loaded, "SVG should display before the pressure-driven identity change")
        let fetchCountAfterLoad = fetchCount.value
        #expect(fetchCountAfterLoad > 0)
        let operationsAfterLoad = NativeMarkdownImageView.debugPreparedOperationCountForTesting

        let criticalContext = TimelineImagePreparationContext(
            broker: broker,
            scope: ChatTimelinePreparationRunway.Scope(
                sessionID: "session-svg",
                serverID: "server-a",
                workspaceID: "workspace-pressure",
                worktreeID: nil
            ),
            itemID: "assistant-svg",
            target: reducedTarget,
            loaders: loaders,
            serverBaseURL: URL(string: "https://oppi.example"),
            resourcePressure: .critical,
            onReady: {},
            onCancelled: {}
        )
        view.apply(
            url: url,
            alt: "Keep SVG",
            fetchWorkspaceFile: { _, _ in
                fetchCount.value += 1
                return svgData
            },
            fetchSessionFile: nil,
            resourcePressure: .critical,
            preparationContext: criticalContext
        )

        #expect(view.debugIsSVGArtifactForTesting)
        #expect(view.debugHasPreparedArtifactForTesting)
        #expect(fetchCount.value == fetchCountAfterLoad)
        #expect(NativeMarkdownImageView.debugPreparedOperationCountForTesting == operationsAfterLoad)
    }

    private static func makeTestPNG() -> Data? {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }.pngData()
    }
}

@Suite("Live expanded tool markdown under resource pressure")
@MainActor
struct ResourcePressureToolViewportTests {
    @Test func streamingExpandedToolMarkdownDefersDecorativeWorkUnderPressure() throws {
        let source = """
        ```mermaid
        graph TD
            A-->B
        ```

        $$
        x^2 + y^2 = z^2
        $$

        ```swift
        let answer = 42
        ```
        """

        for pressure in [
            StreamingRenderPolicy.ResourcePressure.serious,
            .critical,
        ] {
            var configuration = makeTimelineToolConfiguration(
                expandedContent: .markdown(text: source),
                toolNamePrefix: "read",
                isExpanded: true,
                isDone: false
            )
            configuration.resourcePressure = pressure
            let view = ToolTimelineRowContentView(configuration: configuration)
            _ = fittedTimelineSize(for: view, width: 360)

            let mermaid = timelineFirstView(ofType: NativeMermaidBlockView.self, in: view)
            let latex = timelineFirstView(ofType: NativeLatexBlockView.self, in: view)
            let code = timelineFirstView(ofType: NativeCodeBlockView.self, in: view)
            #expect(mermaid != nil, "\(pressure.thermalState.rawValue) streaming tool markdown should keep mermaid chrome")
            #expect(latex != nil, "\(pressure.thermalState.rawValue) streaming tool markdown should keep latex chrome")
            #expect(code != nil, "\(pressure.thermalState.rawValue) streaming tool markdown should keep code chrome")
            #expect(
                mermaid?.debugApplyAsDiagramCallCountForTesting == 0,
                "\(pressure.thermalState.rawValue) must not schedule mermaid raster work"
            )
            #expect(mermaid?.debugIsShowingDiagramForTesting == false)
            #expect(
                latex?.debugRenderCountForTesting == 0,
                "\(pressure.thermalState.rawValue) must not schedule latex render work"
            )
            #expect(latex?.debugIsShowingFormulaForTesting == false)
            #expect(code?.debugHasHighlightedTextForTesting == false)
        }
    }
}

private final class ResourcePressureWorkCounter: @unchecked Sendable {
    var value = 0
}
