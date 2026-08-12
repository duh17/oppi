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
  "getSessionAttachment",
  "headSessionAttachment",
  "sendSessionCommand",
  "stopSession",
  "listRecentSessions",
  "getWorkspaceGitSummary",
  "getWorkspaceGitStatus",
  "listWorkspaceGitChanges",
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
  "sendControlSessionCommand",
  "openControlSessionStream",
  "getIconAsset",
  "headIconAsset",
]);

const settingsOperationIds = new Set<string>([
  "getProviderQuotas",
  "getServerStats",
  "getDailyServerStats",
  "getToolActivityUsage",
  "getServerSkillUsage",
  "getServerExtensionUsage",
  "updateServerRuntime",
  "getAutoTitleConfig",
  "setAutoTitleConfig",
  "listServerSkills",
  "getServerSkill",
  "getServerSkillFile",
  "updateServerSkillFile",
  "setServerSkillEnabled",
  "listServerExtensions",
  "getServerExtension",
  "setServerExtensionEnabled",
  "getOppiExtensionConfig",
  "setOppiExtensionConfig",
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
    path: "/server/provider-quotas",
    operationId: "getProviderQuotas",
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
    method: "GET",
    path: "/server/stats/tool-activity",
    operationId: "getToolActivityUsage",
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
    path: "/server/resources/skills",
    operationId: "listServerSkills",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/resources/skills/{skillId}",
    operationId: "getServerSkill",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/resources/skills/{skillId}/usage",
    operationId: "getServerSkillUsage",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/resources/skills/{skillId}/file",
    operationId: "getServerSkillFile",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/resources/skills/{skillId}/file",
    operationId: "updateServerSkillFile",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/resources/skills/{skillId}/enabled",
    operationId: "setServerSkillEnabled",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/resources/extensions",
    operationId: "listServerExtensions",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/resources/extensions/{extensionId}",
    operationId: "getServerExtension",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/resources/extensions/{extensionId}/usage",
    operationId: "getServerExtensionUsage",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/resources/extensions/{extensionId}/enabled",
    operationId: "setServerExtensionEnabled",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/extensions/oppi/config",
    operationId: "getOppiExtensionConfig",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/extensions/oppi/config",
    operationId: "setOppiExtensionConfig",
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
    method: "POST",
    path: "/control-sessions",
    operationId: "createControlSession",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/control-sessions/{sessionId}",
    operationId: "getControlSession",
    surface: "core",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/control-sessions/{sessionId}",
    operationId: "deleteControlSession",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/control-sessions/{sessionId}/trace-page",
    operationId: "getControlSessionTracePage",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/control-sessions/{sessionId}/trace-outline",
    operationId: "getControlSessionTraceOutline",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/control-sessions/{sessionId}/events",
    operationId: "getControlSessionEvents",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/control-sessions/{sessionId}/tool-output/{toolCallId}",
    operationId: "getControlSessionToolOutput",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/control-sessions/{sessionId}/command",
    operationId: "sendControlSessionCommand",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/control-sessions/{sessionId}/stop",
    operationId: "stopControlSession",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/control-sessions/{sessionId}/resume",
    operationId: "resumeControlSession",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/control-sessions/{sessionId}/attachments",
    operationId: "createControlSessionAttachment",
    surface: "core",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/control-sessions/{sessionId}/attachments/{attachmentId}/content",
    operationId: "putControlSessionAttachmentContent",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/control-sessions/{sessionId}/attachments/{attachmentId}",
    operationId: "getControlSessionAttachment",
    surface: "core",
    auth: "owner",
  },
  {
    method: "HEAD",
    path: "/control-sessions/{sessionId}/attachments/{attachmentId}",
    operationId: "headControlSessionAttachment",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/control-sessions/{sessionId}/stream",
    operationId: "openControlSessionStream",
    surface: "core",
    auth: "owner",
    transport: "websocket",
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
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/trace-page",
    operationId: "getWorkspaceSessionTracePage",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/trace-outline",
    operationId: "getWorkspaceSessionTraceOutline",
    surface: "core",
    auth: "owner",
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
    method: "HEAD",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/raw/{path+}",
    operationId: "headSessionRaw",
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
    path: "/app/events/stream",
    operationId: "openAppEventStream",
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
    path: "/sessions",
    operationId: "listSessions",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/sessions/{sessionId}",
    operationId: "getSession",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/sessions/{sessionId}/read",
    operationId: "readSessionTrace",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/sessions/{sessionId}/trace",
    operationId: "getSessionTrace",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/sessions/{sessionId}/events",
    operationId: "getGenericSessionEvents",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/sessions/{sessionId}/dialogs",
    operationId: "getSessionDialogs",
    surface: "internal",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/sessions/{sessionId}/attachments/{attachmentId}",
    operationId: "getSessionAttachment",
    surface: "core",
    auth: "owner",
  },
  {
    method: "HEAD",
    path: "/sessions/{sessionId}/attachments/{attachmentId}",
    operationId: "headSessionAttachment",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/sessions/{sessionId}/command",
    operationId: "sendSessionCommand",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/sessions/{sessionId}/stop",
    operationId: "stopSession",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/local-sessions",
    operationId: "listLocalSessions",
    surface: "internal",
    auth: "owner",
  },

  {
    method: "POST",
    path: "/icon-assets",
    operationId: "createIconAsset",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/icon-assets/{assetId}",
    operationId: "getIconAsset",
    surface: "core",
    auth: "owner",
  },
  {
    method: "HEAD",
    path: "/icon-assets/{assetId}",
    operationId: "headIconAsset",
    surface: "core",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/agents",
    operationId: "listAgents",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/agents",
    operationId: "createAgent",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/agents/{agentId}",
    operationId: "getAgent",
    surface: "core",
    auth: "owner",
  },
  {
    method: "PATCH",
    path: "/agents/{agentId}",
    operationId: "updateAgent",
    surface: "core",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/agents/{agentId}",
    operationId: "archiveAgent",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/agents/{agentId}/sessions",
    operationId: "createAgentSession",
    surface: "core",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/schedules",
    operationId: "listAgentSchedules",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/schedules",
    operationId: "createAgentSchedule",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/schedules/{scheduleId}",
    operationId: "getAgentSchedule",
    surface: "core",
    auth: "owner",
  },
  {
    method: "PATCH",
    path: "/schedules/{scheduleId}",
    operationId: "updateAgentSchedule",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/schedules/{scheduleId}/pause",
    operationId: "pauseAgentSchedule",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/schedules/{scheduleId}/resume",
    operationId: "resumeAgentSchedule",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/schedules/{scheduleId}/archive",
    operationId: "archiveAgentSchedule",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/schedules/{scheduleId}/restore",
    operationId: "restoreAgentSchedule",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/schedules/{scheduleId}/run",
    operationId: "runAgentSchedule",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/schedules/{scheduleId}/runs",
    operationId: "listAgentScheduleRuns",
    surface: "core",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/workspaces/{workspaceId}/worktrees",
    operationId: "listWorkspaceWorktrees",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/worktrees",
    operationId: "createWorkspaceWorktree",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/worktrees/open",
    operationId: "openWorkspaceWorktree",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/worktrees/{worktreeId}/status",
    operationId: "getWorkspaceWorktreeStatus",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/worktrees/{worktreeId}/preview",
    operationId: "previewWorkspaceWorktree",
    surface: "core",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/workspaces/{workspaceId}/worktrees/{worktreeId}",
    operationId: "removeWorkspaceWorktree",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/git/summary",
    operationId: "getWorkspaceGitSummary",
    surface: "core",
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
