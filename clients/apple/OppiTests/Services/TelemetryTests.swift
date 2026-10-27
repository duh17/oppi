import Foundation
import Testing
@testable import Oppi

@Suite("Telemetry")
struct TelemetryTests {

    // MARK: - Emit policy

    @Test func recordAppliesTheCatalogEmitPolicy() {
        let capture = TelemetryCapture()
        capture.runSync {
            // Below the 4 ms floor: dropped. At the floor: recorded.
            Telemetry.record(AppTimelineApply(durationMs: 3, items: 10, changed: 1))
            Telemetry.record(AppTimelineApply(durationMs: 4, items: 10, changed: 1))
            // At or above the 5 s suspension ceiling: dropped.
            Telemetry.record(AppTimelineApply(durationMs: 5_000, items: 10, changed: 1))
            // A sub-millisecond cell configure is the common case and is dropped.
            Telemetry.record(AppCellConfigure(durationMs: 0, rowType: "assistant"))
            // A negative ping is a clock artifact.
            Telemetry.record(AppWsPing(rttMs: -1, socksGeneration: 0))
        }

        #expect(capture.events.map(\.name) == ["app.timeline_apply"])
        #expect(capture.events.first?.fields["duration_ms"] == 4)
    }

    @Test func fastSuccessfulQueuePollsAreDroppedButFailuresAreKept() {
        let capture = TelemetryCapture()
        capture.runSync {
            Telemetry.record(AppCommand(
                sendMs: 2, roundtripMs: 40, command: "get_queue", transport: .lan, status: .ok
            ))
            Telemetry.record(AppCommand(
                sendMs: 2, roundtripMs: 40, command: "get_queue", transport: .lan,
                status: .error, errorKind: .timeout
            ))
            Telemetry.record(AppCommand(
                sendMs: 2, roundtripMs: 40, command: "prompt", transport: .lan, status: .ok
            ))
        }

        #expect(capture.events.map { $0.tags?["status"] } == ["error", "ok"])
        #expect(capture.events.map { $0.tags?["command"] } == ["get_queue", "prompt"])
    }

    /// One non-finite field would make JSON encoding throw for the whole
    /// upload batch, and the batch is retried forever.
    @Test func nonFiniteFieldsNeverReachTheUploader() {
        let capture = TelemetryCapture()
        capture.runSync {
            Telemetry.record(AppTimelineJank(jankPct: .nan, cycles: 10, hitches: 1))
            Telemetry.record(AppDeviceResources(cpuPct: .infinity, memoryAvailableMb: 100, thermalState: 0))
            Telemetry.record(AppTimelineJank(jankPct: 10, cycles: 10, hitches: 1))
        }

        #expect(capture.events.map(\.name) == ["app.timeline_jank"])
    }

    @Test func sessionAndWorkspaceIdsAreAttachedAndEmptyOnesOmitted() {
        let capture = TelemetryCapture()
        capture.runSync {
            Telemetry.record(
                AppSessionSwitch(durationMs: 20, cached: true),
                sessionId: "s1", workspaceId: "w1"
            )
            Telemetry.record(AppSessionSwitch(durationMs: 20, cached: true), sessionId: "", workspaceId: nil)
        }

        #expect(capture.events[0].sessionId == "s1")
        #expect(capture.events[0].workspaceId == "w1")
        #expect(capture.events[1].sessionId == nil)
        #expect(capture.events[1].workspaceId == nil)
    }

    // MARK: - Encoding

    @Test func boolFieldsEncodeAsZeroOrOneAndOptionalFieldsAreOmitted() {
        let event = AppCellConfigure(durationMs: 5, expanded: true, rowType: "tool")
        #expect(event.fieldValues == ["duration_ms": 5, "expanded": 1])
        #expect(event.tagValues == ["row_type": "tool"])
    }

    @Test func nameTagsOutsideTheSafeAlphabetBecomeUnknown() {
        let event = AppMemoryWarning(cacheEntries: 1, cacheBytes: 1, screen: "Chat / Session #1")
        #expect(event.tagValues["screen"] == "unknown")
        #expect(AppMemoryWarning(cacheEntries: 1, cacheBytes: 1, screen: "chat").tagValues["screen"] == "chat")
    }

    /// One accept/reject list (`protocol/telemetry-name-tags.json`) for the server
    /// sanitizer and this one; both apply the catalog's `NAME_LOCATION_RULES`.
    private struct NameTagFixture: Decodable {
        let accept: [String]
        let reject: [String]
    }

    private static func nameTagFixture() throws -> NameTagFixture {
        try JSONDecoder().decode(NameTagFixture.self, from: ProtocolFixtures.data("telemetry-name-tags.json"))
    }

    @Test func hostsUrlsAndPathsBecomeUnknown() throws {
        let fixture = try Self.nameTagFixture()
        #expect(!fixture.reject.isEmpty)
        for value in fixture.reject {
            #expect(TelemetryName.sanitize(value) == "unknown", "\(value)")
        }
    }

    @Test func identifiersSurviveSanitizing() throws {
        let fixture = try Self.nameTagFixture()
        #expect(!fixture.accept.isEmpty)
        for value in fixture.accept {
            #expect(TelemetryName.sanitize(value) == value, "\(value)")
        }
    }

