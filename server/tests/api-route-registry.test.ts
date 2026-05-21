import { describe, expect, it } from "vitest";

import { apiRouteSpecs, normalizeRegisteredPathPattern } from "../src/routes/registry.js";

const bodylessPostOperationIds = new Set(["stopWorkspaceSession", "resumeWorkspaceSession"]);

const initialSchemaOperationIds = [
  "getHealth",
  "getCurrentUser",
  "listModels",
  "listWorkspaceCatalog",
  "createWorkspace",
  "getWorkspace",
  "updateWorkspace",
  "deleteWorkspace",
  "getWorkspacePaths",
  "createWorkspaceSession",
  "getWorkspaceSession",
  "deleteWorkspaceSession",
  "stopWorkspaceSession",
  "resumeWorkspaceSession",
  "forkWorkspaceSession",
  "getSessionEvents",
  "getSessionToolOutput",
  "listRecentSessions",
  "listReviewComments",
  "createReviewComment",
  "markReviewCommentsSent",
  "updateReviewComment",
  "deleteReviewComment",
  "listWorkspaceQuickActions",
  "prepareWorkspaceQuickActionSelection",
  "createWorkspaceQuickActionSession",
  "respondToPermission",
];

const supervisionOperationIds = [
  "getHealth",
  "pairDevice",
  "getCurrentUser",
  "getServerInfo",
  "listModels",
  "registerDeviceToken",
  "listWorkspaceCatalog",
  "getWorkspace",
  "listWorkspaceSessions",
  "listWorkspaceSessionBuckets",
  "getWorkspacePaths",
  "getWorkspaceContentsRoot",
  "getWorkspaceContents",
  "getWorkspaceRaw",
  "createSessionAttachment",
  "putSessionAttachmentContent",
  "createWorkspaceSession",
  "getWorkspaceSession",
  "deleteWorkspaceSession",
  "stopWorkspaceSession",
  "resumeWorkspaceSession",
  "forkWorkspaceSession",
  "getSessionEvents",
  "listSessionChanges",
  "getSessionDiff",
  "getSessionRaw",
  "getSessionAttachment",
  "getSessionToolOutput",
  "openSessionStream",
  "openSessionAudioStream",
  "searchSessions",
  "listSessions",
  "listRecentSessions",
  "getWorkspaceGitStatus",
  "listWorkspaceGitChanges",
  "getWorkspaceGitDiff",
  "listWorkspaceCommits",
  "getWorkspaceCommit",
  "getWorkspaceCommitDiff",
  "listReviewComments",
  "createReviewComment",
  "markReviewCommentsSent",
  "updateReviewComment",
  "deleteReviewComment",
  "listWorkspaceQuickActions",
  "prepareWorkspaceQuickActionSelection",
  "createWorkspaceQuickActionSession",
  "respondToPermission",
];

const settingsOperationIds = [
  "getCodexUsage",
  "getServerStats",
  "getDailyServerStats",
  "updateServerRuntime",
  "getAutoTitleConfig",
  "setAutoTitleConfig",
  "getAutoPermissionConfig",
  "setAutoPermissionConfig",
  "createWorkspace",
  "updateWorkspace",
  "deleteWorkspace",
  "getPolicyFallback",
  "updatePolicyFallback",
  "listPolicyRules",
  "createPolicyRule",
  "updatePolicyRule",
  "deletePolicyRule",
  "listPolicyAudit",
  "listProviderAuthStatus",
  "startProviderAuthFlow",
  "getProviderAuthFlow",
  "submitProviderAuthPromptResponse",
  "submitProviderAuthManualCode",
  "cancelProviderAuthFlow",
  "setProviderApiKey",
  "removeProviderCredential",
  "listSkills",
  "getSkill",
  "getSkillFile",
  "listExtensions",
  "listHostDirectories",
  "getHostPathStatus",
  "completeHostPath",
  "createHostPath",
  "listThemes",
  "getTheme",
  "uploadMetricKitPayload",
  "uploadChatMetrics",
];

