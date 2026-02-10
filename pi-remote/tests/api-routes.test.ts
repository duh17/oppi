/**
 * API route contract tests.
 *
 * Tests the route matching and dispatch logic for both the new
 * workspace-scoped (v2) and legacy (v1) session API paths.
 *
 * Uses regex patterns extracted from server.ts to verify that URLs
 * resolve to the correct handler, and that workspace-scoped routes
 * take priority over legacy routes.
 */

import { describe, expect, it } from "vitest";

// ─── Route patterns (mirrors server.ts handleHttp) ───

const ROUTES = {
  // v2 workspace-scoped session routes
  wsSessionsList:      /^\/workspaces\/([^/]+)\/sessions$/,
  wsSessionStop:       /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stop$/,
  wsSessionResume:     /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/resume$/,
  wsSessionToolOutput: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/tool-output\/([^/]+)$/,
  wsSessionFiles:      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/files$/,
  wsSessionDetail:     /^\/workspaces\/([^/]+)\/sessions\/([^/]+)$/,
  wsSessionStream:     /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stream$/,

  // v1 legacy routes
  legacySessions:      /^\/sessions$/,
  legacyStop:          /^\/sessions\/([^/]+)\/stop$/,
  legacyToolOutput:    /^\/sessions\/([^/]+)\/tool-output\/([^/]+)$/,
  legacyFiles:         /^\/sessions\/([^/]+)\/files$/,
  legacyDetail:        /^\/sessions\/([^/]+)$/,
  legacyStream:        /^\/sessions\/([^/]+)\/stream$/,
};

describe("Workspace-scoped API routes (v2)", () => {
  it("matches GET /workspaces/:wid/sessions", () => {
    const m = "/workspaces/ws-abc/sessions".match(ROUTES.wsSessionsList);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-abc");
  });

  it("matches POST /workspaces/:wid/sessions", () => {
    const m = "/workspaces/my-ws/sessions".match(ROUTES.wsSessionsList);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("my-ws");
  });

  it("matches POST /workspaces/:wid/sessions/:sid/stop", () => {
    const m = "/workspaces/ws-1/sessions/sess-42/stop".match(ROUTES.wsSessionStop);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
    expect(m![2]).toBe("sess-42");
  });

  it("matches POST /workspaces/:wid/sessions/:sid/resume", () => {
    const m = "/workspaces/ws-1/sessions/sess-42/resume".match(ROUTES.wsSessionResume);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
    expect(m![2]).toBe("sess-42");
  });

  it("matches GET /workspaces/:wid/sessions/:sid/tool-output/:tid", () => {
    const m = "/workspaces/ws-1/sessions/s1/tool-output/tc_abc123".match(ROUTES.wsSessionToolOutput);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
    expect(m![2]).toBe("s1");
    expect(m![3]).toBe("tc_abc123");
  });

  it("matches GET /workspaces/:wid/sessions/:sid/files", () => {
    const m = "/workspaces/ws-1/sessions/s1/files".match(ROUTES.wsSessionFiles);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
    expect(m![2]).toBe("s1");
  });

  it("matches GET /workspaces/:wid/sessions/:sid", () => {
    const m = "/workspaces/ws-1/sessions/s1".match(ROUTES.wsSessionDetail);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
    expect(m![2]).toBe("s1");
  });

  it("matches WS /workspaces/:wid/sessions/:sid/stream", () => {
    const m = "/workspaces/ws-1/sessions/s1/stream".match(ROUTES.wsSessionStream);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
    expect(m![2]).toBe("s1");
  });
});

describe("Legacy session routes (v1 compat)", () => {
  it("matches GET/POST /sessions", () => {
    expect("/sessions".match(ROUTES.legacySessions)).toBeTruthy();
  });

  it("matches POST /sessions/:id/stop", () => {
    const m = "/sessions/sess-1/stop".match(ROUTES.legacyStop);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("sess-1");
  });

  it("matches GET /sessions/:id/tool-output/:tid", () => {
    const m = "/sessions/s1/tool-output/tc_abc".match(ROUTES.legacyToolOutput);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("s1");
    expect(m![2]).toBe("tc_abc");
  });

  it("matches GET /sessions/:id/files", () => {
    const m = "/sessions/s1/files".match(ROUTES.legacyFiles);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("s1");
  });

  it("matches GET/DELETE /sessions/:id", () => {
    const m = "/sessions/s1".match(ROUTES.legacyDetail);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("s1");
  });

  it("matches WS /sessions/:id/stream", () => {
    const m = "/sessions/s1/stream".match(ROUTES.legacyStream);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("s1");
  });
});

describe("Route priority: v2 workspace routes take precedence", () => {
  it("workspace session path does NOT match legacy session pattern", () => {
    // /workspaces/ws-1/sessions should NOT match /sessions
    expect("/workspaces/ws-1/sessions".match(ROUTES.legacySessions)).toBeFalsy();
  });

  it("workspace session detail does NOT match legacy detail", () => {
    // /workspaces/ws-1/sessions/s1 should NOT match /sessions/:id
    // because /sessions/:id only matches single-segment after /sessions/
    expect("/workspaces/ws-1/sessions/s1".match(ROUTES.legacyDetail)).toBeFalsy();
  });

  it("workspace session stop does NOT match legacy stop", () => {
    expect("/workspaces/ws-1/sessions/s1/stop".match(ROUTES.legacyStop)).toBeFalsy();
  });

  it("workspace session stream does NOT match legacy stream", () => {
    expect("/workspaces/ws-1/sessions/s1/stream".match(ROUTES.legacyStream)).toBeFalsy();
  });
});
