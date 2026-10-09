import { describe, expect, it } from "vitest";

import { adaptDurableEvent, createAdapterState } from "../src/durable-event-adapter.js";

describe("durable event adapter", () => {
  it("carries a projected assistant error into agent_end for the shared turn metric path", () => {
    const state = createAdapterState();
    adaptDurableEvent({ type: "run_start" } as never, state);
    adaptDurableEvent(
      {
        type: "message_end",
        entry: {
          id: 4,
          model: [{ role: "assistant", stopReason: "error", errorMessage: "overloaded" }],
        },
      } as never,
      state,
    );
    const events = adaptDurableEvent({ type: "run_end" } as never, state);
    expect(events[0]).toMatchObject({
      type: "agent_end",
      messages: [{ stopReason: "error", errorMessage: "overloaded" }],
    });
    expect(events[1]).toMatchObject({ type: "agent_settled" });
  });

  it("does not invent an error when the projected assistant stopped cleanly", () => {
    const state = createAdapterState();
    adaptDurableEvent(
      {
        type: "message_end",
        entry: { id: 4, model: [{ role: "assistant", stopReason: "stop" }] },
      } as never,
      state,
    );
    const events = adaptDurableEvent({ type: "run_end" } as never, state);
    expect(events[0]).toMatchObject({ type: "agent_end", messages: [] });
  });
});