describe("api route registry", () => {
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
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/raw/src/components/Button.tsx")).toBe(
      "/workspaces/:workspaceId/raw/:path",
    );

    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/raw/src/App.swift")).toBe(
      "/workspaces/:workspaceId/sessions/:sessionId/raw/:path",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/changes")).toBe(
      "/workspaces/:workspaceId/sessions/:sessionId/changes",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/diff")).toBe(
      "/workspaces/:workspaceId/sessions/:sessionId/diff",
    );
    expect(
      normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/tool-output/tc_abc123"),
    ).toBe("/workspaces/:workspaceId/sessions/:sessionId/tool-output/:toolCallId");
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/git/status")).toBe(
      "/workspaces/:workspaceId/git/status",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/git/diff")).toBe(
      "/workspaces/:workspaceId/git/diff",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/review/comments/rc-1")).toBe(
      "/workspaces/:workspaceId/review/comments/:commentId",
    );
    expect(normalizeRegisteredPathPattern("/provider-auth/flows/flow-1/manual-code")).toBe(
      "/provider-auth/flows/:flowId/manual-code",
    );
    expect(normalizeRegisteredPathPattern("/server/stats/daily/2026-05-19")).toBe(
      "/server/stats/daily/:date",
    );
  });

  it("tracks native client route uses", () => {
    const byUse = (use: "supervision" | "settings") =>
      apiRouteSpecs
        .filter((route) => route.nativeClientUses?.includes(use))
        .map((route) => route.operationId)
        .sort();

    expect(byUse("supervision")).toEqual([...supervisionOperationIds].sort());
    expect(byUse("settings")).toEqual([...settingsOperationIds].sort());
  });

  it("keeps internal/debug routes out of native client uses", () => {
    const allowedInternalProfileOperationIds = new Set(["getHealth"]);
    for (const route of apiRouteSpecs.filter((candidate) => candidate.surface === "internal")) {
      if (allowedInternalProfileOperationIds.has(route.operationId)) continue;
      expect(route.nativeClientUses, `${route.operationId} native client uses`).toBeUndefined();
    }
  });

  it("demotes standalone attention snapshots out of the native client contract", () => {
    const byOperationId = new Map(apiRouteSpecs.map((route) => [route.operationId, route]));

    expect(byOperationId.get("getWorkspaceAttention")?.surface).toBe("internal");
    expect(byOperationId.get("getWorkspaceAttention")?.nativeClientUses).toBeUndefined();
    expect(byOperationId.get("respondToPermission")?.nativeClientUses).toContain("supervision");
  });

  it("tracks the initial schema-covered route set", () => {
    const covered = apiRouteSpecs
      .filter((route) => route.schemas)
      .map((route) => route.operationId)
      .sort();

    expect(covered).toEqual([...initialSchemaOperationIds].sort());
  });

  it("keeps schema-covered routes ready for a future OpenAPI emitter", () => {
    for (const route of apiRouteSpecs.filter((candidate) => candidate.schemas)) {
      expect(route.schemas?.response, `${route.operationId} response schema`).toBeDefined();
      expect(route.schemas?.error, `${route.operationId} error schema`).toBeDefined();
      if (route.path.includes("{")) {
        expect(route.schemas?.path, `${route.operationId} path schema`).toBeDefined();
      }
      const shouldHaveBodySchema =
        route.method === "PUT" ||
        route.method === "PATCH" ||
        (route.method === "POST" && !bodylessPostOperationIds.has(route.operationId));
      if (shouldHaveBodySchema) {
        expect(route.schemas?.body, `${route.operationId} body schema`).toBeDefined();
      }
    }
  });

  it("does not register retired cleanup routes", () => {
    const paths = new Set(apiRouteSpecs.map((route) => route.path));

    expect(paths.has("/workspaces/{workspaceId}/home")).toBe(false);
    expect(paths.has("/provider-auth/providers")).toBe(false);
    expect(paths.has("/server/runtime/status")).toBe(false);
    expect(paths.has("/server/subagents")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/prompt-templates")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/review/comments/attach-to-turn")).toBe(false);
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
  });
});
