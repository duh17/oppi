/**
 * API route contract tests.
 *
 * Verifies workspace-scoped session API paths.
 */

import { describe, expect, it } from "vitest";

const ROUTES = {
  sessionsRecent: /^\/sessions\/recent$/,
  wsSessions: /^\/workspaces\/([^/]+)\/sessions$/,
  wsSessionBuckets: /^\/workspaces\/([^/]+)\/session-buckets$/,
  wsAttention: /^\/workspaces\/([^/]+)\/attention$/,
  wsSessionStop: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stop$/,
  wsSessionResume: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/resume$/,
  wsSessionFork: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/fork$/,
  wsSessionToolOutput: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/tool-output\/([^/]+)$/,
  wsSessionAttachments: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/attachments$/,
  wsSessionAttachmentContent:
    /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/attachments\/([^/]+)\/content$/,
  wsSessionChanges: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/changes$/,
  wsSessionRaw: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/raw\/(.+)$/,
  wsSessionDiff: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/diff$/,
  wsSessionEvents: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/events$/,
  wsSessionDetail: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)$/,
  wsSessionStream: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stream$/,
  wsContents: /^\/workspaces\/([^/]+)\/contents(?:\/(.*))?$/,
  wsRaw: /^\/workspaces\/([^/]+)\/raw\/(.+)$/,
  wsPaths: /^\/workspaces\/([^/]+)\/paths$/,
  wsGitStatus: /^\/workspaces\/([^/]+)\/git\/status$/,
  wsGitChanges: /^\/workspaces\/([^/]+)\/git\/changes$/,
  wsGitDiff: /^\/workspaces\/([^/]+)\/git\/diff$/,
  wsQuickActions: /^\/workspaces\/([^/]+)\/quick-actions$/,
  wsQuickActionSelection: /^\/workspaces\/([^/]+)\/quick-actions\/selection$/,
  wsQuickActionSession: /^\/workspaces\/([^/]+)\/quick-actions\/session$/,
  telemetryMetricKit: /^\/telemetry\/metrickit$/,
  telemetryChatMetrics: /^\/telemetry\/chat-metrics$/,
};

describe("Workspace-scoped API routes", () => {
  it("matches GET /sessions/recent", () => {
    expect("/sessions/recent".match(ROUTES.sessionsRecent)).toBeTruthy();
  });

  it("matches /workspaces/:wid/sessions", () => {
    const m = "/workspaces/ws-abc/sessions".match(ROUTES.wsSessions);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-abc");
  });

  it("matches /workspaces/:wid/session-buckets", () => {
    const m = "/workspaces/ws-abc/session-buckets".match(ROUTES.wsSessionBuckets);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-abc");
  });

  it("matches GET /workspaces/:wid/attention", () => {
    const m = "/workspaces/ws-abc/attention".match(ROUTES.wsAttention);
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

  it("matches POST /workspaces/:wid/sessions/:sid/fork", () => {
    const m = "/workspaces/ws-1/sessions/sess-42/fork".match(ROUTES.wsSessionFork);
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

  it("matches /workspaces/:wid/sessions/:sid/attachments", () => {
    const m = "/workspaces/ws-1/sessions/s1/attachments".match(ROUTES.wsSessionAttachments);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
    expect(m![2]).toBe("s1");
  });

  it("matches /workspaces/:wid/sessions/:sid/attachments/:aid/content", () => {
    const m = "/workspaces/ws-1/sessions/s1/attachments/upl_123/content".match(
      ROUTES.wsSessionAttachmentContent,
    );
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
    expect(m![2]).toBe("s1");
    expect(m![3]).toBe("upl_123");
  });

  it("matches resource-shaped session file routes", () => {
    const changes = "/workspaces/ws-1/sessions/s1/changes".match(ROUTES.wsSessionChanges);
    expect(changes).toBeTruthy();
    expect(changes![1]).toBe("ws-1");
    expect(changes![2]).toBe("s1");

    const raw = "/workspaces/ws-1/sessions/s1/raw/src/App.swift".match(ROUTES.wsSessionRaw);
    expect(raw).toBeTruthy();
    expect(raw![1]).toBe("ws-1");
    expect(raw![2]).toBe("s1");
    expect(raw![3]).toBe("src/App.swift");

    const diff = "/workspaces/ws-1/sessions/s1/diff".match(ROUTES.wsSessionDiff);
    expect(diff).toBeTruthy();
    expect(diff![1]).toBe("ws-1");
    expect(diff![2]).toBe("s1");
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

  it("matches resource-shaped workspace file routes", () => {
    const contents = "/workspaces/ws-1/contents/src".match(ROUTES.wsContents);
    expect(contents).toBeTruthy();
    expect(contents![1]).toBe("ws-1");
    expect(contents![2]).toBe("src");

    const raw = "/workspaces/ws-1/raw/src/App.swift".match(ROUTES.wsRaw);
    expect(raw).toBeTruthy();
    expect(raw![1]).toBe("ws-1");
    expect(raw![2]).toBe("src/App.swift");

    const paths = "/workspaces/ws-1/paths".match(ROUTES.wsPaths);
    expect(paths).toBeTruthy();
    expect(paths![1]).toBe("ws-1");
  });

  it("matches resource-shaped workspace git routes", () => {
    expect("/workspaces/ws-1/git/status".match(ROUTES.wsGitStatus)?.[1]).toBe("ws-1");
    expect("/workspaces/ws-1/git/changes".match(ROUTES.wsGitChanges)?.[1]).toBe("ws-1");
    expect("/workspaces/ws-1/git/diff".match(ROUTES.wsGitDiff)?.[1]).toBe("ws-1");
  });

  it("matches GET /workspaces/:wid/quick-actions", () => {
    const m = "/workspaces/ws-1/quick-actions".match(ROUTES.wsQuickActions);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
  });

  it("matches POST /workspaces/:wid/quick-actions/selection", () => {
    const m = "/workspaces/ws-1/quick-actions/selection".match(ROUTES.wsQuickActionSelection);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
  });

  it("matches POST /workspaces/:wid/quick-actions/session", () => {
    const m = "/workspaces/ws-1/quick-actions/session".match(ROUTES.wsQuickActionSession);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
  });

  it("matches telemetry metrickit route", () => {
    expect("/telemetry/metrickit".match(ROUTES.telemetryMetricKit)).toBeTruthy();
  });

  it("matches telemetry chat metrics route", () => {
    expect("/telemetry/chat-metrics".match(ROUTES.telemetryChatMetrics)).toBeTruthy();
  });
});
