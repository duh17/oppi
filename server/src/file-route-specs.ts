/**
 * The file browse and read rows of the route registry (`routes/registry.ts` spreads them into its
 * list at this position; nothing else imports this): the workspace path index and folder listings,
 * the current-file reads and guarded writes by origin, and the server home's folder listings. The
 * handlers are `routes/workspace-files.ts` and `routes/host-files.ts`. Every row needs the owner
 * bearer or a paired device's token; nothing here is public.
 */

const LISTING_PAGE_DESCRIPTION =
  "One page of up to 1000 folder entries in byte order of their names; ?after=<next> asks for the page after the one whose `next` it is. 403 for a path outside the root.";

export const fileRouteSpecs = [
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
    description: LISTING_PAGE_DESCRIPTION,
  },
  {
    method: "GET",
    path: "/workspaces/{workspaceId}/contents/{path+}",
    operationId: "getWorkspaceContents",
    surface: "core",
    auth: "owner",
    description: LISTING_PAGE_DESCRIPTION,
  },
  {
    method: "GET",
    path: "/files/current",
    operationId: "getCurrentFile",
    surface: "core",
    auth: "owner",
    description:
      "Current-file bytes by origin (host, workspace, session, skill, or pi). With X-Oppi-Edit-Resolve: 1, names the origin that edits the file (X-Oppi-Edit-Origin) or why it is read-only (X-Oppi-Edit-Refusal).",
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
      "Guarded write of a text file. origin=workspace, origin=skill (an editable Skill's own file), origin=pi (Pi's own agent files), or origin=host (a home file no other origin owns, outside the refusal list); requires one concrete If-Match, or If-None-Match: * to create a missing Pi agent file or a checkout's pane layout (origin=workspace, path .oppi/layouts/<name>.json). No other workspace file, and no Skill or host file, is ever created.",
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
    description: LISTING_PAGE_DESCRIPTION,
  },
  {
    method: "GET",
    path: "/host/contents/{path+}",
    operationId: "getHostContents",
    surface: "core",
    auth: "owner",
    description: LISTING_PAGE_DESCRIPTION,
  },
] as const;
