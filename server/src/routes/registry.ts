export type HttpMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
export type RouteSurface = "core" | "admin" | "internal";
export type RouteAuth = "none" | "owner" | "query-token-browse";
export type RouteTransport = "http" | "websocket";

export type SchemaRef = `#/components/schemas/${string}`;

export interface ApiRouteSchemas {
  path?: SchemaRef;
  query?: SchemaRef;
  body?: SchemaRef;
  response?: SchemaRef;
  error?: SchemaRef;
}

export interface ApiRouteSpec {
  method: HttpMethod;
  path: string;
  operationId: string;
  surface: RouteSurface;
  auth: RouteAuth;
  transport?: RouteTransport;
  description?: string;
  schemas?: ApiRouteSchemas;
}

const schemaRef = (name: string): SchemaRef => `#/components/schemas/${name}` as SchemaRef;
const errorResponse = schemaRef("ErrorResponse");

export const apiRouteSpecs = [
  {
    method: "GET",
    path: "/health",
    operationId: "getHealth",
    surface: "internal",
    auth: "none",
    schemas: { response: schemaRef("HealthResponse"), error: errorResponse },
  },
  { method: "POST", path: "/pair", operationId: "pairDevice", surface: "admin", auth: "none" },
  {
    method: "GET",
    path: "/me",
    operationId: "getCurrentUser",
    surface: "core",
    auth: "owner",
    schemas: { response: schemaRef("CurrentUserResponse"), error: errorResponse },
  },

  {
    method: "GET",
    path: "/server/info",
    operationId: "getServerInfo",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/codex-usage",
    operationId: "getCodexUsage",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/stats",
    operationId: "getServerStats",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/stats/daily/{date}",
    operationId: "getDailyServerStats",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/server/runtime/update",
    operationId: "updateServerRuntime",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/auto-title",
    operationId: "getAutoTitleConfig",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/auto-title",
    operationId: "setAutoTitleConfig",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/subagents",
    operationId: "getSubagentConfig",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/subagents",
    operationId: "setSubagentConfig",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/models",
    operationId: "listModels",
    surface: "core",
    auth: "owner",
    schemas: { response: schemaRef("ModelsResponse"), error: errorResponse },
  },
  {
    method: "POST",
    path: "/me/device-token",
    operationId: "registerDeviceToken",
    surface: "admin",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/workspaces",
    operationId: "listWorkspaceCatalog",
    surface: "core",
    auth: "owner",
    schemas: { response: schemaRef("WorkspaceCatalogResponse"), error: errorResponse },
  },
  {
    method: "POST",
    path: "/workspaces",
    operationId: "createWorkspace",
    surface: "admin",
    auth: "owner",
    schemas: {
      body: schemaRef("CreateWorkspaceRequest"),
      response: schemaRef("WorkspaceResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}",
    operationId: "getWorkspace",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      response: schemaRef("WorkspaceResponse"),
      error: errorResponse,
    },
  },
  {
    method: "PUT",
    path: "/workspaces/{workspaceId}",
    operationId: "updateWorkspace",
    surface: "admin",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      body: schemaRef("UpdateWorkspaceRequest"),
      response: schemaRef("WorkspaceResponse"),
      error: errorResponse,
    },
  },
  {
    method: "DELETE",
    path: "/workspaces/{workspaceId}",
    operationId: "deleteWorkspace",
    surface: "admin",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      response: schemaRef("OkResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/home",
    operationId: "getWorkspaceHome",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      query: schemaRef("WorkspaceHomeQuery"),
      response: schemaRef("WorkspaceHomeResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/attention",
    operationId: "getWorkspaceAttention",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      response: schemaRef("WorkspaceAttentionResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/file-index",
    operationId: "getWorkspaceFileIndex",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      response: schemaRef("FileIndexResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/files",
    operationId: "getWorkspaceFilesRoot",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/files/{path+}",
    operationId: "getWorkspaceFile",
    surface: "core",
    auth: "query-token-browse",
  },

  {
    method: "POST",
    path: "/workspaces/{workspaceId}/uploads",
    operationId: "createUpload",
    surface: "core",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/workspaces/{workspaceId}/uploads/{uploadId}/content",
    operationId: "putUploadContent",
    surface: "core",
    auth: "owner",
  },

  {
    method: "POST",
    path: "/workspaces/{workspaceId}/sessions",
    operationId: "createWorkspaceSession",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      body: schemaRef("CreateSessionRequest"),
      response: schemaRef("SessionResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}",
    operationId: "getWorkspaceSession",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspaceSessionPathParams"),
      query: schemaRef("SessionTraceQuery"),
      response: schemaRef("SessionDetailResponse"),
      error: errorResponse,
    },
  },
  {
    method: "DELETE",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}",
    operationId: "deleteWorkspaceSession",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspaceSessionPathParams"),
      response: schemaRef("OkResponse"),
      error: errorResponse,
    },
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/stop",
    operationId: "stopWorkspaceSession",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspaceSessionPathParams"),
      response: schemaRef("SessionResponse"),
      error: errorResponse,
    },
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/resume",
    operationId: "resumeWorkspaceSession",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspaceSessionPathParams"),
      response: schemaRef("SessionResponse"),
      error: errorResponse,
    },
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/fork",
    operationId: "forkWorkspaceSession",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspaceSessionPathParams"),
      body: schemaRef("ForkSessionRequest"),
      response: schemaRef("SessionResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/events",
    operationId: "getSessionEvents",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspaceSessionPathParams"),
      query: schemaRef("SessionEventsQuery"),
      response: schemaRef("SessionEventsResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/overall-diff",
    operationId: "getSessionOverallDiff",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/files",
    operationId: "getSessionFile",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/touched-file",
    operationId: "getSessionTouchedFile",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/attachments/{attachmentId}",
    operationId: "getSessionAttachment",
    surface: "core",
    auth: "query-token-browse",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/tool-output/{toolCallId}",
    operationId: "getSessionToolOutput",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("ToolOutputPathParams"),
      query: schemaRef("ToolOutputQuery"),
      response: schemaRef("ToolOutputResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/stream",
    operationId: "openSessionStream",
    surface: "core",
    auth: "owner",
    transport: "websocket",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/audio/stream",
    operationId: "openSessionAudioStream",
    surface: "core",
    auth: "owner",
    transport: "websocket",
  },

  {
    method: "GET",
    path: "/sessions/search",
    operationId: "searchSessions",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/sessions/recent",
    operationId: "listRecentSessions",
    surface: "core",
    auth: "owner",
    schemas: {
      query: schemaRef("RecentSessionsQuery"),
      response: schemaRef("WorkspaceSessionSummariesResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/local-sessions",
    operationId: "listLocalSessions",
    surface: "internal",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/tui-sessions",
    operationId: "listTuiSessions",
    surface: "internal",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/workspaces/{workspaceId}/git-status",
    operationId: "getWorkspaceGitStatus",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/git/commits",
    operationId: "listWorkspaceCommits",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/git/commits/{commit}",
    operationId: "getWorkspaceCommit",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/git/commits/{commit}/diff",
    operationId: "getWorkspaceCommitDiff",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/review/diff",
    operationId: "getWorkspaceReviewDiff",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/review/comments",
    operationId: "listReviewComments",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      query: schemaRef("ReviewCommentsQuery"),
      response: schemaRef("ReviewCommentsResponse"),
      error: errorResponse,
    },
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/review/comments",
    operationId: "createReviewComment",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      body: schemaRef("CreateReviewCommentRequest"),
      response: schemaRef("ReviewCommentResponse"),
      error: errorResponse,
    },
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/review/comments/sent",
    operationId: "markReviewCommentsSent",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      body: schemaRef("MarkReviewCommentsSentRequest"),
      response: schemaRef("ReviewCommentsResponse"),
      error: errorResponse,
    },
  },
  {
    method: "PATCH",
    path: "/workspaces/{workspaceId}/review/comments/{commentId}",
    operationId: "updateReviewComment",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("ReviewCommentPathParams"),
      body: schemaRef("UpdateReviewCommentRequest"),
      response: schemaRef("ReviewCommentResponse"),
      error: errorResponse,
    },
  },
  {
    method: "DELETE",
    path: "/workspaces/{workspaceId}/review/comments/{commentId}",
    operationId: "deleteReviewComment",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("ReviewCommentPathParams"),
      response: schemaRef("OkResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/quick-actions",
    operationId: "listWorkspaceQuickActions",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      response: schemaRef("WorkspaceQuickActionsResponse"),
      error: errorResponse,
    },
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/quick-actions/selection",
    operationId: "prepareWorkspaceQuickActionSelection",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      body: schemaRef("WorkspaceQuickActionSelectionRequest"),
      response: schemaRef("WorkspaceQuickActionSelectionResponse"),
      error: errorResponse,
    },
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/quick-actions/session",
    operationId: "createWorkspaceQuickActionSession",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("WorkspacePathParams"),
      body: schemaRef("CreateWorkspaceQuickActionSessionRequest"),
      response: schemaRef("WorkspaceQuickActionSessionResponse"),
      error: errorResponse,
    },
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/system-prompt/base",
    operationId: "getWorkspaceBaseSystemPrompt",
    surface: "internal",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/permissions/pending",
    operationId: "listPendingPermissions",
    surface: "core",
    auth: "owner",
    schemas: { response: schemaRef("PendingPermissionsResponse"), error: errorResponse },
  },
  {
    method: "POST",
    path: "/permissions/{requestId}/respond",
    operationId: "respondToPermission",
    surface: "core",
    auth: "owner",
    schemas: {
      path: schemaRef("PermissionPathParams"),
      body: schemaRef("PermissionResponseRequest"),
      response: schemaRef("OkResponse"),
      error: errorResponse,
    },
  },

  {
    method: "GET",
    path: "/policy/fallback",
    operationId: "getPolicyFallback",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PATCH",
    path: "/policy/fallback",
    operationId: "updatePolicyFallback",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/policy/rules",
    operationId: "listPolicyRules",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/policy/rules",
    operationId: "createPolicyRule",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PATCH",
    path: "/policy/rules/{ruleId}",
    operationId: "updatePolicyRule",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/policy/rules/{ruleId}",
    operationId: "deletePolicyRule",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/policy/audit",
    operationId: "listPolicyAudit",
    surface: "admin",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/provider-auth/status",
    operationId: "listProviderAuthStatus",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/provider-auth/flows",
    operationId: "startProviderAuthFlow",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/provider-auth/flows/{flowId}",
    operationId: "getProviderAuthFlow",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/provider-auth/flows/{flowId}/prompt-response",
    operationId: "submitProviderAuthPromptResponse",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/provider-auth/flows/{flowId}/manual-code",
    operationId: "submitProviderAuthManualCode",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/provider-auth/flows/{flowId}/cancel",
    operationId: "cancelProviderAuthFlow",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/provider-auth/api-key",
    operationId: "setProviderApiKey",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/provider-auth/{providerId}",
    operationId: "removeProviderCredential",
    surface: "admin",
    auth: "owner",
  },

  { method: "GET", path: "/skills", operationId: "listSkills", surface: "admin", auth: "owner" },
  {
    method: "POST",
    path: "/skills/rescan",
    operationId: "rescanSkills",
    surface: "internal",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/skills/{skillName}",
    operationId: "getSkill",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/skills/{skillName}/file",
    operationId: "getSkillFile",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/extensions",
    operationId: "listExtensions",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/host/directories",
    operationId: "listHostDirectories",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/host/path/status",
    operationId: "getHostPathStatus",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/host/path/completions",
    operationId: "completeHostPath",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/host/path/create",
    operationId: "createHostPath",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/me/skills",
    operationId: "listUserSkills",
    surface: "internal",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/me/skills",
    operationId: "createUserSkillDisabled",
    surface: "internal",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/me/skills/{skillName}",
    operationId: "getUserSkillDisabled",
    surface: "internal",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/me/skills/{skillName}",
    operationId: "updateUserSkillDisabled",
    surface: "internal",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/me/skills/{skillName}",
    operationId: "deleteUserSkillDisabled",
    surface: "internal",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/me/skills/{skillName}/files",
    operationId: "getUserSkillFileDisabled",
    surface: "internal",
    auth: "owner",
  },

  { method: "GET", path: "/themes", operationId: "listThemes", surface: "admin", auth: "owner" },
  {
    method: "GET",
    path: "/themes/{name}",
    operationId: "getTheme",
    surface: "admin",
    auth: "owner",
  },

  {
    method: "POST",
    path: "/telemetry/metrickit",
    operationId: "uploadMetricKitPayload",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/telemetry/chat-metrics",
    operationId: "uploadChatMetrics",
    surface: "admin",
    auth: "owner",
  },
] as const satisfies readonly ApiRouteSpec[];

