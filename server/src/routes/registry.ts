export type HttpMethod = "GET" | "HEAD" | "POST" | "PUT" | "PATCH" | "DELETE";
export type RouteSurface = "core" | "admin" | "internal";
export type RouteAuth = "none" | "owner";
export type RouteTransport = "http" | "websocket";
// Which iOS/Mac app flows should depend on this route?
// - session: watching and controlling agent sessions.
// - settings: configuring the local server and workspaces.
// This is separate from `surface`, which answers who owns the route: core, admin, or internal.
export type NativeClientUse = "session" | "settings";

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
  nativeClientUses?: readonly NativeClientUse[];
  description?: string;
  schemas?: ApiRouteSchemas;
}

const schemaRef = (name: string): SchemaRef => `#/components/schemas/${name}` as SchemaRef;
const errorResponse = schemaRef("ErrorResponse");

const sessionOperationIds = new Set<string>([
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
  "headSessionAttachment",
  "getSessionToolOutput",
  "openSessionStream",
  "openDictationStream",
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
]);

const settingsOperationIds = new Set<string>([
  "getCodexUsage",
  "getServerStats",
  "getDailyServerStats",
  "updateServerRuntime",
  "getAutoTitleConfig",
  "setAutoTitleConfig",
  "createWorkspace",
  "updateWorkspace",
  "deleteWorkspace",
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
]);

function nativeClientUsesFor(operationId: string): readonly NativeClientUse[] | undefined {
  const uses: NativeClientUse[] = [];
  if (sessionOperationIds.has(operationId)) uses.push("session");
  if (settingsOperationIds.has(operationId)) uses.push("settings");
  return uses.length > 0 ? uses : undefined;
}

const rawApiRouteSpecs = [
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
    path: "/workspaces/{workspaceId}/attention",
    operationId: "getWorkspaceAttention",
    surface: "internal",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/paths",
    operationId: "getWorkspacePaths",
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
    path: "/workspaces/{workspaceId}/contents",
    operationId: "getWorkspaceContentsRoot",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/contents/{path+}",
    operationId: "getWorkspaceContents",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/raw/{path+}",
    operationId: "getWorkspaceRaw",
    surface: "core",
    auth: "owner",
  },

  {
    method: "POST",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/attachments",
    operationId: "createSessionAttachment",
    surface: "core",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/attachments/{attachmentId}/content",
    operationId: "putSessionAttachmentContent",
    surface: "core",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions",
    operationId: "listWorkspaceSessions",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/session-buckets",
    operationId: "listWorkspaceSessionBuckets",
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
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/command",
    operationId: "sendWorkspaceSessionCommand",
    surface: "core",
    auth: "owner",
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
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/changes",
    operationId: "listSessionChanges",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/diff",
    operationId: "getSessionDiff",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/raw/{path+}",
    operationId: "getSessionRaw",
    surface: "core",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/attachments/{attachmentId}",
    operationId: "getSessionAttachment",
    surface: "core",
    auth: "owner",
  },
  {
    method: "HEAD",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/attachments/{attachmentId}",
    operationId: "headSessionAttachment",
    surface: "core",
    auth: "owner",
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
    path: "/dictation/stream",
    operationId: "openDictationStream",
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
    path: "/sessions",
    operationId: "listSessions",
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
    path: "/workspaces/{workspaceId}/git/status",
    operationId: "getWorkspaceGitStatus",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/git/changes",
    operationId: "listWorkspaceGitChanges",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/git/diff",
    operationId: "getWorkspaceGitDiff",
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

export const apiRouteSpecs = rawApiRouteSpecs.map((route): ApiRouteSpec => {
  const nativeClientUses = nativeClientUsesFor(route.operationId);
  return nativeClientUses ? { ...route, nativeClientUses } : route;
});

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
