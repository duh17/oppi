export type HttpMethod = "GET" | "HEAD" | "POST" | "PUT" | "PATCH" | "DELETE";
export type RouteSurface = "core" | "admin" | "internal";
export type RouteAuth = "none" | "owner";
export type RouteTransport = "http" | "websocket";

/**
 * Every route the server answers. `RouteHandler` refuses an HTTP request that matches no row here,
 * so an HTTP handler without its row is unreachable. WebSocket upgrades and `/health` are answered
 * in `server.ts` before `RouteHandler`; the auth integration test is what keeps their rows, and
 * every row's `auth`, true to the server.
 */
export interface ApiRouteSpec {
  method: HttpMethod;
  path: string;
  operationId: string;
  surface: RouteSurface;
  /** `none`: served without credentials. `owner`: needs the owner bearer or a paired device's token. */
  auth: RouteAuth;
  transport?: RouteTransport;
  description?: string;
}

const rawApiRouteSpecs = [
  {
    method: "GET",
    path: "/health",
    operationId: "getHealth",
    surface: "internal",
    auth: "none",
  },
  { method: "POST", path: "/pair", operationId: "pairDevice", surface: "admin", auth: "none" },
  {
    method: "POST",
    path: "/pair/tailscale",
    operationId: "issueTailscalePairingInvite",
    surface: "admin",
    auth: "none",
  },
  {
    method: "POST",
    path: "/pair/approval-status",
    operationId: "getPairingApprovalStatus",
    surface: "admin",
    auth: "none",
  },
  {
    method: "POST",
    path: "/auth/challenge",
    operationId: "createDeviceAuthChallenge",
    surface: "admin",
    auth: "none",
  },
  {
    method: "POST",
    path: "/auth/refresh",
    operationId: "refreshDeviceAccessToken",
    surface: "admin",
    auth: "none",
  },
  {
    method: "GET",
    path: "/auth/pairing-approvals",
    operationId: "listPairingApprovals",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/auth/pairing-approvals/{approvalId}/approve",
    operationId: "approvePairing",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/auth/pairing-approvals/{approvalId}/deny",
    operationId: "denyPairing",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/auth/devices",
    operationId: "listDevices",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/auth/devices/{deviceId}",
    operationId: "revokeDevice",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/auth/rotate",
    operationId: "rotateOwnerToken",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/me",
    operationId: "getCurrentUser",
    surface: "core",
    auth: "owner",
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
    path: "/server/metrics",
    operationId: "getServerMetrics",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/metrics/settings",
    operationId: "getServerMetricsSettings",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/metrics/settings",
    operationId: "setServerMetricsSettings",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/durable-sessions/settings",
    operationId: "getDurableSessionsSettings",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/durable-sessions/settings",
    operationId: "setDurableSessionsSettings",
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
    path: "/server/resources/skills/{skillId}/file",
    operationId: "getServerSkillFile",
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
    method: "PUT",
    path: "/server/resources/extensions/{extensionId}/enabled",
    operationId: "setServerExtensionEnabled",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/server/resources/extensions/reload",
    operationId: "reloadServerExtensions",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/server/update",
    operationId: "updateServer",
    surface: "admin",
    auth: "owner",
    description:
      "Install an exact already-discovered latest oppi-server version for a global npm install",
  },
  {
    method: "GET",
    path: "/server/mobile-output-guide",
    operationId: "getMobileOutputGuide",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/mobile-output-guide",
    operationId: "setMobileOutputGuide",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/resources/pi/system-prompt",
    operationId: "getPiSystemPrompt",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/server/resources/pi/default-tools",
    operationId: "getPiDefaultTools",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/resources/pi/default-tools",
    operationId: "setPiDefaultTools",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/pi/resources/enabled",
    operationId: "setPiResourceEnabled",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/server/resources/pi/default-model",
    operationId: "setPiDefaultModel",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/models",
    operationId: "listModels",
    surface: "core",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/me/push-registration",
    operationId: "putPushRegistration",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/me/push-registration",
    operationId: "deletePushRegistration",
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
    method: "HEAD",
    path: "/control-sessions/{sessionId}/tool-output/{toolCallId}",
    operationId: "headControlSessionToolOutput",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/control-sessions/{sessionId}/input-card-output/{cardId}",
    operationId: "getControlSessionInputCardOutput",
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
  },
  {
    method: "POST",
    path: "/workspaces",
    operationId: "createWorkspace",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}",
    operationId: "getWorkspace",
    surface: "core",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/workspaces/{workspaceId}",
    operationId: "updateWorkspace",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/workspaces/{workspaceId}",
    operationId: "deleteWorkspace",
    surface: "admin",
    auth: "owner",
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
    path: "/files/current",
    operationId: "getCurrentFile",
    surface: "core",
    auth: "owner",
    description: "Current-file bytes by origin (host, workspace, session, skill, or pi).",
  },
  {
    method: "HEAD",
    path: "/files/current",
    operationId: "headCurrentFile",
    surface: "core",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/files/current",
    operationId: "putCurrentFile",
    surface: "core",
    auth: "owner",
    description:
      "Guarded write of a text file. origin=workspace, origin=skill (an editable Skill's own file), or origin=pi (Pi's own agent files); requires one concrete If-Match, or If-None-Match: * to create a missing Pi agent file. A workspace or Skill file is never created.",
  },
  {
    method: "GET",
    path: "/files/current/sidecars",
    operationId: "listCurrentFileSidecars",
    surface: "core",
    auth: "owner",
    description: "Same-stem timed-text sidecar names beside an existing media file.",
  },
  {
    method: "GET",
    path: "/files/current/media-info",
    operationId: "getCurrentFileMediaInfo",
    surface: "core",
    auth: "owner",
    description: "Header-derived audio length for an existing current file.",
  },
  {
    method: "GET",
    path: "/host/contents",
    operationId: "getHostContentsRoot",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/host/contents/{path+}",
    operationId: "getHostContents",
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
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}",
    operationId: "getWorkspaceSession",
    surface: "core",
    auth: "owner",
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
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/resume",
    operationId: "resumeWorkspaceSession",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/fork",
    operationId: "forkWorkspaceSession",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/events",
    operationId: "getSessionEvents",
    surface: "core",
    auth: "owner",
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
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/worktree-changes",
    operationId: "getSessionWorktreeChanges",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/worktree-diff",
    operationId: "getSessionWorktreeDiff",
    surface: "core",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/tool-output/{toolCallId}",
    operationId: "getSessionToolOutput",
    surface: "core",
    auth: "owner",
  },
  {
    method: "HEAD",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/tool-output/{toolCallId}",
    operationId: "headSessionToolOutput",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/sessions/{sessionId}/input-card-output/{cardId}",
    operationId: "getSessionInputCardOutput",
    surface: "core",
    auth: "owner",
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
    path: "/mirror/v1/bridge",
    operationId: "openMirrorBridge",
    surface: "internal",
    auth: "none",
    transport: "websocket",
    description:
      "The oppi-mirror Pi extension's bridge. Owner Unix socket only; 404 on the network.",
  },
  {
    method: "GET",
    path: "/dictation/dictionary/global",
    operationId: "getGlobalDictationDictionary",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/dictation/dictionary/global",
    operationId: "addToGlobalDictationDictionary",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/dictation/dictionary/global",
    operationId: "replaceGlobalDictationDictionary",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/dictation/dictionary/global",
    operationId: "removeFromGlobalDictationDictionary",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/dictation/dictionary/workspaces/{workspaceId}",
    operationId: "getWorkspaceDictationDictionary",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/dictation/dictionary/workspaces/{workspaceId}",
    operationId: "addToWorkspaceDictationDictionary",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/dictation/dictionary/workspaces/{workspaceId}",
    operationId: "replaceWorkspaceDictationDictionary",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/dictation/dictionary/workspaces/{workspaceId}",
    operationId: "removeFromWorkspaceDictationDictionary",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/speech",
    operationId: "synthesizeSpeech",
    surface: "core",
    auth: "owner",
    description: "Read a message aloud with the configured TTS provider; streams 16-bit PCM.",
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
    surface: "core",
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
    method: "POST",
    path: "/control-conversation",
    operationId: "openControlConversation",
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
    path: "/workspaces/{workspaceId}/git/graph",
    operationId: "getWorkspaceGitGraph",
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
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/quick-actions/selection",
    operationId: "prepareWorkspaceQuickActionSelection",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/workspaces/{workspaceId}/quick-actions/session",
    operationId: "createWorkspaceQuickActionSession",
    surface: "core",
    auth: "owner",
  },

  {
    method: "GET",
    path: "/mcp/scopes/{scopeId}/servers",
    operationId: "listMcpServers",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/mcp/scopes/{scopeId}/servers",
    operationId: "addMcpServer",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "PATCH",
    path: "/mcp/scopes/{scopeId}/servers/{name}",
    operationId: "patchMcpServer",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "DELETE",
    path: "/mcp/scopes/{scopeId}/servers/{name}",
    operationId: "removeMcpServer",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/mcp/scopes/{scopeId}/servers/{name}/login",
    operationId: "startMcpAuthFlow",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/mcp/scopes/{scopeId}/servers/{name}/logout",
    operationId: "logoutMcpServer",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/mcp/auth/flows/{flowId}",
    operationId: "getMcpAuthFlow",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/mcp/auth/flows/{flowId}/manual-code",
    operationId: "submitMcpCallback",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/mcp/auth/flows/{flowId}/cancel",
    operationId: "cancelMcpAuthFlow",
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
    path: "/telemetry/events",
    operationId: "uploadTelemetryEvents",
    surface: "admin",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/telemetry/client-logs",
    operationId: "uploadClientLogs",
    surface: "admin",
    auth: "owner",
  },
] as const satisfies readonly ApiRouteSpec[];

