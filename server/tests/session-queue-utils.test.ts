import { describe, expect, it } from "vitest";

import { parseQueueState } from "../src/session-queue-utils.js";

describe("parseQueueState", () => {
  const state = { version: 3, steering: [], followUp: [] };

  it("reads a bare state and one nested under queue", () => {
    expect(parseQueueState(state)).toEqual(state);
    expect(parseQueueState({ queue: state })).toEqual(state);
  });

  it("rejects an array as a state", () => {
    expect(parseQueueState([])).toBeUndefined();
  });
});
