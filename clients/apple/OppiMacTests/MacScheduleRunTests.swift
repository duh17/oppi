import AppKit
import SwiftUI
import XCTest
import Foundation
import Testing
@testable import Oppi

@Suite("Mac schedule runs")
@MainActor
struct MacScheduleRunTests {
    @Test func selectingScheduleLoadsRecentHistory() async {
        let transport = ScheduleRunTransport()
        let store = makeStore(transport)
        await store.loadSelectedSchedule()
        let requests = await transport.requests
        #expect(requests.contains { $0.path == "/schedules/schedule-a/runs?limit=20&order=desc" })
        #expect(store.loadedSchedule?.id == "schedule-a")
        #expect(store.hasLoadedScheduleRuns)
        #expect(store.scheduleRuns.isEmpty)
    }

    @Test func routesEncodeIDsAndDecodeSortedHistoryAndUniqueMutationBodies() async throws {
        let transport = ScheduleRunTransport()
        await transport.setHistory([runJSON(id: "a", time: 2000), runJSON(id: "old", time: 1000), runJSON(id: "z", time: 2000)])
        let client = makeClient(transport)
        let runs = try await client.listAgentScheduleRuns(scheduleId: "id /?", limit: 20)
        #expect(runs.map(\.id) == ["z", "a", "old"])
        let run = try await client.runAgentSchedule("id /?")
        _ = try await client.runAgentSchedule("id /?")
        #expect(run.status == .completed)
        #expect(run.sessionId == "session-1")
        let requests = await transport.requests
        #expect(requests[0].path == "/schedules/id%20%2F%3F/runs?limit=20&order=desc")
        #expect(requests[1].method == "POST")
        #expect(requests[1].path == "/schedules/id%20%2F%3F/run")
        let first = try JSONDecoder().decode(ManualBody.self, from: #require(requests[1].body))
        let second = try JSONDecoder().decode(ManualBody.self, from: #require(requests[2].body))
        #expect(first.requestId.hasPrefix("mac-manual-"))
        #expect(first.requestId != second.requestId)
    }

    @Test func pendingBlocksDuplicateSubmissionAndReturnsAuthoritativeSessionTarget() async {
        let transport = ScheduleRunTransport(heldSuffix: "/run")
        let store = makeStore(transport)
        let first = Task { await store.runSelectedScheduleNow() }
        await transport.waitUntilHeld()
        #expect(store.isRunningSchedule)
        #expect(!store.canRunSelectedSchedule)
        let duplicate = await store.runSelectedScheduleNow()
        #expect(duplicate == nil)
        await transport.release()
        let target = await first.value
        #expect(target?.sessionId == "session-1")
        #expect(target?.workspaceId == "actual-workspace")
        #expect(target?.summary.status == .stopped)
        #expect(!store.isRunningSchedule)
        #expect(store.scheduleRunMessage == "Run completed.")
        #expect(store.scheduleRuns.map(\.id) == ["run-1"])
        let posts = await transport.requests.filter { $0.method == "POST" }
        #expect(posts.count == 1)
    }

    @Test func failureIsRetryableButNeverAutomaticallyRetried() async {
        let transport = ScheduleRunTransport()
        await transport.failNextRun()
        let store = makeStore(transport)
        #expect(await store.runSelectedScheduleNow() == nil)
        #expect(store.scheduleRunError != nil)
        #expect(store.scheduleRunMessage == nil)
        #expect(store.canRunSelectedSchedule)
        #expect(await transport.requests.count == 1)
        #expect(await store.runSelectedScheduleNow() != nil)
        #expect(store.scheduleRunError == nil)
    }

    @Test func selectionRoundTripSettlesRunWithoutStaleNavigationOrDuplicate() async {
        let transport = ScheduleRunTransport(heldSuffix: "/run")
        let store = makeStore(transport)
        let first = Task { await store.runSelectedScheduleNow() }
        await transport.waitUntilHeld()
        store.selectSchedule("schedule-b")
        store.selectSchedule("schedule-a")
        #expect(store.isRunningSchedule)
        #expect(await store.runSelectedScheduleNow() == nil)
        await transport.release()
        #expect(await first.value == nil)
        #expect(store.scheduleRuns.map(\.id) == ["run-1"])
        #expect(store.scheduleRunMessage == "Run completed.")
        #expect(!store.isRunningSchedule)
    }

    @Test func selectionRoundTripSettlesUncertainFailureBeforeExplicitNewAttempt() async {
        let transport = ScheduleRunTransport(heldSuffix: "/run")
        await transport.failNextRun()
        let store = makeStore(transport)
        let first = Task { await store.runSelectedScheduleNow() }
        await transport.waitUntilHeld()
        store.selectSchedule("schedule-b")
        store.selectSchedule("schedule-a")
        #expect(await store.runSelectedScheduleNow() == nil)
        #expect(await transport.requests.count == 1)
        await transport.release()
        #expect(await first.value == nil)
        #expect(store.scheduleRunError?.contains("may have reached the server") == true)
        #expect(store.scheduleRunMessage == nil)
        // A newer attempt is impossible until the original task settles. Once it
        // does, only an explicit attempt clears the old warning and may navigate.
        #expect(await store.runSelectedScheduleNow() != nil)
        #expect(store.scheduleRunError == nil)
        #expect(store.scheduleRunMessage == "Run completed.")
        let posts = await transport.requests.filter { $0.method == "POST" }
        #expect(posts.count == 2)
        #expect(posts[0].body != posts[1].body)
    }

    @Test func anotherScheduleNeverReceivesRunAcknowledgement() async {
        let transport = ScheduleRunTransport(heldSuffix: "/run")
        let store = makeStore(transport)
        let task = Task { await store.runSelectedScheduleNow() }
        await transport.waitUntilHeld()
        store.selectSchedule("schedule-b")
        await transport.release()
        #expect(await task.value == nil)
        #expect(store.scheduleRuns.isEmpty)
        #expect(store.scheduleRunMessage == nil)
    }

    @Test func historyOpenAndRunNowAreMutuallyExclusive() async throws {
        let transport = ScheduleRunTransport(heldSuffix: "/session-1")
        let store = makeStore(transport)
        let run = try JSONDecoder().decode(AgentScheduleRunSummary.self, from: Data(runJSON().utf8))
        let opening = Task { await store.openScheduleRun(run) }
        await transport.waitUntilHeld()
        #expect(!store.canRunSelectedSchedule)
        #expect(await store.runSelectedScheduleNow() == nil)
        #expect(await transport.requests.count == 1)
        await transport.release()
        #expect(await opening.value != nil)

        let runningTransport = ScheduleRunTransport(heldSuffix: "/run")
        let runningStore = makeStore(runningTransport)
        let running = Task { await runningStore.runSelectedScheduleNow() }
        await runningTransport.waitUntilHeld()
        #expect(await runningStore.openScheduleRun(run) == nil)
        #expect(await runningTransport.requests.count == 1)
        await runningTransport.release()
        #expect(await running.value != nil)
    }

    @Test func staleHistoryCannotOverwriteNewRunAcknowledgement() async {
        let transport = ScheduleRunTransport(heldSuffix: "order=desc")
        let store = makeStore(transport)
        let history = Task { await store.refreshScheduleRuns() }
        await transport.waitUntilHeld()
        _ = await store.runSelectedScheduleNow()
        await transport.release()
        await history.value
        #expect(store.scheduleRuns.map(\.id) == ["run-1"])
        #expect(!store.isLoadingScheduleRuns)
    }

    @Test func staleHistoryAndCancelledSessionOpenDoNotPaintOrNavigate() async throws {
        let transport = ScheduleRunTransport(heldSuffix: "order=desc")
        let store = makeStore(transport)
        let history = Task { await store.refreshScheduleRuns() }
        await transport.waitUntilHeld()
        store.selectSchedule("schedule-b")
        await transport.release()
        await history.value
        #expect(!store.hasLoadedScheduleRuns)
        #expect(store.scheduleRuns.isEmpty)

        let opening = ScheduleRunTransport(heldSuffix: "/session-1")
        let otherStore = makeStore(opening)
        let run = try JSONDecoder().decode(AgentScheduleRunSummary.self, from: Data(runJSON().utf8))
        let task = Task { await otherStore.openScheduleRun(run) }
        await opening.waitUntilHeld()
        task.cancel()
        await opening.release()
        #expect(await task.value == nil)
        #expect(otherStore.openingScheduleRunID == nil)
    }

    @Test func historyFailureKeepsRowsAndCanRetryEmptyAndArchivedCannotRun() async {
        let transport = ScheduleRunTransport()
        let store = makeStore(transport)
        _ = await store.runSelectedScheduleNow()
        await transport.failNextHistory()
        await store.refreshScheduleRuns()
        #expect(store.scheduleHistoryError != nil)
        #expect(store.scheduleRuns.count == 1)
        await store.refreshScheduleRuns()
        #expect(store.scheduleHistoryError == nil)
        #expect(store.scheduleRuns.isEmpty)
        store.schedules[0].status = .archived
        #expect(!store.canRunSelectedSchedule)
        let count = await transport.requests.count
        #expect(await store.runSelectedScheduleNow() == nil)
        #expect(await transport.requests.count == count)
        store.schedules[0].status = .paused
        #expect(store.canRunSelectedSchedule)
    }
}

@MainActor
final class MacScheduleRunVisualGateTests: XCTestCase {
    func testMountedScheduleEditorWithCompletedRun() async throws {
        let store = makeStore(ScheduleRunTransport())
        await store.loadSelectedSchedule()
        _ = await store.runSelectedScheduleNow()
        let root = MacScheduleEditor(store: store, onOpenSession: { _ in })
            .frame(width: 720, height: 1000)
            .environment(\.theme, AppTheme.dark)
            .environment(\.themeID, ThemeID.dark)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        XCTAssertEqual(image.size.width, 720)
        let attachment = XCTAttachment(image: image)
        attachment.name = "mac-schedule-completed-run-fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct ManualBody: Decodable { let requestId: String }

@MainActor
private func makeStore(_ transport: ScheduleRunTransport) -> MacCatalogStore {
    let store = MacCatalogStore(client: makeClient(transport))
    store.schedules = [AgentScheduleSummary(id: "schedule-a", name: "Fixture", status: .active,
        trigger: .every(intervalMs: 3600000, timeZone: "UTC"),
        action: AgentScheduleActionSummary(type: .newSession, workspaceId: "ws-1", promptChars: 12),
        createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))]
    store.selectSchedule("schedule-a")
    return store
}

private func makeClient(_ transport: ScheduleRunTransport) -> MacWorkspaceClient {
    MacWorkspaceClient(socketPath: "/tmp/schedule-fixture.sock", token: "fixture", transport: transport)
}

private actor ScheduleRunTransport: MacLocalHTTPPerforming {
    var requests: [MacLocalHTTPRequest] = []
    private var history: [String] = []
    private var runFailure = false
    private var historyFailure = false
    private var heldSuffix: String?
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(heldSuffix: String? = nil) { self.heldSuffix = heldSuffix }
    func setHistory(_ rows: [String]) { history = rows }
    func failNextRun() { runFailure = true }
    func failNextHistory() { historyFailure = true }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { heldSuffix = nil; held?.resume(); held = nil }
    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        if let heldSuffix, request.path.hasSuffix(heldSuffix) {
            await withCheckedContinuation { continuation in
                held = continuation
                waiter?.resume()
                waiter = nil
            }
        }
        let json: String
        if request.path.hasSuffix("/run") {
            if runFailure { runFailure = false; throw MacLocalHTTPError.timeout }
            json = "{\"run\":\(runJSON())}"
        } else if request.path.contains("/runs?") {
            if historyFailure { historyFailure = false; throw MacLocalHTTPError.timeout }
            json = "{\"runs\":[\(history.joined(separator: ","))]}"
        } else if request.path.hasPrefix("/sessions/") {
            json = #"{"session":{"id":"session-1","workspaceId":"actual-workspace","status":"stopped","createdAt":1000,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}"#
        } else {
            json = scheduleJSON
        }
        return MacLocalHTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

private let scheduleJSON = #"{"schedule":{"id":"schedule-a","name":"Fixture schedule","status":"active","trigger":{"type":"every","intervalMs":3600000,"timeZone":"UTC"},"action":{"type":"new_session","workspaceId":"ws-1","prompt":"Fixture only"},"createdAt":1000,"updatedAt":1000}}"#

private func runJSON(id: String = "run-1", time: Int = 3000) -> String {
    """
    {"id":"\(id)","scheduleId":"schedule-a","kind":"manual","slotKey":"manual:fixture","idempotencyKey":"fixture","status":"completed","action":{"type":"new_session","workspaceId":"ws-1","promptChars":12},"createdAt":\(time),"updatedAt":\(time),"sessionId":"session-1"}
    """
}
