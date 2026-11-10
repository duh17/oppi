import { homedir } from "node:os";
import type { ConversationId } from "@earendil-works/pi-durable";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { createRemoteEnv } from "./machines/remote-env.js";
import { OPPI_CALLER_SESSION_ID_ENV } from "./session-caller-identity.js";

/** Where a conversation's tools run, as its `DurableRuntime` document says. */
export interface ConversationRuntime {
  kind: "host" | "sandbox" | "remote";
  workspaceId?: string;
  worktreeId?: string;
  machine?: string;
  root?: string;
}

/**
 * Whether a bound conversation's stored runtime differs from the one its Session asks for: a
 * conversation never switches between the host, a sandbox workspace and a machine. `expected` is
 * what the Session row says (`machine` is its worktree's placement).
 */
export function runtimeSwitched(
  runtime: ConversationRuntime | undefined,
  expected: { sandbox: boolean; workspaceId?: string; machine?: string },
): boolean {
  if (runtime?.kind === "remote") return expected.sandbox || expected.machine !== runtime.machine;
  if (expected.machine !== undefined || (runtime?.kind === "sandbox") !== expected.sandbox)
    return true;
  return expected.sandbox && runtime?.workspaceId !== expected.workspaceId;
}

/**
 * The execution environment a Harness call runs in. `bound` is the one this host already made
 * for the conversation (a sandbox's VM, or a remote conversation's connection); a remote
 * conversation makes it on its first call and `remember`s it, so it has one SSH connection that
 * ends with the conversation's session.
 */
export function executionEnv(
  runtime: ConversationRuntime | undefined,
  args: {
    conversationId: ConversationId;
    cwd: string | undefined;
    callerSessionId: string | undefined;
    bound: ExecutionEnv | undefined;
    dataDir: string;
    remember: (env: ExecutionEnv) => void;
  },
): ExecutionEnv {
  if (runtime?.kind === "sandbox") {
    if (!args.bound)
      throw new Error("Durable sandbox workspace is not attached; refusing host execution");
    return args.bound;
  }
  if (runtime?.kind === "remote") {
    if (args.bound) return args.bound;
    if (!runtime.machine || !runtime.root)
      throw new Error("A remote conversation's runtime names no machine and worktree");
    const env = createRemoteEnv({
      dataDir: args.dataDir,
      machine: runtime.machine,
      root: args.cwd ?? runtime.root,
      conversationId: String(args.conversationId),
      ...(runtime.worktreeId ? { worktreeId: runtime.worktreeId } : {}),
    });
    args.remember(env);
    return env;
  }
  // Classic bash exports `OPPI_CALLER_SESSION_ID` from its shell prefix; a durable conversation's
  // host bash and background jobs need it in the env so `oppi session create` run here is
  // attributed to this conversation's own Session: parented, policy-checked, and unable to
  // target itself. A conversation with no Session row adds none of its own (the server's process
  // env still applies). A remote conversation gets none: the `oppi` command is not there.
  return new NodeExecutionEnv({
    cwd: args.cwd ?? homedir(),
    ...(args.callerSessionId
      ? { shellEnv: { [OPPI_CALLER_SESSION_ID_ENV]: args.callerSessionId } }
      : {}),
  });
}
