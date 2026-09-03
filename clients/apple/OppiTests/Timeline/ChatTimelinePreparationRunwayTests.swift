import Testing
import UIKit
@testable import Oppi

private actor TimelineRunwayParseGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var startedContents: [String] = []

    func parse(
        content: String,
        themeID: ThemeID,
        scope: ChatTimelinePreparationRunway.Scope,
        serverBaseURL: URL?
    ) async -> [MarkdownBlock]? {
        startedContents.append(content)
        if !isOpen {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        guard !Task.isCancelled else { return nil }
        return MarkdownWikiLinkRewriter.rewrite(
            blocks: parseCommonMark(content),
            serverID: scope.serverID,
            workspaceID: scope.workspaceID,
            sessionID: scope.sessionID,
            sourceDirectory: nil
        )
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func startedCount() -> Int { startedContents.count }
}

private actor TimelineRunwayFetchCounter {
    private var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }

    func count() -> Int { paths.count }
}

private actor TimelineRunwayFetchGate {
    private var startedPaths: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func fetch(path: String, data: Data) async -> Data {
        startedPaths.append(path)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        return data
    }

    func startedCount() -> Int { startedPaths.count }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@Suite("Chat timeline preparation runway", .serialized)
@MainActor
struct ChatTimelinePreparationRunwayTests {
    private let scope = ChatTimelinePreparationRunway.Scope(
        sessionID: "session-a",
        serverID: "server-a",
        workspaceID: "workspace-a",
        worktreeID: nil
    )

    private let target = ChatTimelinePreparationRunway.ImageTarget(
        pointWidth: 320,
        displayScale: 3,
        screenHeight: 844
    )

    private let trustedServerBaseURL = URL(string: "https://oppi.example")

    @Test func finalizedMarkdownPrefetchIsIdentityKeyedAndStreamingIsExcluded() async throws {
        let runway = ChatTimelinePreparationRunway()
        let finalized = request(
            itemID: "assistant-final",
            content: "# Final\n\nPrepared body"
        )
        let streaming = request(
            itemID: "assistant-streaming",
            content: "# Still arriving",
            isStreaming: true
        )

        #expect(runway.request(finalized, demand: .prefetch) == .inFlight)
        #expect(runway.request(streaming, demand: .prefetch) == .neverRequested)

        #expect(await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            runway.state(for: finalized) == .ready
        })
        #expect(runway.preparedBlocks(for: finalized) != nil)
        #expect(runway.preparedBlocks(for: streaming) == nil)
    }

    @Test func visibleDemandKeepsJoinedParseAliveAfterPrefetchCancellation() async throws {
        let gate = TimelineRunwayParseGate()
        let runway = ChatTimelinePreparationRunway(parse: { content, themeID, scope, serverBaseURL in
            await gate.parse(
                content: content,
                themeID: themeID,
                scope: scope,
                serverBaseURL: serverBaseURL
            )
        })
        let joined = request(itemID: "assistant-joined", content: "Joined **parse**")

        #expect(runway.request(joined, demand: .prefetch) == .inFlight)
        #expect(runway.request(joined, demand: .visible) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await gate.startedCount() == 1
        })

        runway.cancel(itemID: joined.itemID, demand: .prefetch)
        #expect(runway.state(for: joined) == .inFlight)

        await gate.open()
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            runway.state(for: joined) == .ready
        })
    }

    @Test func readyInFlightAndNeverPrefetchedMarkdownProduceTheSameContent() async throws {
        let content = "# Runway\n\nSame **body**.\n\n```swift\nlet answer = 42\n```"
        let gate = TimelineRunwayParseGate()
        let runway = ChatTimelinePreparationRunway(parse: { content, themeID, scope, serverBaseURL in
            await gate.parse(
                content: content,
                themeID: themeID,
                scope: scope,
                serverBaseURL: serverBaseURL
            )
        })
        let preparedRequest = request(itemID: "assistant-content", content: content)
        let configuration = AssistantMarkdownContentView.Configuration.make(
            content: content,
            isStreaming: false,
            themeID: .dark,
            serverID: scope.serverID,
            workspaceID: scope.workspaceID,
            sessionID: scope.sessionID
        )
        let source = AssistantMarkdownSegmentSource()
        let neverPrefetched = segmentContentSignature(source.buildSegments(configuration))

        #expect(runway.state(for: preparedRequest) == .neverRequested)
        #expect(runway.request(preparedRequest, demand: .prefetch) == .inFlight)
        let inFlight = segmentContentSignature(source.buildSegments(configuration))
        #expect(inFlight == neverPrefetched)

        await gate.open()
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            runway.state(for: preparedRequest) == .ready
        })
        let ready = source.buildSegments(
            configuration,
            preparedBlocks: runway.preparedBlocks(for: preparedRequest)
        )
        #expect(segmentContentSignature(ready) == neverPrefetched)
    }

    @Test func actualCellReuseReleasesItsVisibleDemand() async throws {
        let gate = TimelineRunwayParseGate()
        let runway = ChatTimelinePreparationRunway(parse: { content, themeID, scope, serverBaseURL in
            await gate.parse(
                content: content,
                themeID: themeID,
                scope: scope,
                serverBaseURL: serverBaseURL
            )
        })
        let joined = request(itemID: "assistant-reused", content: "Reuse me")
        let cell = SafeSizingCell()

        #expect(runway.request(joined, demand: .prefetch) == .inFlight)
        #expect(runway.request(joined, demand: .visible) == .inFlight)
        cell.bindTimelinePreparationDemand(itemID: joined.itemID) {
            runway.cancel(itemID: joined.itemID, demand: .visible)
        }
        cell.prepareForReuse()

        #expect(runway.state(for: joined) == .inFlight)
        runway.cancel(itemID: joined.itemID, demand: .prefetch)
        #expect(runway.state(for: joined) == .neverRequested)
        await gate.open()
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            runway.debugOperationCount == 0
        })
    }

    @Test func replacementIdentityAndSessionTeardownDiscardLateParses() async throws {
        let gate = TimelineRunwayParseGate()
        let runway = ChatTimelinePreparationRunway(parse: { content, themeID, scope, serverBaseURL in
            await gate.parse(
                content: content,
                themeID: themeID,
                scope: scope,
                serverBaseURL: serverBaseURL
            )
        })
        let old = request(itemID: "assistant-same", content: "Old revision")
        let replacement = request(itemID: "assistant-same", content: "New revision")
        let tornDown = request(itemID: "assistant-torn-down", content: "Old session")

        #expect(runway.request(old, demand: .prefetch) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await gate.startedCount() == 1
        })
        #expect(runway.request(replacement, demand: .prefetch) == .inFlight)
        #expect(runway.request(tornDown, demand: .prefetch) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await gate.startedCount() == 3
        })

        runway.cancelAll()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }

        #expect(runway.state(for: old) == .neverRequested)
        #expect(runway.state(for: replacement) == .neverRequested)
        #expect(runway.state(for: tornDown) == .neverRequested)
        #expect(runway.preparedBlocks(for: replacement) == nil)
    }

    @Test func canonicalRowSourceKeysBothFallbackAndPreparedParse() async throws {
        let raw = "    indented code\n\nTrailing space   \n"
        let rowConfiguration = AssistantTimelineRowConfiguration(
            text: raw,
            isStreaming: false,
            canFork: false,
            onFork: nil
        )
        let expectedSource = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(rowConfiguration.renderedMarkdownSource == expectedSource)

        let runway = ChatTimelinePreparationRunway()
        let canonicalRequest = ChatTimelinePreparationRunway.Request(
            scope: scope,
            itemID: "assistant-canonical-source",
            content: rowConfiguration.renderedMarkdownSource,
            isStreaming: false,
            themeID: .dark,
            serverBaseURL: nil,
            target: target
        )
        #expect(runway.request(canonicalRequest, demand: .prefetch) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            runway.state(for: canonicalRequest) == .ready
        })
        let expectedBlocks = MarkdownWikiLinkRewriter.rewrite(
            blocks: parseCommonMark(expectedSource),
            serverID: scope.serverID,
            workspaceID: scope.workspaceID,
            sessionID: scope.sessionID,
            sourceDirectory: nil
        )
        #expect(runway.preparedBlocks(for: canonicalRequest) == expectedBlocks)
    }

    @Test func markdownOperationAdmissionStaysGloballyBounded() async {
        let gate = TimelineRunwayParseGate()
        let runway = ChatTimelinePreparationRunway(parse: { content, themeID, scope, serverBaseURL in
            await gate.parse(
                content: content,
                themeID: themeID,
                scope: scope,
                serverBaseURL: serverBaseURL
            )
        })
        var admitted = 0
        for index in 0..<100 {
            if runway.request(
                request(itemID: "bounded-\(index)", content: "Body \(index)"),
                demand: .prefetch
            ) == .inFlight {
                admitted += 1
            }
        }

        #expect(admitted == ChatTimelinePreparationRunway.maximumParseOperations)
        #expect(runway.debugOperationCount <= ChatTimelinePreparationRunway.maximumParseOperations)
        #expect(runway.debugTrackedIdentityCount <= ChatTimelinePreparationRunway.maximumParseOperations)
        runway.cancelAll()
        await gate.open()
    }

    @Test func canceledParsesKeepTheirAdmissionUntilTheyReturn() async {
        let gate = TimelineRunwayParseGate()
        let runway = ChatTimelinePreparationRunway(parse: { content, themeID, scope, serverBaseURL in
            await gate.parse(
                content: content,
                themeID: themeID,
                scope: scope,
                serverBaseURL: serverBaseURL
            )
        })
        for index in 0..<ChatTimelinePreparationRunway.maximumParseOperations {
            #expect(runway.request(
                request(itemID: "parse-slot-\(index)", content: "Body \(index)"),
                demand: .prefetch
            ) == .inFlight)
        }
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await gate.startedCount() == ChatTimelinePreparationRunway.maximumParseOperations
        })

        runway.cancelAll()
        let replacement = request(itemID: "parse-replacement", content: "Replacement")
        #expect(runway.request(replacement, demand: .prefetch) == .neverRequested)

        await gate.releaseOne()
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            runway.debugOperationCount == ChatTimelinePreparationRunway.maximumParseOperations - 1
        })
        #expect(runway.request(replacement, demand: .prefetch) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await gate.startedCount() == ChatTimelinePreparationRunway.maximumParseOperations + 1
        })
        await gate.open()
    }

    @Test func trimAndLastImageCancellationPruneTrackedIdentities() async throws {
        let runway = ChatTimelinePreparationRunway()
        for wave in 0..<3 {
            for index in 0..<ChatTimelinePreparationRunway.maximumParseOperations {
                #expect(runway.request(
                    request(itemID: "trim-\(wave)-\(index)", content: "Wave \(wave) item \(index)"),
                    demand: .prefetch
                ) == .inFlight)
            }
            #expect(await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
                runway.debugOperationCount == 0
            })
            runway.trimUnreferencedArtifacts()
            #expect(runway.debugTrackedIdentityCount == 0)
        }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let png = try #require(image.pngData())
        let fetchGate = TimelineRunwayFetchGate()
        let broker = TimelineImagePreparationBroker()
        let imageRunway = ChatTimelinePreparationRunway(imageBroker: broker)
        let imageURL = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/identity.png"
        ))
        let imageRequest = ChatTimelinePreparationRunway.Request(
            scope: scope,
            itemID: "trim-image",
            content: "![identity](\(imageURL.absoluteString))",
            isStreaming: false,
            themeID: .dark,
            serverBaseURL: URL(string: "https://oppi.example"),
            target: target,
            imageLoaders: ChatTimelinePreparationRunway.ImageLoaders(
                fetchWorkspaceFile: { _, path in
                    await fetchGate.fetch(path: path, data: png)
                }
            )
        )
        #expect(imageRunway.request(imageRequest, demand: .prefetch) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) {
            await fetchGate.startedCount() == 1
        })
        imageRunway.trimUnreferencedArtifacts()
        #expect(imageRunway.debugTrackedIdentityCount == 1)
        imageRunway.cancel(itemID: imageRequest.itemID, demand: .prefetch)
        #expect(imageRunway.debugTrackedIdentityCount == 0)
        await fetchGate.releaseAll()
    }

    @Test func imagePreparationContextCancelPrunesTheExactTrackedIdentity() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let png = try #require(image.pngData())
        let fetchGate = TimelineRunwayFetchGate()
        let broker = TimelineImagePreparationBroker()
        let imageRunway = ChatTimelinePreparationRunway(imageBroker: broker)
        let imageURL = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/context-cancel.png"
        ))
        let imageRequest = ChatTimelinePreparationRunway.Request(
            scope: scope,
            itemID: "context-cancel",
            content: "![identity](\(imageURL.absoluteString))",
            isStreaming: false,
            themeID: .dark,
            serverBaseURL: URL(string: "https://oppi.example"),
            target: target,
            imageLoaders: ChatTimelinePreparationRunway.ImageLoaders(
                fetchWorkspaceFile: { _, path in
                    await fetchGate.fetch(path: path, data: png)
                }
            )
        )
        #expect(imageRunway.request(imageRequest, demand: .prefetch) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) {
            await fetchGate.startedCount() == 1
        })
        imageRunway.trimUnreferencedArtifacts()
        #expect(imageRunway.debugTrackedIdentityCount == 1)

        let context = try #require(imageRunway.imagePreparationContext(for: imageRequest))
        let visibleDemandID = UUID()
        #expect(context.request(url: imageURL, visibleDemandID: visibleDemandID) == .inFlight)
        imageRunway.cancel(itemID: imageRequest.itemID, demand: .prefetch)
        #expect(imageRunway.debugTrackedIdentityCount == 1)

        context.cancel(url: imageURL, visibleDemandID: visibleDemandID)
        #expect(imageRunway.debugTrackedIdentityCount == 0)
        await fetchGate.releaseAll()
    }

    @Test func collectionPrefetchIsBoundedUsesStableIDsAndSkipsStreamingRow() {
        let harness = makeTimelineHarness(sessionId: "session-prefetch")
        let items = (0..<12).map { index in
            ChatItem.assistantMessage(
                id: "assistant-\(index)",
                text: "# Row \(index)\n\nBody",
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        let config = makeTimelineConfiguration(
            items: items,
            isBusy: true,
            streamingAssistantID: "assistant-2",
            sessionId: "session-prefetch",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            toolSegmentStore: harness.toolSegmentStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        #expect(harness.collectionView.prefetchDataSource === harness.coordinator)
        harness.coordinator.collectionView(
            harness.collectionView,
            prefetchItemsAt: (0..<12).map { IndexPath(item: $0, section: 0) }
        )

        #expect(
            harness.coordinator.debugPreparationRunwayForTesting.debugPrefetchRequestedItemIDs
                == Set(["assistant-0", "assistant-1", "assistant-3", "assistant-4", "assistant-5", "assistant-6", "assistant-7"])
        )
    }

    @Test func reversePrefetchDirectionCancelsSpeculativeDemand() {
        let harness = makeTimelineHarness(sessionId: "session-reverse")
        let items = (0..<12).map { index in
            ChatItem.assistantMessage(
                id: "reverse-\(index)",
                text: "Row \(index)",
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        harness.applyAndLayout(items: items)
        let runway = harness.coordinator.debugPreparationRunwayForTesting
        let baseline = runway.debugCancelAllPrefetchCount

        harness.coordinator.collectionView(
            harness.collectionView,
            prefetchItemsAt: [IndexPath(item: 8, section: 0), IndexPath(item: 9, section: 0)]
        )
        harness.coordinator.collectionView(
            harness.collectionView,
            prefetchItemsAt: [IndexPath(item: 1, section: 0), IndexPath(item: 2, section: 0)]
        )
        harness.coordinator.collectionView(
            harness.collectionView,
            prefetchItemsAt: [IndexPath(item: 8, section: 0), IndexPath(item: 9, section: 0)]
        )

        #expect(runway.debugCancelAllPrefetchCount == baseline + 1)
    }

    @Test func lateCompletionReconfiguresTheCurrentStableIDAfterAPrepend() throws {
        let windowed = makeWindowedTimelineHarness(sessionId: "session-stable-id")
        let preparedID = "assistant-prepared"
        let prepared = ChatItem.assistantMessage(
            id: preparedID,
            text: "Prepared row",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        windowed.applyItems([prepared], isBusy: false)
        _ = try configuredTimelineCell(in: windowed.collectionView, item: 0)

        let prepended = ChatItem.assistantMessage(
            id: "assistant-prepended",
            text: "Earlier row",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        windowed.applyItems([prepended, prepared], isBusy: false)
        _ = try configuredTimelineCell(in: windowed.collectionView, item: 1)
        #expect(windowed.coordinator.dataSource?.indexPath(for: preparedID)?.item == 1)

        windowed.coordinator.handlePreparedArtifact(
            scope: ChatTimelinePreparationRunway.Scope(
                sessionID: "wrong-session",
                serverID: nil,
                workspaceID: "ws-test",
                worktreeID: nil
            ),
            itemID: preparedID
        )
        #expect(windowed.coordinator.debugPreparedArtifactReconfiguredItemIDs.isEmpty)

        windowed.coordinator.handlePreparedArtifact(
            scope: ChatTimelinePreparationRunway.Scope(
                sessionID: windowed.sessionId,
                serverID: nil,
                workspaceID: "ws-test",
                worktreeID: nil
            ),
            itemID: preparedID
        )
        #expect(windowed.coordinator.debugPreparedArtifactReconfiguredItemIDs == [preparedID])
    }

    @Test func finalizedMarkdownParseStartsInternalRasterPreparation() async throws {
        let sourceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 900, height: 450)
        ).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 450))
        }
        let png = try #require(sourceImage.pngData())
        let counter = TimelineRunwayFetchCounter()
        let broker = TimelineImagePreparationBroker()
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/runway.png"
        ))
        let runway = ChatTimelinePreparationRunway(imageBroker: broker)
        let imageRequest = ChatTimelinePreparationRunway.Request(
            scope: scope,
            itemID: "assistant-raster-pipeline",
            content: "![runway](images/runway.png)",
            isStreaming: false,
            themeID: .dark,
            serverBaseURL: URL(string: "https://oppi.example"),
            target: target,
            imageLoaders: ChatTimelinePreparationRunway.ImageLoaders(
                fetchWorkspaceFile: { _, path in
                    await counter.record(path)
                    return png
                }
            )
        )

        #expect(runway.request(imageRequest, demand: .prefetch) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 5_000) { @MainActor in
            runway.imagePreparationContext(for: imageRequest)?.preparedImage(for: url) != nil
        })
        #expect(await counter.count() == 1)
    }

    @Test func visibleImagesOnlyJoinTwoPrefetchAdmissionsPerItem() async throws {
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 160)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
        }
        let png = try #require(sourceImage.pngData())
        let counter = TimelineRunwayFetchCounter()
        let broker = TimelineImagePreparationBroker()
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, path in
                await counter.record(path)
                return png
            }
        )
        let urls = try (0..<3).map { index in
            try #require(WorkspaceFileURL.make(
                baseURL: URL(string: "https://oppi.example")!,
                workspaceID: "workspace-a",
                filePath: "images/admitted-\(index).png"
            ))
        }

        #expect(broker.request(
            url: urls[0],
            scope: scope,
            itemID: "assistant-admitted",
            target: target,
            loaders: loaders,
            demand: .visible(itemID: "assistant-admitted", id: UUID()),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .neverRequested)
        for url in urls.prefix(2) {
            #expect(broker.request(
                url: url,
                scope: scope,
                itemID: "assistant-admitted",
                target: target,
                loaders: loaders,
                demand: .prefetch(itemID: "assistant-admitted"),
                onReady: {},
                serverBaseURL: trustedServerBaseURL
            ) == .inFlight)
        }
        #expect(broker.request(
            url: urls[2],
            scope: scope,
            itemID: "assistant-admitted",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-admitted"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .neverRequested)
        #expect(broker.request(
            url: urls[0],
            scope: scope,
            itemID: "assistant-admitted",
            target: target,
            loaders: loaders,
            demand: .visible(itemID: "assistant-admitted", id: UUID()),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) != .neverRequested)

        #expect(await waitForTimelineCondition(timeoutMs: 5_000) {
            await counter.count() == 2
        })
    }

    @Test func untrackedVisibleRowCannotJoinAnotherItemsSameGatedURL() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let png = try #require(image.pngData())
        let gate = TimelineRunwayFetchGate()
        let broker = TimelineImagePreparationBroker()
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, path in
                await gate.fetch(path: path, data: png)
            }
        )
        let sharedURL = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/same-gated.png"
        ))
        let runway = ChatTimelinePreparationRunway(imageBroker: broker)
        let trackedRequest = ChatTimelinePreparationRunway.Request(
            scope: scope,
            itemID: "assistant-tracked",
            content: "![same](\(sharedURL.absoluteString))",
            isStreaming: false,
            themeID: .dark,
            serverBaseURL: URL(string: "https://oppi.example"),
            target: target,
            imageLoaders: loaders
        )
        let untrackedRequest = ChatTimelinePreparationRunway.Request(
            scope: scope,
            itemID: "assistant-untracked",
            content: "![same](\(sharedURL.absoluteString))",
            isStreaming: false,
            themeID: .dark,
            serverBaseURL: URL(string: "https://oppi.example"),
            target: target,
            imageLoaders: loaders
        )

        #expect(runway.request(trackedRequest, demand: .prefetch) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) {
            await gate.startedCount() == 1
        })
        #expect(runway.imagePreparationContext(for: trackedRequest) != nil)
        #expect(runway.imagePreparationContext(for: untrackedRequest) == nil)
        #expect(broker.request(
            url: sharedURL,
            scope: scope,
            itemID: "assistant-untracked",
            target: target,
            loaders: loaders,
            demand: .visible(itemID: "assistant-untracked", id: UUID()),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .neverRequested)
        #expect(await gate.startedCount() == 1)

        let orphanURL = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/orphan-no-markdown.png"
        ))
        #expect(broker.request(
            url: orphanURL,
            scope: scope,
            itemID: "orphan-no-markdown",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "orphan-no-markdown"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)
        let demandCount = broker.debugDemandRegistrationCountForTesting
        runway.remove(itemIDs: ["orphan-no-markdown"])
        #expect(broker.debugDemandRegistrationCountForTesting == demandCount - 1)
        await gate.releaseAll()
    }

    @Test func imageOperationAdmissionStaysGloballyBounded() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.brown.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let png = try #require(image.pngData())
        let broker = TimelineImagePreparationBroker()
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, _ in png }
        )
        var admitted = 0
        for index in 0..<100 {
            let url = try #require(WorkspaceFileURL.make(
                baseURL: URL(string: "https://oppi.example")!,
                workspaceID: "workspace-a",
                filePath: "images/global-\(index).png"
            ))
            if broker.request(
                url: url,
                scope: scope,
                itemID: "global-\(index)",
                target: target,
                loaders: loaders,
                demand: .prefetch(itemID: "global-\(index)"),
                onReady: {},
                serverBaseURL: trustedServerBaseURL
            ) == .inFlight {
                admitted += 1
            }
        }

        #expect(admitted == TimelineImagePreparationBroker.maximumOperations)
        #expect(broker.debugInFlightCountForTesting <= TimelineImagePreparationBroker.maximumOperations)
        #expect(broker.debugTrackedAdmissionCountForTesting <= TimelineImagePreparationBroker.maximumOperations)
        broker.cancelAll()
    }

    @Test func joinedImageConsumerMetadataIsBounded() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let png = try #require(image.pngData())
        let gate = TimelineRunwayFetchGate()
        let broker = TimelineImagePreparationBroker()
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, path in
                await gate.fetch(path: path, data: png)
            }
        )
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/shared.png"
        ))
        var joined = 0
        for index in 0..<100 {
            if broker.request(
                url: url,
                scope: scope,
                itemID: "shared-\(index)",
                target: target,
                loaders: loaders,
                demand: .prefetch(itemID: "shared-\(index)"),
                onReady: {},
                serverBaseURL: trustedServerBaseURL
            ) == .inFlight {
                joined += 1
            }
        }

        #expect(joined == TimelineImagePreparationBroker.maximumDemandRegistrations)
        #expect(
            broker.debugDemandRegistrationCountForTesting
                == TimelineImagePreparationBroker.maximumDemandRegistrations
        )
        broker.cancelAll()
        await gate.releaseAll()
    }

    @Test func joinedPrefetchAdmissionChurnReleasesExactItemKeyImmediately() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let png = try #require(image.pngData())
        let gate = TimelineRunwayFetchGate()
        let broker = TimelineImagePreparationBroker()
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, path in
                await gate.fetch(path: path, data: png)
            }
        )
        let sharedURL = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/shared-churn.png"
        ))
        let secondURL = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/item-a-second.png"
        ))
        let thirdURL = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/item-a-third.png"
        ))

        #expect(broker.request(
            url: sharedURL,
            scope: scope,
            itemID: "assistant-churn-a",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-churn-a"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)
        #expect(broker.request(
            url: sharedURL,
            scope: scope,
            itemID: "assistant-churn-b",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-churn-b"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)
        #expect(broker.request(
            url: secondURL,
            scope: scope,
            itemID: "assistant-churn-a",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-churn-a"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)
        #expect(broker.request(
            url: thirdURL,
            scope: scope,
            itemID: "assistant-churn-a",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-churn-a"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .neverRequested)

        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await gate.startedCount() == 2
        })

        broker.cancel(
            url: sharedURL,
            scope: scope,
            target: target,
            demand: .prefetch(itemID: "assistant-churn-a")
        )
        #expect(broker.request(
            url: thirdURL,
            scope: scope,
            itemID: "assistant-churn-a",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-churn-a"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await gate.startedCount() == 3
        })
        await gate.releaseAll()
    }

    @Test func canceledFetchesKeepTheirSlotsUntilTheirLoadersReturn() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let png = try #require(image.pngData())
        let gate = TimelineRunwayFetchGate()
        let broker = TimelineImagePreparationBroker()
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, path in
                await gate.fetch(path: path, data: png)
            }
        )
        let urls = try (0..<4).map { index in
            try #require(WorkspaceFileURL.make(
                baseURL: URL(string: "https://oppi.example")!,
                workspaceID: "workspace-a",
                filePath: "images/slot-\(index).png"
            ))
        }

        for index in 0..<3 {
            #expect(broker.request(
                url: urls[index],
                scope: scope,
                itemID: "slot-\(index)",
                target: target,
                loaders: loaders,
                demand: .prefetch(itemID: "slot-\(index)"),
                onReady: {},
                serverBaseURL: trustedServerBaseURL
            ) == .inFlight)
        }
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await gate.startedCount() == 3
        })

        broker.cancelAll()
        #expect(broker.request(
            url: urls[3],
            scope: scope,
            itemID: "slot-3",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "slot-3"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await gate.startedCount() == 3)

        await gate.releaseOne()
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) {
            await gate.startedCount() == 4
        })
        await gate.releaseAll()
    }

    @Test func targetsInTheSameBucketUseTheBucketEnvelope() async throws {
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600)).image { context in
            UIColor.systemMint.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        let png = try #require(sourceImage.pngData())
        let broker = TimelineImagePreparationBroker()
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/bucket.png"
        ))
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, _ in png }
        )
        let firstTarget = ChatTimelinePreparationRunway.ImageTarget(
            pointWidth: 65,
            displayScale: 1,
            screenHeight: 320
        )
        let largerSameBucket = ChatTimelinePreparationRunway.ImageTarget(
            pointWidth: 127,
            displayScale: 1,
            screenHeight: 320
        )
        #expect(firstTarget.widthPixelBucket == largerSameBucket.widthPixelBucket)

        #expect(broker.request(
            url: url,
            scope: scope,
            itemID: "assistant-bucket",
            target: firstTarget,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-bucket"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 5_000) { @MainActor in
            broker.preparedImage(url: url, scope: scope, target: firstTarget) != nil
        })
        let artifact = try #require(broker.preparedImage(
            url: url,
            scope: scope,
            target: largerSameBucket
        ))
        #expect(artifact.preparedPixelSize.width >= 127)
        #expect(artifact.preparedPixelSize.width <= CGFloat(largerSameBucket.widthPixelBucket))
    }

    @Test func rasterBrokerJoinsRequestsUsesTargetBucketsAndTrimsDecodedCost() async throws {
        let sourceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 600)
        ).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        let png = try #require(sourceImage.pngData())
        let fetchCounter = TimelineRunwayFetchCounter()
        let broker = TimelineImagePreparationBroker()
        let smallTarget = ChatTimelinePreparationRunway.ImageTarget(
            pointWidth: 80,
            displayScale: 1,
            screenHeight: 320
        )
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://oppi.example")!,
            workspaceID: "workspace-a",
            filePath: "images/chart.png"
        ))
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, path in
                await fetchCounter.record(path)
                return png
            }
        )
        var readyCount = 0

        #expect(broker.request(
            url: url,
            scope: scope,
            itemID: "assistant-image",
            target: smallTarget,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-image"),
            onReady: { readyCount += 1 },
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)
        #expect(broker.request(
            url: url,
            scope: scope,
            itemID: "assistant-image",
            target: smallTarget,
            loaders: loaders,
            demand: .visible(itemID: "assistant-image", id: UUID()),
            onReady: { readyCount += 1 },
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)

        #expect(await waitForTimelineCondition(timeoutMs: 5_000) { @MainActor in
            readyCount == 1
        })
        let auxiliaryURLs = try ["aux-a.png", "aux-b.png"].map { path in
            try #require(WorkspaceFileURL.make(
                baseURL: URL(string: "https://oppi.example")!,
                workspaceID: "workspace-a",
                filePath: "images/\(path)"
            ))
        }
        for (index, auxiliaryURL) in auxiliaryURLs.enumerated() {
            #expect(broker.request(
                url: auxiliaryURL,
                scope: scope,
                itemID: "assistant-aux-\(index)",
                target: smallTarget,
                loaders: loaders,
                demand: .prefetch(itemID: "assistant-aux-\(index)"),
                onReady: { readyCount += 1 },
                serverBaseURL: trustedServerBaseURL
            ) == .inFlight)
        }

        #expect(await waitForTimelineCondition(timeoutMs: 5_000) { @MainActor in
            readyCount == 3
        })
        #expect(await fetchCounter.count() == 3)
        let small = try #require(broker.preparedImage(url: url, scope: scope, target: smallTarget))
        #expect(small.preparedPixelSize.width <= CGFloat(smallTarget.widthPixelBucket))
        #expect(small.preparedPixelSize.height <= CGFloat(smallTarget.maximumHeightPixelBucket))
        #expect(small.decodedByteCost == Int(small.preparedPixelSize.width * small.preparedPixelSize.height) * 4)
        #expect(broker.debugDecodedCostForTesting == small.decodedByteCost * 3)
        #expect(await broker.debugMaximumConcurrentRasterPreparationsForTesting == 1)

        let largeTarget = ChatTimelinePreparationRunway.ImageTarget(
            pointWidth: 320,
            displayScale: 2,
            screenHeight: 844
        )
        #expect(broker.preparedImage(url: url, scope: scope, target: largeTarget) == nil)
        #expect(broker.request(
            url: url,
            scope: scope,
            itemID: "assistant-image",
            target: largeTarget,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-image"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 5_000) { @MainActor in
            broker.preparedImage(url: url, scope: scope, target: largeTarget) != nil
        })
        #expect(await fetchCounter.count() == 4)
        let large = try #require(broker.preparedImage(url: url, scope: scope, target: largeTarget))
        #expect(large.preparedPixelSize.width > small.preparedPixelSize.width)

        broker.trimUnreferencedArtifacts()
        #expect(broker.debugDecodedCostForTesting == 0)
        #expect(broker.preparedImage(url: url, scope: scope, target: smallTarget) == nil)
    }

    @Test func runwayNeverFetchesExternalHTTPSImages() async throws {
        let broker = TimelineImagePreparationBroker()
        let counter = TimelineRunwayFetchCounter()
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, path in
                await counter.record(path)
                return Data()
            }
        )
        let external = try #require(URL(string: "https://images.example/photo.png"))

        #expect(broker.request(
            url: external,
            scope: scope,
            itemID: "assistant-external",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-external"),
            onReady: {},
            serverBaseURL: trustedServerBaseURL
        ) == .neverRequested)
        for _ in 0..<10 { await Task.yield() }
        #expect(await counter.count() == 0)
    }

    @Test func routeShapedHTTPSPrefetchRequiresTrustedOriginAndWorkspaceScope() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let png = try #require(image.pngData())
        let counter = TimelineRunwayFetchCounter()
        let broker = TimelineImagePreparationBroker()
        let loaders = ChatTimelinePreparationRunway.ImageLoaders(
            fetchWorkspaceFile: { _, path in
                await counter.record("workspace:\(path)")
                return png
            },
            fetchSessionFile: { _, _, path in
                await counter.record("session:\(path)")
                return png
            },
            fetchHostFile: { path in
                await counter.record("host:\(path)")
                return png
            }
        )
        let trustedBase = try #require(URL(string: "https://oppi.example"))
        let lookalike = try #require(URL(
            string: "https://evil.example/workspaces/workspace-a/raw/images/lookalike.png"
        ))
        let crossWorkspace = try #require(WorkspaceFileURL.make(
            baseURL: trustedBase,
            workspaceID: "workspace-b",
            filePath: "images/cross.png"
        ))
        let owned = try #require(WorkspaceFileURL.make(
            baseURL: trustedBase,
            workspaceID: "workspace-a",
            filePath: "images/owned.png"
        ))
        let sessionURL = try #require(SessionFileURL.make(
            workspaceID: "workspace-a",
            sessionID: "session-a",
            filePath: "images/session.png"
        ))
        let hostURL = try #require(HostFileURL.make(filePath: "/tmp/host.png"))

        #expect(broker.request(
            url: lookalike,
            scope: scope,
            itemID: "assistant-lookalike",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-lookalike"),
            onReady: {},
            serverBaseURL: trustedBase
        ) == .neverRequested)
        #expect(broker.request(
            url: crossWorkspace,
            scope: scope,
            itemID: "assistant-cross-workspace",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-cross-workspace"),
            onReady: {},
            serverBaseURL: trustedBase
        ) == .neverRequested)
        for _ in 0..<10 { await Task.yield() }
        #expect(await counter.count() == 0)

        #expect(broker.request(
            url: owned,
            scope: scope,
            itemID: "assistant-owned",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-owned"),
            onReady: {},
            serverBaseURL: trustedBase
        ) == .inFlight)
        #expect(broker.request(
            url: sessionURL,
            scope: scope,
            itemID: "assistant-session-file",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-session-file"),
            onReady: {},
            serverBaseURL: trustedBase
        ) == .inFlight)
        #expect(broker.request(
            url: hostURL,
            scope: scope,
            itemID: "assistant-host-file",
            target: target,
            loaders: loaders,
            demand: .prefetch(itemID: "assistant-host-file"),
            onReady: {},
            serverBaseURL: trustedBase
        ) == .inFlight)
        #expect(await waitForTimelineCondition(timeoutMs: 5_000) {
            await counter.count() == 3
        })
    }

    private func segmentContentSignature(_ segments: [FlatSegment]) -> [String] {
        segments.map { segment in
            switch segment {
            case .text(let attributed):
                "text:\(String(attributed.characters))"
            case .codeBlock(let language, let code):
                "code:\(language ?? ""):\(code)"
            case .table(let headers, let rows):
                "table:\(headers.count):\(rows.count)"
            case .thematicBreak:
                "thematic-break"
            case .image(let alt, let url):
                "image:\(alt):\(url.absoluteString)"
            case .video:
                "video"
            case .audio:
                "audio"
            case .mermaidDiagram(let code):
                "mermaid:\(code)"
            case .latexBlock(let code):
                "latex:\(code)"
            }
        }
    }

    private func request(
        itemID: String,
        content: String,
        isStreaming: Bool = false
    ) -> ChatTimelinePreparationRunway.Request {
        ChatTimelinePreparationRunway.Request(
            scope: scope,
            itemID: itemID,
            content: content,
            isStreaming: isStreaming,
            themeID: .dark,
            serverBaseURL: nil,
            target: target
        )
    }
}
