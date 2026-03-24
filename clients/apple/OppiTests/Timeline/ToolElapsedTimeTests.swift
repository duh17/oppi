import Testing
import Foundation
import UIKit
@testable import Oppi

@MainActor
@Suite("Tool elapsed time")
struct ToolElapsedTimeTests {

    // MARK: - Formatting

    @Test("formatElapsed sub-second")
    func formatSubSecond() {
        #expect(ToolTimelineRowDisplayState.formatElapsed(0) == "<1s")
    }

    @Test("formatElapsed seconds")
    func formatSeconds() {
        #expect(ToolTimelineRowDisplayState.formatElapsed(1) == "1s")
        #expect(ToolTimelineRowDisplayState.formatElapsed(45) == "45s")
        #expect(ToolTimelineRowDisplayState.formatElapsed(59) == "59s")
    }

    @Test("formatElapsed minutes")
    func formatMinutes() {
        #expect(ToolTimelineRowDisplayState.formatElapsed(60) == "1m")
        #expect(ToolTimelineRowDisplayState.formatElapsed(72) == "1m 12s")
        #expect(ToolTimelineRowDisplayState.formatElapsed(330) == "5m 30s")
    }

    @Test("formatElapsed hours")
    func formatHours() {
        #expect(ToolTimelineRowDisplayState.formatElapsed(3600) == "1h")
        #expect(ToolTimelineRowDisplayState.formatElapsed(3720) == "1h 2m")
    }

    // MARK: - Reducer timing

    @Test("toolStartTime is set on tool_start")
    func toolStartTimeSet() {
        let reducer = TimelineReducer()
        let toolId = "t1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: [:]))

        #expect(reducer.toolStartTime(for: toolId) != nil)
    }

    @Test("toolStartTime not overwritten on duplicate tool_start")
    func toolStartTimeNotOverwritten() {
        let reducer = TimelineReducer()
        let toolId = "t1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: [:]))

        let firstStart = reducer.toolStartTime(for: toolId)

        // Simulate duplicate tool_start (reconnect/replay)
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: [:]))

        #expect(reducer.toolStartTime(for: toolId) == firstStart)
    }

    @Test("toolElapsed frozen on tool_end")
    func toolElapsedFrozen() {
        let reducer = TimelineReducer()
        let toolId = "t1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: [:]))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolId))

        let elapsed = reducer.toolElapsed(for: toolId)
        #expect(elapsed != nil)
        // Should be 0 since start and end happen in the same runloop tick
        #expect(elapsed == 0)
    }

    @Test("toolElapsed nil for running tool")
    func toolElapsedNilWhileRunning() {
        let reducer = TimelineReducer()
        let toolId = "t1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: [:]))

        #expect(reducer.toolElapsed(for: toolId) == nil)
    }

    @Test("toolElapsed stable across reconfigurations")
    func toolElapsedStable() {
        let reducer = TimelineReducer()
        let toolId = "t1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: [:]))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolId))

        let first = reducer.toolElapsed(for: toolId)
        // Simulate later access (tap to expand, scroll, etc.)
        let second = reducer.toolElapsed(for: toolId)

        #expect(first == second)
    }

    @Test("historical tools have no start time or elapsed")
    func historicalToolsNoTiming() {
        let reducer = TimelineReducer()

        let events: [TraceEvent] = [
            TraceEvent(id: "e1", type: .toolCall, timestamp: "2026-01-01T00:00:00.000Z",
                       text: nil, tool: "bash", args: ["command": .string("ls")],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e1", type: .toolResult, timestamp: "2026-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil,
                       output: "ok", toolCallId: "e1", toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(events)

        #expect(reducer.toolStartTime(for: "e1") == nil)
        #expect(reducer.toolElapsed(for: "e1") == nil)
    }

    @Test("reset clears timing state")
    func resetClearsTiming() {
        let reducer = TimelineReducer()
        let toolId = "t1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: [:]))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolId))

        #expect(reducer.toolStartTime(for: toolId) != nil)
        #expect(reducer.toolElapsed(for: toolId) != nil)

        reducer.reset()

        #expect(reducer.toolStartTime(for: toolId) == nil)
        #expect(reducer.toolElapsed(for: toolId) == nil)
    }

    // MARK: - Display logic

    @Test("applyElapsed hidden when no timing data")
    func applyElapsedHiddenNoData() {
        let label = UILabel()
        ToolTimelineRowDisplayState.applyElapsed(
            startedAt: nil, elapsedSeconds: nil, isDone: true, elapsedLabel: label
        )
        #expect(label.isHidden)
    }

    @Test("applyElapsed hidden for sub-second done tools")
    func applyElapsedHiddenSubSecondDone() {
        let label = UILabel()
        ToolTimelineRowDisplayState.applyElapsed(
            startedAt: nil, elapsedSeconds: 0, isDone: true, elapsedLabel: label
        )
        #expect(label.isHidden)
    }

    @Test("applyElapsed shows frozen value for done tools")
    func applyElapsedFrozenDone() {
        let label = UILabel()
        ToolTimelineRowDisplayState.applyElapsed(
            startedAt: Date.distantPast, elapsedSeconds: 42, isDone: true, elapsedLabel: label
        )
        #expect(!label.isHidden)
        #expect(label.text == "42s")
    }

    @Test("applyElapsed frozen value takes priority over startedAt")
    func applyElapsedFrozenPriority() {
        let label = UILabel()
        // startedAt was long ago, but frozen says 5s
        ToolTimelineRowDisplayState.applyElapsed(
            startedAt: Date(timeIntervalSinceNow: -3600),
            elapsedSeconds: 5,
            isDone: true,
            elapsedLabel: label
        )
        #expect(label.text == "5s")
    }

    @Test("applyElapsed ticks from startedAt when running")
    func applyElapsedTicksWhenRunning() {
        let label = UILabel()
        ToolTimelineRowDisplayState.applyElapsed(
            startedAt: Date(timeIntervalSinceNow: -10),
            elapsedSeconds: nil,
            isDone: false,
            elapsedLabel: label
        )
        #expect(!label.isHidden)
        #expect(label.text == "10s")
    }
}
