/**
 * The Godot pane's rows of the route registry (`routes/registry.ts` spreads them into its list;
 * nothing else imports this). Types and messages: `server/src/types/godot.ts`. Every row needs the owner
 * bearer or a paired device's token; nothing here is public.
 */
export const godotRouteSpecs = [
  {
    method: "GET",
    path: "/godot",
    operationId: "listGodotProjects",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/godot/{projectId}",
    operationId: "getGodotProject",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/godot/{projectId}/link",
    operationId: "openGodotLink",
    surface: "core",
    auth: "owner",
    transport: "websocket",
    description: "The live link: ?role=player (the app's Godot pane) or ?role=follower.",
  },
  {
    method: "HEAD",
    path: "/godot/{projectId}/packs/{sha256}",
    operationId: "headGodotPack",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/godot/{projectId}/packs/{sha256}",
    operationId: "getGodotPack",
    surface: "core",
    auth: "owner",
    description: "Pack bytes; ETag is the sha256, one byte range.",
  },
  {
    method: "PUT",
    path: "/godot/{projectId}/packs/{sha256}",
    operationId: "uploadGodotPack",
    surface: "core",
    auth: "owner",
    description: "Store a pack for a later release; an existing sha256 is not stored again.",
  },
  {
    method: "POST",
    path: "/godot/{projectId}/releases",
    operationId: "publishGodotRelease",
    surface: "core",
    auth: "owner",
  },
  {
    method: "POST",
    path: "/godot/{projectId}/commands",
    operationId: "runGodotCommand",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/godot/{projectId}/logs",
    operationId: "getGodotLogs",
    surface: "core",
    auth: "owner",
  },
  {
    method: "PUT",
    path: "/godot/{projectId}/captures/{captureId}",
    operationId: "uploadGodotCapture",
    surface: "core",
    auth: "owner",
  },
  {
    method: "GET",
    path: "/godot/{projectId}/captures/{captureId}",
    operationId: "getGodotCapture",
    surface: "core",
    auth: "owner",
  },
] as const;
