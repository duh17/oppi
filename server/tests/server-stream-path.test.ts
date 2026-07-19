import { describe, expect, it } from "vitest";
import { matchFocusedSessionStreamPath } from "../src/server.js";

describe("focused session stream paths", () => {
  it("matches workspace and control paths without conflating their scopes", () => {
    expect(matchFocusedSessionStreamPath("/workspaces/ws-1/sessions/session-1/stream")).toEqual({
      scope: "workspace",
      workspaceId: "ws-1",
      sessionId: "session-1",
    });
    expect(matchFocusedSessionStreamPath("/control-sessions/control-1/stream")).toEqual({
      scope: "control",
      sessionId: "control-1",
    });
    expect(matchFocusedSessionStreamPath("/sessions/control-1/stream")).toBeNull();
  });
});
