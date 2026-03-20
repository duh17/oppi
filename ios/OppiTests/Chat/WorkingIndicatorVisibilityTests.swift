import Foundation
import Testing
@testable import Oppi

/// Tests that the working indicator (Game of Life) appears at the right times
/// and doesn't flicker or vanish unexpectedly during agent activity.
///
/// The indicator should show whenever the session is busy but no assistant
/// content is streaming yet. Once `streamingAssistantID` becomes non-nil
/// (text/thinking/tool deltas flowing), the indicator yields to real content.
@Suite("Working indicator visibility")
@MainActor
struct WorkingIndicatorVisibilityTests {
    private let workingID = ChatTimelineCollectionHost.workingIndicatorID
    private let sid = "test-session"

    // MARK: - Indicator should be PRESENT

    @Test func showsWhenBusyAndNoStreaming() {
        let plan = ChatTimelineApplyPlan.build(
            items: [],
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: nil
        )
        #expect(plan.nextIDs.contains(workingID),
                "Indicator must show when busy with no streaming content")
    }

    @Test func showsWhenBusyWithPriorItemsButNoStreaming() {
        let userMsg = ChatItem.userMessage(
            id: "user-1", text: "hello", timestamp: Date()
        )
        let plan = ChatTimelineApplyPlan.build(
            items: [userMsg],
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: nil
        )
        #expect(plan.nextIDs.contains(workingID),
                "Indicator must show after user message while waiting for turn")
    }

    @Test func showsAtEndOfItemList() {
        let userMsg = ChatItem.userMessage(
            id: "user-1", text: "hello", timestamp: Date()
        )
        let plan = ChatTimelineApplyPlan.build(
            items: [userMsg],
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: nil
        )
        #expect(plan.nextIDs.last == workingID,
                "Indicator must be the last item in the timeline")
    }

    @Test func showsAfterLoadMoreWhenEmpty() {
        let plan = ChatTimelineApplyPlan.build(
            items: [],
            hiddenCount: 5,
            isBusy: true,
            streamingAssistantID: nil
        )
        #expect(plan.nextIDs.contains(workingID))
        #expect(plan.nextIDs.last == workingID)
    }

    // MARK: - Indicator should be ABSENT

    @Test func hiddenWhenNotBusy() {
        let plan = ChatTimelineApplyPlan.build(
            items: [],
            hiddenCount: 0,
            isBusy: false,
            streamingAssistantID: nil
        )
        #expect(!plan.nextIDs.contains(workingID),
                "Indicator must not show when session is idle")
    }

    @Test func hiddenWhenStreamingAssistantContent() {
        let assistantMsg = ChatItem.assistantMessage(
            id: "asst-1", text: "thinking...", timestamp: Date()
        )
        let plan = ChatTimelineApplyPlan.build(
            items: [assistantMsg],
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: "asst-1"
        )
        #expect(!plan.nextIDs.contains(workingID),
                "Indicator must hide once assistant content is streaming")
    }

    @Test func hiddenWhenSessionEnds() {
        let plan = ChatTimelineApplyPlan.build(
            items: [.systemEvent(id: "end", message: "Session ended")],
            hiddenCount: 0,
            isBusy: false,
            streamingAssistantID: nil
        )
        #expect(!plan.nextIDs.contains(workingID))
    }

    // MARK: - Transition scenarios (the flicker cases)

    @Test func transitionFromBusyToStreaming() {
        // Step 1: busy, no streaming -> indicator present
        let plan1 = ChatTimelineApplyPlan.build(
            items: [],
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: nil
        )
        #expect(plan1.nextIDs.contains(workingID))

        // Step 2: assistant starts streaming -> indicator gone
        let assistantMsg = ChatItem.assistantMessage(
            id: "asst-1", text: "", timestamp: Date()
        )
        let plan2 = ChatTimelineApplyPlan.build(
            items: [assistantMsg],
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: "asst-1"
        )
        #expect(!plan2.nextIDs.contains(workingID))

        // Indicator should be in the removed set
        let plan2WithRemoved = plan2.withRemovedIDs(from: plan1.nextIDs)
        #expect(plan2WithRemoved.removedIDs.contains(workingID),
                "Indicator should be cleanly removed, not left orphaned")
    }

    @Test func transitionFromStreamingBackToBusy() {
        // Simulates the gap between turns: agentEnd fires clearing
        // streamingAssistantID while session is still busy.
        let assistantMsg = ChatItem.assistantMessage(
            id: "asst-1", text: "done with first part", timestamp: Date()
        )

        // During turn gap: busy but streamingAssistantID went nil
        let plan = ChatTimelineApplyPlan.build(
            items: [assistantMsg],
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: nil
        )
        #expect(plan.nextIDs.contains(workingID),
                "Indicator must reappear in the gap between turns")
        #expect(plan.nextIDs.last == workingID,
                "Indicator must be last (after existing content)")
    }

    @Test func transitionBusyToIdle() {
        // Step 1: busy with indicator
        let plan1 = ChatTimelineApplyPlan.build(
            items: [],
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: nil
        )
        #expect(plan1.nextIDs.contains(workingID))

        // Step 2: session becomes idle -> indicator removed
        let plan2 = ChatTimelineApplyPlan.build(
            items: [.assistantMessage(id: "asst-1", text: "done", timestamp: Date())],
            hiddenCount: 0,
            isBusy: false,
            streamingAssistantID: nil
        )
        #expect(!plan2.nextIDs.contains(workingID))

        let plan2WithRemoved = plan2.withRemovedIDs(from: plan1.nextIDs)
        #expect(plan2WithRemoved.removedIDs.contains(workingID))
    }

    // MARK: - Reducer integration: streamingAssistantID lifecycle

    @Test func reducerKeepsStreamingIDDuringToolExecution() {
        // The reducer keeps streamingAssistantID non-nil during tool execution
        // (turnInProgress + lastAssistantIDThisTurn). This prevents the
        // indicator from flickering between tool calls within the same turn.
        let reducer = TimelineReducer()

        // agentStart -> textDelta -> toolStart
        reducer.process(.agentStart(sessionId: sid))
        reducer.process(.textDelta(sessionId: sid, delta: "Let me check..."))

        #expect(reducer.streamingAssistantID != nil,
                "streamingAssistantID must be set during text streaming")

        // Tool starts: text finalized but turn still in progress
        reducer.process(.toolStart(
            sessionId: sid,
            toolEventId: "tool-1",
            tool: "bash",
            args: ["command": .string("ls")]
        ))

        // streamingAssistantID should STILL be non-nil
        #expect(reducer.streamingAssistantID != nil,
                "streamingAssistantID must persist during tool execution to prevent indicator flicker")
    }

    @Test func reducerClearsStreamingIDOnAgentEnd() {
        let reducer = TimelineReducer()
        reducer.process(.agentStart(sessionId: sid))
        reducer.process(.textDelta(sessionId: sid, delta: "done"))
        reducer.process(.agentEnd(sessionId: sid))

        #expect(reducer.streamingAssistantID == nil,
                "streamingAssistantID must clear on agentEnd")
    }

    @Test func reducerStreamingIDNilBeforeFirstDelta() {
        // Before any content arrives, streamingAssistantID should be nil
        // even after agentStart — no text/thinking has been emitted yet.
        let reducer = TimelineReducer()
        reducer.process(.agentStart(sessionId: sid))

        let streamID = reducer.streamingAssistantID

        let plan = ChatTimelineApplyPlan.build(
            items: reducer.items,
            hiddenCount: 0,
            isBusy: true,
            streamingAssistantID: streamID
        )

        if streamID == nil {
            // No streaming ID -> indicator shows as bridge
            #expect(plan.nextIDs.contains(workingID),
                    "Indicator must show in pre-delta gap after agentStart")
        } else {
            // Streaming ID set -> content row exists, indicator yields
            #expect(!plan.nextIDs.contains(workingID))
        }
    }

    @Test func reducerMultiToolTurnNeverDropsStreamingID() {
        // Full multi-tool turn: text -> tool1 -> text -> tool2 -> text
        // streamingAssistantID should never go nil during the turn.
        let reducer = TimelineReducer()
        reducer.process(.agentStart(sessionId: sid))

        // First text
        reducer.process(.textDelta(sessionId: sid, delta: "Checking..."))
        #expect(reducer.streamingAssistantID != nil, "After first text delta")

        // Tool 1
        reducer.process(.toolStart(sessionId: sid, toolEventId: "t1", tool: "bash", args: [:]))
        #expect(reducer.streamingAssistantID != nil, "During tool 1")

        reducer.process(.toolEnd(sessionId: sid, toolEventId: "t1"))
        #expect(reducer.streamingAssistantID != nil, "After tool 1 end")

        // More text
        reducer.process(.textDelta(sessionId: sid, delta: "Now trying..."))
        #expect(reducer.streamingAssistantID != nil, "After second text delta")

        // Tool 2
        reducer.process(.toolStart(sessionId: sid, toolEventId: "t2", tool: "read", args: [:]))
        #expect(reducer.streamingAssistantID != nil, "During tool 2")

        reducer.process(.toolEnd(sessionId: sid, toolEventId: "t2"))
        #expect(reducer.streamingAssistantID != nil, "After tool 2 end")

        // Final text
        reducer.process(.textDelta(sessionId: sid, delta: "All done"))
        #expect(reducer.streamingAssistantID != nil, "After final text delta")

        // Turn ends
        reducer.process(.agentEnd(sessionId: sid))
        #expect(reducer.streamingAssistantID == nil, "After agentEnd")
    }
}
