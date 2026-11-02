import { describe, expect, it } from "vitest";

import { apiRouteSpecs, normalizeRegisteredPathPattern } from "../src/routes/registry.js";

describe("api route registry", () => {
  it("normalizes MCP scope/server/flow identities", () => {
    expect(normalizeRegisteredPathPattern("/mcp/scopes/workspace-123/servers/echo/login")).toBe(
      "/mcp/scopes/:scopeId/servers/:name/login",
    );
    expect(normalizeRegisteredPathPattern("/mcp/auth/flows/pa_test/manual-code")).toBe(
      "/mcp/auth/flows/:flowId/manual-code",
    );
  });

  it("keeps operation ids unique", () => {
    const ids = apiRouteSpecs.map((route) => route.operationId);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("keeps method + path entries unique", () => {
    const keys = apiRouteSpecs.map((route) => `${route.method} ${route.path}`);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("normalizes high-cardinality route paths for metrics", () => {
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/contents/")).toBe(
      "/workspaces/:workspaceId/contents",
    );
    expect(
      normalizeRegisteredPathPattern("/workspaces/ws-1/contents/src/components/Button.tsx"),
    ).toBe("/workspaces/:workspaceId/contents/:path");
    expect(normalizeRegisteredPathPattern("/files/current")).toBe("/files/current");
    expect(normalizeRegisteredPathPattern("/host/contents")).toBe("/host/contents");
    expect(normalizeRegisteredPathPattern("/host/contents/")).toBe("/host/contents");
    expect(normalizeRegisteredPathPattern("/host/contents/Documents/notes")).toBe(
      "/host/contents/:path",
    );

    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/changes")).toBe(
      "/workspaces/:workspaceId/sessions/:sessionId/changes",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/diff")).toBe(
      "/workspaces/:workspaceId/sessions/:sessionId/diff",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/trace-page")).toBe(
      "/workspaces/:workspaceId/sessions/:sessionId/trace-page",
    );
    expect(
      normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/tool-output/tc_abc123"),
    ).toBe("/workspaces/:workspaceId/sessions/:sessionId/tool-output/:toolCallId");
    expect(normalizeRegisteredPathPattern("/sessions/recent")).toBe("/sessions/recent");
    expect(normalizeRegisteredPathPattern("/sessions/s1")).toBe("/sessions/:sessionId");
    expect(normalizeRegisteredPathPattern("/sessions/s1/trace")).toBe("/sessions/:sessionId/trace");
    expect(normalizeRegisteredPathPattern("/sessions/s1/events")).toBe(
      "/sessions/:sessionId/events",
    );
    expect(normalizeRegisteredPathPattern("/sessions/s1/dialogs")).toBe(
      "/sessions/:sessionId/dialogs",
    );
    expect(normalizeRegisteredPathPattern("/sessions/s1/attachments/att-image")).toBe(
      "/sessions/:sessionId/attachments/:attachmentId",
    );
    expect(normalizeRegisteredPathPattern("/sessions/s1/command")).toBe(
      "/sessions/:sessionId/command",
    );
    expect(normalizeRegisteredPathPattern("/sessions/s1/stop")).toBe("/sessions/:sessionId/stop");
    expect(normalizeRegisteredPathPattern("/control-sessions")).toBe("/control-sessions");
    expect(normalizeRegisteredPathPattern("/control-sessions/s1/trace-page")).toBe(
      "/control-sessions/:sessionId/trace-page",
    );
    expect(normalizeRegisteredPathPattern("/control-sessions/s1/tool-output/tc-1")).toBe(
      "/control-sessions/:sessionId/tool-output/:toolCallId",
    );
    expect(normalizeRegisteredPathPattern("/control-sessions/s1/stream")).toBe(
      "/control-sessions/:sessionId/stream",
    );
    expect(normalizeRegisteredPathPattern("/agents")).toBe("/agents");
    expect(normalizeRegisteredPathPattern("/agents/reviewer")).toBe("/agents/:agentId");
    expect(normalizeRegisteredPathPattern("/agents/reviewer/sessions")).toBe(
      "/agents/:agentId/sessions",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/worktrees/open")).toBe(
      "/workspaces/:workspaceId/worktrees/open",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/worktrees/wt_feature/status")).toBe(
      "/workspaces/:workspaceId/worktrees/:worktreeId/status",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/worktrees/wt_feature/preview")).toBe(
      "/workspaces/:workspaceId/worktrees/:worktreeId/preview",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/worktrees/wt_feature")).toBe(
      "/workspaces/:workspaceId/worktrees/:worktreeId",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/git/summary")).toBe(
      "/workspaces/:workspaceId/git/summary",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/git/status")).toBe(
      "/workspaces/:workspaceId/git/status",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/git/diff")).toBe(
      "/workspaces/:workspaceId/git/diff",
    );
    expect(normalizeRegisteredPathPattern("/provider-auth/flows/flow-1/manual-code")).toBe(
      "/provider-auth/flows/:flowId/manual-code",
    );
    expect(normalizeRegisteredPathPattern("/server/stats/daily/2026-05-19")).toBe(
      "/server/stats/daily/:date",
    );
    expect(
      normalizeRegisteredPathPattern(
        "/server/resources/skills/skill_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/file",
      ),
    ).toBe("/server/resources/skills/:skillId/file");
    expect(
      normalizeRegisteredPathPattern(
        "/server/resources/extensions/extension_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/enabled",
      ),
    ).toBe("/server/resources/extensions/:extensionId/enabled");
  });

  it("does not register retired cleanup routes", () => {
    const paths = new Set(apiRouteSpecs.map((route) => route.path));

    expect(paths.has("/workspaces/{workspaceId}/home")).toBe(false);
    expect(paths.has("/provider-auth/providers")).toBe(false);
    expect(paths.has("/server/runtime/status")).toBe(false);
    expect(paths.has("/server/runtime/update")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/prompt-templates")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/review/comments/attach-to-turn")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/sessions/{sessionId}/audio/stream")).toBe(false);
    expect(paths.has("/tui-sessions")).toBe(false);
    expect(paths.has("/me/skills")).toBe(false);
    expect(paths.has("/me/skills/{skillName}")).toBe(false);
    expect(
      paths.has("/workspaces/{workspaceId}/sessions/{sessionId}/tool-output/{toolCallId}/full"),
    ).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/file-index")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/files")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/files/{path+}")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/uploads")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/uploads/{uploadId}/content")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/sessions/{sessionId}/files")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/sessions/{sessionId}/touched-file")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/sessions/{sessionId}/overall-diff")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/git-status")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/review/diff")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/git/changes")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/system-prompt/base")).toBe(false);
  });

  it("has no legacy raw byte routes; the only file write is workspace-origin /files/current", () => {
    const legacyRawPaths = [
      "/workspaces/ws-1/raw/src/App.swift",
      "/files/raw",
      "/workspaces/ws-1/sessions/s1/raw/src/App.swift",
    ];
    for (const path of legacyRawPaths) {
      expect(normalizeRegisteredPathPattern(path), path).toBeUndefined();
    }

    const fileWrites = apiRouteSpecs.filter(
      (route) =>
        (route.method === "PUT" || route.method === "POST" || route.method === "PATCH") &&
        (route.path.includes("/raw") || route.path.startsWith("/files/")),
    );
    expect(fileWrites.map((route) => `${route.method} ${route.path}`)).toEqual([
      "PUT /files/current",
    ]);
  });
});
