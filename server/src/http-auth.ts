const WORKSPACE_BROWSE_ROUTE = /^\/workspaces\/[^/]+\/files\/(.+)$/;
const SESSION_ATTACHMENT_ROUTE = /^\/workspaces\/[^/]+\/sessions\/[^/]+\/attachments\/[^/]+$/;

function decodePathSuffix(value: string): string | null {
  try {
    return decodeURIComponent(value);
  } catch {
    return null;
  }
}

export function isQueryTokenAllowed(method: string, path: string, url: URL): boolean {
  if (method.toUpperCase() !== "GET") {
    return false;
  }

  if (SESSION_ATTACHMENT_ROUTE.test(path)) {
    return true;
  }

  const workspaceMatch = path.match(WORKSPACE_BROWSE_ROUTE);
  if (!workspaceMatch) {
    return false;
  }

  const requestedPath = decodePathSuffix(workspaceMatch[1]);
  if (!requestedPath || requestedPath.endsWith("/")) {
    return false;
  }

  return url.searchParams.get("mode") === "browse";
}
