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
  "getWorkspaceAttention",
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
  "listPendingPermissions",
  "respondToPermission",
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
