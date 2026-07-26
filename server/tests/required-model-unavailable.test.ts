import { describe, expect, it } from "vitest";

import {
  isRequiredModelUnavailableError,
  isRequiredModelUnavailableMessage,
  RequiredModelUnavailableError,
} from "../src/model-resolution.js";
import { enforceLaunchModelPolicy } from "../src/sdk-backend.js";
import type { Session } from "../src/types.js";

function makeRequiredSession(model: string): Session {
  return {
    id: "required-model-session",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    model,
    launch: {
      model,
      modelPolicy: "required",
      status: "launching",
      requestedAt: 1,
    },
  };
}

describe("required model unavailable errors", () => {
  it("classifies the actual SDK policy error", () => {
    const session = makeRequiredSession("openai-codex/gpt-5.6-sol");

    let thrown: unknown;
    try {
      enforceLaunchModelPolicy(session, undefined);
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(RequiredModelUnavailableError);
    expect(isRequiredModelUnavailableError(thrown)).toBe(true);
    expect(isRequiredModelUnavailableMessage((thrown as Error).message)).toBe(true);
  });

  it("recognizes persisted errors when a malformed raw model contains a newline", () => {
    const error = new RequiredModelUnavailableError("provider/model\nvariant");

    expect(isRequiredModelUnavailableError(error)).toBe(true);
    expect(isRequiredModelUnavailableMessage(error.message)).toBe(true);
  });

  it("does not classify unrelated startup errors", () => {
    expect(isRequiredModelUnavailableError(new Error("transport unavailable"))).toBe(false);
    expect(isRequiredModelUnavailableMessage("transport unavailable")).toBe(false);
  });
});