interface CompiledRoutePattern {
  pattern: string;
  regex: RegExp;
}

const compiledPathPatterns: CompiledRoutePattern[] = uniquePathTemplates(apiRouteSpecs).map(
  (path) => ({
    pattern: pathTemplateToMetricPattern(path),
    regex: pathTemplateToRegex(path),
  }),
);

export function normalizeRegisteredPathPattern(path: string): string | undefined {
  const direct = compiledPathPatterns.find((entry) => entry.regex.test(path))?.pattern;
  if (direct) return direct;

  if (path.length > 1 && path.endsWith("/")) {
    const withoutTrailingSlash = path.slice(0, -1);
    return compiledPathPatterns.find((entry) => entry.regex.test(withoutTrailingSlash))?.pattern;
  }

  return undefined;
}

function uniquePathTemplates(routes: readonly ApiRouteSpec[]): string[] {
  return [...new Set(routes.map((route) => route.path))];
}

function pathTemplateToMetricPattern(path: string): string {
  return path
    .replace(/\{([A-Za-z][A-Za-z0-9_]*)\+\}/g, ":$1")
    .replace(/\{([A-Za-z][A-Za-z0-9_]*)\}/g, ":$1");
}

function pathTemplateToRegex(path: string): RegExp {
  let pattern = "^";
  let cursor = 0;
  const paramPattern = /\{([A-Za-z][A-Za-z0-9_]*)(\+)?\}/g;
  let match: RegExpExecArray | null;

  while ((match = paramPattern.exec(path))) {
    pattern += escapeRegex(path.slice(cursor, match.index));
    pattern += match[2] ? ".+" : "[^/]+";
    cursor = match.index + match[0].length;
  }

  pattern += escapeRegex(path.slice(cursor));
  pattern += "$";
  return new RegExp(pattern);
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
