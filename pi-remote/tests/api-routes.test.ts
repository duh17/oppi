/**
 * API route contract tests.
 *
 * Verifies workspace-scoped session API paths and rejects removed legacy
 * `/sessions*` routes.
 */

import { describe, expect, it } from "vitest";

const ROUTES = {
  wsSessionsList: /^\/workspaces\/([^/]+)\/sessions$/,
  wsSessionStop: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stop$/,
  wsSessionResume: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/resume$/,
  wsSessionToolOutput: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/tool-output\/([^/]+)$/,
  wsSessionFiles: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/files$/,
  wsSessionOverallDiff: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/overall-diff$/,
  wsSessionEvents: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/events$/,
  wsSessionDetail: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)$/,
  wsSessionStream: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stream$/,
  userStream: /^\/stream$/,
  userStreamEvents: /^\/stream\/events$/,
  permissionsPending: /^\/permissions\/pending$/,
  securityProfile: /^\/security\/profile$/,
  policyProfile: /^\/policy\/profile$/,
  policyRules: /^\/policy\/rules$/,
  policyAudit: /^\/policy\/audit$/,
};

const ROUTE_PATTERNS = Object.values(ROUTES);

function matchesAnyRoute(path: string): boolean {
  return ROUTE_PATTERNS.some((pattern) => pattern.test(path));
}

describe("Workspace-scoped API routes", () => {
  it("matches GET /workspaces/:wid/sessions", () => {
    const m = "/workspaces/ws-abc/sessions".match(ROUTES.wsSessionsList);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-abc");
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
    const m = "/workspaces/ws-1/sessions/s1/tool-output/tc_abc123".match(
      ROUTES.wsSessionToolOutput,
    );
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

  it("matches GET /workspaces/:wid/sessions/:sid/overall-diff", () => {
    const m = "/workspaces/ws-1/sessions/s1/overall-diff".match(ROUTES.wsSessionOverallDiff);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
    expect(m![2]).toBe("s1");
  });

  it("matches GET /workspaces/:wid/sessions/:sid/events", () => {
    const m = "/workspaces/ws-1/sessions/s1/events".match(ROUTES.wsSessionEvents);
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

  it("matches multiplexed WS /stream", () => {
    expect("/stream".match(ROUTES.userStream)).toBeTruthy();
  });

  it("matches user stream events catch-up route", () => {
    expect("/stream/events".match(ROUTES.userStreamEvents)).toBeTruthy();
  });

  it("matches pending permissions snapshot route", () => {
    expect("/permissions/pending".match(ROUTES.permissionsPending)).toBeTruthy();
  });

  it("matches security profile route", () => {
    expect("/security/profile".match(ROUTES.securityProfile)).toBeTruthy();
  });

  it("matches policy profile route", () => {
    expect("/policy/profile".match(ROUTES.policyProfile)).toBeTruthy();
  });

  it("matches policy rules route", () => {
    expect("/policy/rules".match(ROUTES.policyRules)).toBeTruthy();
  });

  it("matches policy audit route", () => {
    expect("/policy/audit".match(ROUTES.policyAudit)).toBeTruthy();
  });
});

describe("Removed legacy session routes", () => {
  const legacyPaths = [
    "/sessions",
    "/sessions/s1",
    "/sessions/s1/stop",
    "/sessions/s1/events",
    "/sessions/s1/files",
    "/sessions/s1/client-logs",
    "/sessions/s1/tool-output/tc_abc",
    "/sessions/s1/stream",
  ];

  it.each(legacyPaths)("does not match removed path %s", (path) => {
    expect(matchesAnyRoute(path)).toBe(false);
  });
});
