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
  "getWorkspaceHome",
  "getWorkspaceFileIndex",
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

const nativeRuntimeOperationIds = [
  "getHealth",
  "pairDevice",
  "getCurrentUser",
  "getServerInfo",
  "listModels",
  "registerDeviceToken",
  "listWorkspaceCatalog",
  "getWorkspace",
  "getWorkspaceHome",
  "getWorkspaceFileIndex",
  "getWorkspaceFilesRoot",
  "getWorkspaceFile",
  "createUpload",
  "putUploadContent",
  "createWorkspaceSession",
  "getWorkspaceSession",
  "deleteWorkspaceSession",
  "stopWorkspaceSession",
  "resumeWorkspaceSession",
  "forkWorkspaceSession",
  "getSessionEvents",
  "getSessionOverallDiff",
  "getSessionFile",
  "getSessionTouchedFile",
  "getSessionAttachment",
  "getSessionToolOutput",
  "openSessionStream",
  "openSessionAudioStream",
  "searchSessions",
  "listRecentSessions",
  "getWorkspaceGitStatus",
  "listWorkspaceCommits",
  "getWorkspaceCommit",
  "getWorkspaceCommitDiff",
  "getWorkspaceReviewDiff",
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

const nativeAdminOperationIds = [
  "getCodexUsage",
  "getServerStats",
  "getDailyServerStats",
  "updateServerRuntime",
  "getAutoTitleConfig",
  "setAutoTitleConfig",
  "getSubagentConfig",
  "setSubagentConfig",
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
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/home")).toBe(
      "/workspaces/:workspaceId/home",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/files/")).toBe(
      "/workspaces/:workspaceId/files",
    );
    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/files/src/components/Button.tsx")).toBe(
      "/workspaces/:workspaceId/files/:path",
    );
    expect(
      normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/tool-output/tc_abc123"),
    ).toBe("/workspaces/:workspaceId/sessions/:sessionId/tool-output/:toolCallId");
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

  it("tracks native route profiles", () => {
    const byProfile = (profile: "native-runtime" | "native-admin") =>
      apiRouteSpecs
        .filter((route) => route.profiles?.includes(profile))
        .map((route) => route.operationId)
        .sort();

    expect(byProfile("native-runtime")).toEqual([...nativeRuntimeOperationIds].sort());
    expect(byProfile("native-admin")).toEqual([...nativeAdminOperationIds].sort());
  });

  it("keeps internal/debug routes out of native client profiles", () => {
    const allowedInternalProfileOperationIds = new Set(["getHealth"]);
    for (const route of apiRouteSpecs.filter((candidate) => candidate.surface === "internal")) {
      if (allowedInternalProfileOperationIds.has(route.operationId)) continue;
      expect(route.profiles, `${route.operationId} profiles`).toBeUndefined();
    }
  });

  it("demotes standalone attention snapshots out of the native client contract", () => {
    const byOperationId = new Map(apiRouteSpecs.map((route) => [route.operationId, route]));

    expect(byOperationId.get("getWorkspaceAttention")?.surface).toBe("internal");
    expect(byOperationId.get("getWorkspaceAttention")?.profiles).toBeUndefined();
    expect(byOperationId.get("listPendingPermissions")?.surface).toBe("internal");
    expect(byOperationId.get("listPendingPermissions")?.profiles).toBeUndefined();
    expect(byOperationId.get("respondToPermission")?.profiles).toContain("native-runtime");
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

    expect(paths.has("/provider-auth/providers")).toBe(false);
    expect(paths.has("/server/runtime/status")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/prompt-templates")).toBe(false);
    expect(paths.has("/workspaces/{workspaceId}/review/comments/attach-to-turn")).toBe(false);
    expect(
      paths.has("/workspaces/{workspaceId}/sessions/{sessionId}/tool-output/{toolCallId}/full"),
    ).toBe(false);
  });
});