export const apiRouteSpecs: readonly ApiRouteSpec[] = rawApiRouteSpecs;

interface CompiledRoutePattern {
  pattern: string;
  regex: RegExp;
  methods: ReadonlySet<HttpMethod>;
}

const compiledPathPatterns: CompiledRoutePattern[] = uniquePathTemplates(apiRouteSpecs).map(
  (path) => ({
    pattern: pathTemplateToMetricPattern(path),
    regex: pathTemplateToRegex(path),
    methods: new Set(
      apiRouteSpecs.filter((route) => route.path === path).map((route) => route.method),
    ),
  }),
);

/**
 * The methods registered for a request path, across every template it matches (`/sessions/search`
 * also matches `/sessions/{sessionId}`); `undefined` when no template matches. A path with a
 * trailing slash falls back to the path without it, as `normalizeRegisteredPathPattern` does.
 */
export function registeredMethodsForPath(path: string): ReadonlySet<string> | undefined {
  const methods = methodsMatching(path);
  if (methods || path.length <= 1 || !path.endsWith("/")) return methods;
  return methodsMatching(path.slice(0, -1));
}

function methodsMatching(path: string): Set<string> | undefined {
  let methods: Set<string> | undefined;
  for (const entry of compiledPathPatterns) {
    if (!entry.regex.test(path)) continue;
    methods ??= new Set();
    for (const method of entry.methods) methods.add(method);
  }
  return methods;
}

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
