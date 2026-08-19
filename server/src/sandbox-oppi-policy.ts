/**
 * Sandbox Oppi tool surface: same workspace only.
 *
 * A sandbox session may orchestrate children inside its own sandbox
 * workspace. It must not create host workspaces, edit Agents, touch
 * schedules/config, or inspect sessions outside this workspace.
 */

export type SandboxOppiScope = Readonly<{
  workspaceId: string;
  workspaceName?: string;
}>;

export type SandboxOppiRestriction =
  | { readonly ok: true; readonly args: readonly string[] }
  | { readonly ok: false; readonly reason: string };

const ALLOWED_PATHS = new Set([
  "quota",
  "models",
  "agent\u0000list",
  "agent\u0000get",
  "workspace\u0000get",
  "session\u0000list",
  "session\u0000get",
  "session\u0000inspect",
  "session\u0000wait",
  "session\u0000create",
  "session\u0000send",
  "session\u0000abort",
  "session\u0000stop",
]);

export function sandboxOppiAllowsPath(path: readonly string[], isHelp = false): boolean {
  if (isHelp && path.length === 0) return true;
  if (isHelp && path.length === 1 && path[0] === "session") return true;
  return ALLOWED_PATHS.has(path.join("\u0000"));
}

export function restrictSandboxOppiCommand(options: {
  path: readonly string[];
  args: readonly string[];
  isHelp?: boolean;
  scope: SandboxOppiScope;
}): SandboxOppiRestriction {
  const { path, args, scope } = options;
  const isHelp = options.isHelp === true;
  if (!sandboxOppiAllowsPath(path, isHelp)) {
    return {
      ok: false,
      reason:
        "Sandbox Oppi can only use session list/get/inspect/wait/create/send/abort/stop, agent list/get, workspace get, quota, and models in this sandbox workspace",
    };
  }
  if (isHelp) return { ok: true, args };

  const command = path[0];
  const action = path[1];
  if (command === "session" && action === "list" && hasFlag(args, "all")) {
    return { ok: false, reason: "Sandbox Oppi cannot list sessions across workspaces" };
  }
  if (hasFlag(args, "allow-nested-delegation")) {
    return {
      ok: false,
      reason: "Sandbox Oppi cannot authorize nested delegation",
    };
  }
  if (command === "workspace" && action === "get") {
    const target = positionalAfterCommand(args, "workspace", "get") ?? flagValue(args, "workspace");
    if (target && !workspaceMatchesScope(target, scope)) {
      return {
        ok: false,
        reason: "Sandbox Oppi can only read this sandbox workspace",
      };
    }
    return { ok: true, args };
  }

  if (command === "session" && (action === "create" || action === "list")) {
    const requested = flagValue(args, "workspace");
    if (requested && !workspaceMatchesScope(requested, scope)) {
      return {
        ok: false,
        reason: "Sandbox Oppi can only create or list sessions in this sandbox workspace",
      };
    }
    return { ok: true, args: setFlag(args, "workspace", scope.workspaceId) };
  }

  return { ok: true, args };
}

export function workspaceMatchesScope(value: string, scope: SandboxOppiScope): boolean {
  const requested = value.trim();
  if (!requested) return false;
  if (requested === scope.workspaceId) return true;
  return scope.workspaceName !== undefined && requested === scope.workspaceName;
}

function hasFlag(args: readonly string[], name: string): boolean {
  return flagIndex(args, name) !== -1;
}

function flagValue(args: readonly string[], name: string): string | undefined {
  const index = flagIndex(args, name);
  if (index === -1) return undefined;
  return args[index + 1];
}

function flagIndex(args: readonly string[], name: string): number {
  return args.findIndex((arg) => arg === `--${name}`);
}

function setFlag(args: readonly string[], name: string, value: string): string[] {
  const next = [...args];
  const index = flagIndex(next, name);
  const exact = `--${name}`;
  if (index === -1) {
    next.push(exact, value);
    return next;
  }
  next[index + 1] = value;
  return next;
}

function positionalAfterCommand(
  args: readonly string[],
  command: string,
  action: string,
): string | undefined {
  const start = args[0] === "oppi" ? 1 : 0;
  if (args[start] !== command || args[start + 1] !== action) return undefined;
  const candidate = args[start + 2];
  if (!candidate || candidate.startsWith("-")) return undefined;
  return candidate;
}
