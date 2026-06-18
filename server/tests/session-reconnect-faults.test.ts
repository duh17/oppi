import { describe, expect, it } from "vitest";

import { EventRing } from "../src/event-ring.js";
import {
  SessionBroadcaster,
  type BroadcastSessionState,
  type SessionBroadcastEvent,
} from "../src/session-broadcast.js";
import type { ServerMessage, Session } from "../src/types.js";

interface Harness {
  active: BroadcastSessionState;
  broadcaster: SessionBroadcaster;
  emitted: SessionBroadcastEvent[];
}

interface ReconnectSchedule {
  ringCapacity: number;
  eventCount: number;
  disconnectAfter: number;
}

const DURABLE_EVENT_BUILDERS: Array<(index: number) => ServerMessage> = [
  () => ({ type: "agent_start" }) as ServerMessage,
  (index) =>
    ({
      type: "message_end",
      role: index % 2 === 0 ? "assistant" : "user",
      content: `message-${index}`,
    }) as ServerMessage,
  (index) =>
    ({
      type: "tool_start",
      tool: "bash",
      args: { command: `echo ${index}` },
    }) as ServerMessage,
  () => ({ type: "tool_end", tool: "bash" }) as ServerMessage,
  () => ({ type: "compaction_start", reason: "test" }) as ServerMessage,
  () =>
    ({
      type: "compaction_end",
      reason: "test",
      summary: "condensed",
      aborted: false,
      willRetry: false,
    }) as ServerMessage,
  () => ({ type: "retry_start", reason: "test" }) as ServerMessage,
  () => ({ type: "retry_end", reason: "test" }) as ServerMessage,
  () => ({ type: "agent_end" }) as ServerMessage,
];

function makeSession(id = "sess-reconnect"): Session {
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

function createHarness(ringCapacity: number): Harness {
  const emitted: SessionBroadcastEvent[] = [];
  const active: BroadcastSessionState = {
    session: makeSession(),
    subscribers: new Set(),
    seq: 0,
    eventRing: new EventRing(ringCapacity),
  };
  const activeSessions = new Map([[active.session.id, active]]);

  return {
    active,
    emitted,
    broadcaster: new SessionBroadcaster({
      getActiveSession: (key) => activeSessions.get(key),
      emitSessionEvent: (event) => emitted.push(event),
      saveSession: () => {},
    }),
  };
}

function makeDurableMessage(index: number): ServerMessage {
  return DURABLE_EVENT_BUILDERS[(index - 1) % DURABLE_EVENT_BUILDERS.length]!(index);
}

function seqOf(message: ServerMessage): number {
  const seq = (message as { seq?: number }).seq;
  if (typeof seq !== "number") {
    throw new Error(`Expected sequenced message ${message.type} to include seq`);
  }
  return seq;
}

function seqs(messages: ServerMessage[]): number[] {
  return messages.map(seqOf);
}

function range(from: number, to: number): number[] {
  if (to < from) {
    return [];
  }
  return Array.from({ length: to - from + 1 }, (_, offset) => from + offset);
}

function makeSchedules(): ReconnectSchedule[] {
  const schedules: ReconnectSchedule[] = [];
  for (const ringCapacity of [1, 2, 3, 5, 8]) {
    for (let eventCount = 0; eventCount <= 12; eventCount += 1) {
      for (let disconnectAfter = 0; disconnectAfter <= eventCount; disconnectAfter += 1) {
        schedules.push({ ringCapacity, eventCount, disconnectAfter });
      }
    }
  }
  return schedules;
}

function assertSchedule(schedule: ReconnectSchedule): void {
  const { ringCapacity, eventCount, disconnectAfter } = schedule;
  const label = `ring=${ringCapacity}, events=${eventCount}, disconnectAfter=${disconnectAfter}`;
  const { active, broadcaster, emitted } = createHarness(ringCapacity);
  const key = active.session.id;
  const alwaysConnected: ServerMessage[] = [];
  const reconnectingClient: ServerMessage[] = [];

  broadcaster.subscribe(key, (message) => alwaysConnected.push(message));
  const unsubscribeReconnectingClient = broadcaster.subscribe(key, (message) => {
    reconnectingClient.push(message);
  });

  let closeLanded = false;
  const closeReconnectingClient = (): void => {
    if (closeLanded) {
      return;
    }
    closeLanded = true;
    unsubscribeReconnectingClient();
  };

  for (let index = 1; index <= eventCount; index += 1) {
    if (index - 1 === disconnectAfter) {
      closeReconnectingClient();
    }
    broadcaster.broadcast(key, makeDurableMessage(index));
  }

  if (disconnectAfter === eventCount) {
    closeReconnectingClient();
  }

  const canonicalSeqs = emitted.map((event) => seqOf(event.event));
  const lastSeenSeq = reconnectingClient.at(-1) ? seqOf(reconnectingClient.at(-1)!) : 0;
  const catchUp = broadcaster.getCatchUp(key, lastSeenSeq);

  expect(closeLanded, label).toBe(true);
  expect(active.seq, label).toBe(eventCount);
  expect(active.eventRing.currentSeq, label).toBe(eventCount);
  expect(catchUp, label).not.toBeNull();
  expect(canonicalSeqs, label).toEqual(range(1, eventCount));
  expect(new Set(canonicalSeqs).size, label).toBe(canonicalSeqs.length);
  expect(seqs(alwaysConnected), label).toEqual(canonicalSeqs);

  // This is the explicit fault-landing assertion: once the client has
  // disconnected, it receives no further live messages. Any missing events
  // must come through catch-up, not through a leaky subscription.
  expect(seqs(reconnectingClient), label).toEqual(range(1, disconnectAfter));

  const oldestSeq = active.eventRing.oldestSeq;
  const canServe = eventCount === 0 || lastSeenSeq >= oldestSeq - 1;
  expect(catchUp!.currentSeq, label).toBe(eventCount);
  expect(catchUp!.catchUpComplete, label).toBe(canServe);

  if (canServe) {
    expect(seqs(catchUp!.events), label).toEqual(range(lastSeenSeq + 1, eventCount));
  } else {
    // No partial suffix may masquerade as a complete replay when the bounded
    // ring has evicted events the client still needs.
    expect(catchUp!.events, label).toEqual([]);
  }
}

describe("session reconnect faults", () => {
  it("keeps catch-up as a prefix/suffix contract under disconnect and ring eviction", () => {
    for (const schedule of makeSchedules()) {
      assertSchedule(schedule);
    }
  });
});
