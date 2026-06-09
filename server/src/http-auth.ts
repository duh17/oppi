const WORKSPACE_RAW_ROUTE = /^\/workspaces\/[^/]+\/raw\/(.+)$/;
const SESSION_ATTACHMENT_ROUTE = /^\/workspaces\/[^/]+\/sessions\/[^/]+\/attachments\/[^/]+$/;

function decodePathSuffix(value: string): string | null {
  try {
    return decodeURIComponent(value);
  } catch {
    return null;
  }
}

export function isQueryTokenAllowed(method: string, path: string, _url: URL): boolean {
  const normalizedMethod = method.toUpperCase();
  if (normalizedMethod !== "GET" && normalizedMethod !== "HEAD") {
    return false;
  }

  if (SESSION_ATTACHMENT_ROUTE.test(path)) {
    return normalizedMethod === "GET";
  }

  const workspaceMatch = path.match(WORKSPACE_RAW_ROUTE);
  if (!workspaceMatch) {
    return false;
  }

  const requestedPath = decodePathSuffix(workspaceMatch[1]);
  return !!requestedPath && !requestedPath.endsWith("/");
}