    @Test func sizeBucketsUseTheServersEdges() {
        #expect(TelemetryTag.OutputSize(bytes: 999) == .under1kb)
        #expect(TelemetryTag.OutputSize(bytes: 1_000) == .under10kb)
        #expect(TelemetryTag.OutputSize(bytes: 199_999) == .under200kb)
        #expect(TelemetryTag.InputSize(bytes: 200_000) == .over200kb)
    }

    // MARK: - Context

    /// A device sample always names a screen: a missing context is `unknown`, never absent.
    @Test func contextAlwaysSuppliesAScreen() {
        let empty = TelemetryContext(crashContext: nil, agentsRunning: false, voiceActive: false)
        #expect(empty.screen == "unknown")
        #expect(empty.streamState == "unknown")

        let busy = TelemetryContext(crashContext: nil, agentsRunning: true, voiceActive: true)
        #expect(busy.agents == .running)
        #expect(busy.voice == .on)
        #expect(empty.agents == .idle)
        #expect(empty.voice == .off)

        let event = AppDeviceResources(
            memoryAvailableMb: 100, thermalState: 0,
            screen: empty.screen, streamState: empty.streamState,
            agents: empty.agents, voice: empty.voice
        )
        #expect(event.tagValues["screen"] == "unknown")
        #expect(Set(event.tagValues.keys) == ["screen", "stream_state", "agents", "voice"])
    }

    @Test func contextCarriesTheRecordedScreenAndStream() {
        MetricKitCrashContextStore.clearForTesting()
        MetricKitCrashContextStore.recordAppContext(
            sessionId: "s1", workspaceId: "w1", activeServerId: "srv",
            screen: "workspace", scenePhase: "active"
        )
        MetricKitCrashContextStore.record(sessionId: "s1", workspaceId: "w1", streamState: "streaming")
        defer { MetricKitCrashContextStore.clearForTesting() }

        let context = TelemetryContext(
            crashContext: MetricKitCrashContextStore.snapshot(),
            agentsRunning: false, voiceActive: false
        )
        #expect(context.screen == "workspace")
        #expect(context.streamState == "streaming")
    }

    // MARK: - Error classification

    @Test func errorsMapToCoarseKindsNeverTypeNamesOrCodes() {
        let cases: [(Error, TelemetryTag.ErrorKind)] = [
            (CancellationError(), .cancelled),
            (URLError(.cancelled), .cancelled),
            (URLError(.timedOut), .timeout),
            (URLError(.cannotConnectToHost), .network),
            (URLError(.secureConnectionFailed), .urlError),
            (APIError.server(status: 503, message: "down"), .httpStatus),
            (APIError.invalidResponse, .decode),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")), .decode),
            (VoiceInputError.remoteDecodeFailed, .decode),
            (VoiceInputError.remoteBadResponseStatus(500), .httpStatus),
            (VoiceInputError.serverAsrUnavailable, .misconfigured),
            (VoiceInputError.captureBufferOverflow, .captureBufferOverflow),
            (QuickSessionError.noConnection, .noConnection),
            (QuickSessionError.noWorkspace, .noWorkspace),
            (QuickSessionError.agentLaunchFailed("x"), .agentLaunchFailed),
            (ShareSessionRequestError.timedOut, .timeout),
            (ShareSessionRequestError.failed("x"), .requestFailed),
            (NSError(domain: "test", code: 1), .other),
        ]
        for (error, kind) in cases {
            #expect(TelemetryErrorKind.classify(error) == kind, "\(error)")
        }
    }

    // MARK: - Runtime events

    /// The shared runtime (also compiled by Mac) names its telemetry vocabulary
    /// with enums whose raw values are catalog values. A case added there without
    /// a catalog counterpart fails here instead of being dropped in production.
    @Test func everyRuntimeVocabularyCaseMapsToACatalogEvent() {
        for reason in ChatSessionRuntimeTelemetry.FreshnessReason.allCases {
            let mapped = ChatSessionTelemetry.event(
                for: .freshContentLag(durationMs: 5, workspaceId: "w", reason: reason, cached: false, transport: "lan")
            )
            #expect(mapped?.event is AppFreshContentLag, "reason \(reason)")
            #expect(mapped?.workspaceId == "w")
        }

        for path in ChatSessionRuntimeTelemetry.LoadPath.allCases {
            let mapped = ChatSessionTelemetry.event(
                for: .sessionLoad(durationMs: 5, workspaceId: nil, path: path, itemCount: 3)
            )
            #expect(mapped?.event is AppSessionLoad, "path \(path)")
        }

        for source in ChatSessionRuntimeTelemetry.ReducerSource.allCases {
            let mapped = ChatSessionTelemetry.event(
                for: .reducerLoad(durationMs: 5, source: source, eventCount: 2, itemCount: 3)
            )
            #expect(mapped?.event is AppReducerLoad, "source \(source)")
        }

        for result in ChatSessionRuntimeTelemetry.CatchUpResult.allCases {
            let mapped = ChatSessionTelemetry.event(for: .catchUp(durationMs: 5, result: result))
            #expect(mapped?.event is AppCatchup, "result \(result)")
        }
    }

    @Test func traceFetchFailureCarriesItsErrorKind() throws {
        let mapped = try #require(ChatSessionTelemetry.event(
            for: .traceFetch(durationMs: 9, workspaceId: "w", status: "error", eventCount: nil, errorKind: "timeout")
        ))
        let event = try #require(mapped.event as? AppTraceFetch)
        #expect(event.tagValues == ["status": "error", "error_kind": "timeout"])
    }
}
