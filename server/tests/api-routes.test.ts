/**
 * API route contract tests.
 *
 * Verifies workspace-scoped session API paths.
 */

import { describe, expect, it } from "vitest";

const ROUTES = {
  sessionsRecent: /^\/sessions\/recent$/,
  wsHome: /^\/workspaces\/([^/]+)\/home$/,
  wsSessionsCreate: /^\/workspaces\/([^/]+)\/sessions$/,
  wsAttention: /^\/workspaces\/([^/]+)\/attention$/,
  wsSessionStop: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stop$/,
  wsSessionResume: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/resume$/,
  wsSessionFork: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/fork$/,
  wsSessionToolOutput: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/tool-output\/([^/]+)$/,
  wsSessionFiles: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/files$/,
  wsSessionOverallDiff: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/overall-diff$/,
  wsSessionEvents: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/events$/,
  wsSessionDetail: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)$/,
  wsSessionStream: /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stream$/,
  wsReviewDiff: /^\/workspaces\/([^/]+)\/review\/diff$/,
  wsReviewCommentsSent: /^\/workspaces\/([^/]+)\/review\/comments\/sent$/,
  wsQuickActions: /^\/workspaces\/([^/]+)\/quick-actions$/,
  wsQuickActionSelection: /^\/workspaces\/([^/]+)\/quick-actions\/selection$/,
  wsQuickActionSession: /^\/workspaces\/([^/]+)\/quick-actions\/session$/,
  permissionsPending: /^\/permissions\/pending$/,
  policyRules: /^\/policy\/rules$/,
  policyRuleDetail: /^\/policy\/rules\/([^/]+)$/,
  policyAudit: /^\/policy\/audit$/,
  policyFallback: /^\/policy\/fallback$/,
  telemetryMetricKit: /^\/telemetry\/metrickit$/,
  telemetryChatMetrics: /^\/telemetry\/chat-metrics$/,
};

describe("Workspace-scoped API routes", () => {
  it("matches GET /sessions/recent", () => {
    expect("/sessions/recent".match(ROUTES.sessionsRecent)).toBeTruthy();
  });

  it("matches GET /workspaces/:wid/home", () => {
    const m = "/workspaces/ws-abc/home".match(ROUTES.wsHome);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-abc");
  });

  it("matches POST /workspaces/:wid/sessions", () => {
    const m = "/workspaces/ws-abc/sessions".match(ROUTES.wsSessionsCreate);
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

  it("matches GET /workspaces/:wid/review/diff", () => {
    const m = "/workspaces/ws-1/review/diff".match(ROUTES.wsReviewDiff);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
  });

  it("matches POST /workspaces/:wid/review/comments/sent", () => {
    const m = "/workspaces/ws-1/review/comments/sent".match(ROUTES.wsReviewCommentsSent);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("ws-1");
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

  it("matches pending permissions snapshot route", () => {
    expect("/permissions/pending".match(ROUTES.permissionsPending)).toBeTruthy();
  });

  it("matches policy rules route", () => {
    expect("/policy/rules".match(ROUTES.policyRules)).toBeTruthy();
  });

  it("matches policy rule detail route", () => {
    const m = "/policy/rules/rule-123".match(ROUTES.policyRuleDetail);
    expect(m).toBeTruthy();
    expect(m![1]).toBe("rule-123");
  });

  it("matches policy audit route", () => {
    expect("/policy/audit".match(ROUTES.policyAudit)).toBeTruthy();
  });

  it("matches policy fallback route", () => {
    expect("/policy/fallback".match(ROUTES.policyFallback)).toBeTruthy();
  });

  it("matches telemetry metrickit route", () => {
    expect("/telemetry/metrickit".match(ROUTES.telemetryMetricKit)).toBeTruthy();
  });

  it("matches telemetry chat metrics route", () => {
    expect("/telemetry/chat-metrics".match(ROUTES.telemetryChatMetrics)).toBeTruthy();
  });
});
