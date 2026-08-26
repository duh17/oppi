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
  "listWorkspaceQuickActions",
  "prepareWorkspaceQuickActionSelection",
  "createWorkspaceQuickActionSession",
];

const sessionOperationIds = [
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
  "getHostRaw",
  "headHostRaw",
  "createSessionAttachment",
  "putSessionAttachmentContent",
  "createWorkspaceSession",
  "createControlSession",
  "getControlSession",
  "getControlSessionTracePage",
  "getControlSessionTraceOutline",
  "deleteControlSession",
  "stopControlSession",
  "resumeControlSession",
  "getControlSessionEvents",
  "getControlSessionToolOutput",
  "createControlSessionAttachment",
  "putControlSessionAttachmentContent",
  "getControlSessionAttachment",
  "headControlSessionAttachment",
  "getIconAsset",
  "headIconAsset",
  "sendControlSessionCommand",
  "openControlSessionStream",
  "getWorkspaceSession",
  "getWorkspaceSessionTracePage",
  "getWorkspaceSessionTraceOutline",
  "deleteWorkspaceSession",
  "stopWorkspaceSession",
  "resumeWorkspaceSession",
  "forkWorkspaceSession",
  "getSessionEvents",
  "listSessionChanges",
  "getSessionDiff",
  "getSessionRaw",
  "headSessionRaw",
  "getSessionToolOutput",
  "openSessionStream",
  "openAppEventStream",
  "openDictationStream",
  "searchSessions",
  "listSessions",
  "getSession",
  "readSessionTrace",
  "getSessionTrace",
  "getGenericSessionEvents",
  "getSessionDialogs",
  "getSessionAttachment",
  "headSessionAttachment",
  "sendSessionCommand",
  "stopSession",
  "listRecentSessions",
  "getWorkspaceGitSummary",
  "getWorkspaceGitStatus",
  "getWorkspaceGitDiff",
  "listWorkspaceCommits",
  "getWorkspaceCommit",
  "getWorkspaceCommitDiff",
  "listWorkspaceQuickActions",
  "prepareWorkspaceQuickActionSelection",
  "createWorkspaceQuickActionSession",
  "listWorkspaceWorktrees",
  "getWorkspaceWorktreeStatus",
  "previewWorkspaceWorktree",
];

const settingsOperationIds = [
  "getProviderQuotas",
  "getServerStats",
  "getDailyServerStats",
  "getAutoTitleConfig",
  "setAutoTitleConfig",
  "listServerSkills",
  "getServerSkill",
  "getServerSkillFile",
  "setServerSkillEnabled",
  "listServerExtensions",
  "getServerExtension",
  "setServerExtensionEnabled",
  "getMobileOutputGuide",
  "setMobileOutputGuide",
  "getPiSystemPrompt",
  "getPiDefaultTools",
  "setPiDefaultTools",
  "createWorkspace",
  "updateWorkspace",
  "deleteWorkspace",
  "createWorkspaceWorktree",
  "openWorkspaceWorktree",
  "removeWorkspaceWorktree",
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
  "createIconAsset",
  "getIconAsset",
  "headIconAsset",
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
    expect(normalizeRegisteredPathPattern("/files/raw")).toBe("/files/raw");

    expect(normalizeRegisteredPathPattern("/workspaces/ws-1/sessions/s1/raw/src/App.swift")).toBe(
      "/workspaces/:workspaceId/sessions/:sessionId/raw/:path",
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
    expect(normalizeRegisteredPathPattern("/sessions/s1/read")).toBe("/sessions/:sessionId/read");
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

  it("tracks native client route uses", () => {
    const byUse = (use: "session" | "settings") =>
      apiRouteSpecs
        .filter((route) => route.nativeClientUses?.includes(use))
        .map((route) => route.operationId)
        .sort();

    expect(byUse("session")).toEqual([...sessionOperationIds].sort());
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
    expect(byOperationId.has("respondToPermission")).toBe(false);
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

  it("registers the global app event stream as a native session WebSocket", () => {
    const route = apiRouteSpecs.find((candidate) => candidate.operationId === "openAppEventStream");

    expect(route).toMatchObject({
      method: "GET",
      path: "/app/events/stream",
      surface: "core",
      auth: "owner",
      transport: "websocket",
      nativeClientUses: ["session"],
    });
  });

  it("registers the control session stream as an owner-only native WebSocket", () => {
    const route = apiRouteSpecs.find(
      (candidate) => candidate.operationId === "openControlSessionStream",
    );

    expect(route).toMatchObject({
      method: "GET",
      path: "/control-sessions/{sessionId}/stream",
      surface: "core",
      auth: "owner",
      transport: "websocket",
      nativeClientUses: ["session"],
    });
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
});
