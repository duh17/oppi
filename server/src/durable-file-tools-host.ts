import {
  createLsTool,
  createFindTool,
  createGrepTool,
  createReadTool as createSdkReadTool,
  type ExtensionToolContext,
} from "@earendil-works/pi-coding-agent";
import type { JsonValue } from "@earendil-works/chord";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import type { OppiFileToolsHost } from "./durable-extension-api.js";
import {
  createSandboxLsOps,
  createGondolinFindOps,
  createSandboxGrepToolDefinition,
  createGondolinReadOps,
} from "./gondolin-ops.js";
import { shouldShadowSandboxWorkspacePath } from "./gondolin-manager.js";
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";

// The host side of the `oppi.file-tools` built-in (`extensions/durable/file-tools`), bound through
// `oppi/durable`. Schemas and descriptions are Pi's. Each call runs where the invocation's env
// runs: Pi's own tools (host rg and fd) in a host session's cwd, operations over the VM in a
// sandbox session, never host rg/fd there. Any other env is refused.
const ls = createLsTool("/");
const find = createFindTool("/");
const grep = createGrepTool("/");
type LsArgs = Parameters<typeof ls.execute>[1];
type FindArgs = Parameters<typeof find.execute>[1];
type GrepArgs = Parameters<typeof grep.execute>[1];

export const fileToolsHost: OppiFileToolsHost = {
  ls: {
    description: ls.description,
    parameters: ls.parameters,
    async execute(args, api, context) {
      const env = runtimeOf(api.env);
      const tool =
        env.kind === "host"
          ? createLsTool(env.env.cwd)
          : createLsTool(env.env.cwd, {
              operations: createSandboxLsOps(
                env.env.vm,
                env.env.workspaceRoot,
                env.env.workspaceRoot,
                {
                  shouldShadow: (path) => shouldShadowSandboxWorkspacePath({ op: "readdir", path }),
                },
              ),
            });
      const result = await tool.execute(api.callId, args as LsArgs, context.abortSignal);
      return { output: result.content, details: jsonDetails(result.details) };
    },
  },
  find: {
    description: find.description,
    parameters: find.parameters,
    async execute(args, api, context) {
      const env = runtimeOf(api.env);
      const tool =
        env.kind === "host"
          ? createFindTool(env.env.cwd)
          : createFindTool(env.env.cwd, {
              operations: createGondolinFindOps(
                env.env.cancellableVm(context),
                env.env.workspaceRoot,
                env.env.workspaceRoot,
              ),
            });
      const result = await tool.execute(api.callId, args as FindArgs, context.abortSignal);
      return { output: result.content, details: jsonDetails(result.details) };
    },
  },
  grep: {
    // Pi's promises .gitignore and output caps the sandbox's guest search does not keep.
    description:
      "Search file contents for a pattern. Returns matching lines with file paths and line numbers, up to `limit` matches (default 100).",
    parameters: grep.parameters,
    async execute(args, api, context) {
      const env = runtimeOf(api.env);
      if (env.kind === "host") {
        const result = await createGrepTool(env.env.cwd).execute(
          api.callId,
          args as GrepArgs,
          context.abortSignal,
        );
        return { output: result.content, details: jsonDetails(result.details) };
      }
      // This Oppi definition does not consume an SDK extension context.
      const result = await createSandboxGrepToolDefinition(
        env.env.cancellableVm(context),
        env.env.workspaceRoot,
        env.env.workspaceRoot,
      ).execute(
        api.callId,
        args as Parameters<ReturnType<typeof createSandboxGrepToolDefinition>["execute"]>[1],
        context.abortSignal,
        undefined,
        undefined as unknown as ExtensionToolContext,
      );
      return { output: result.content };
    },
  },
  async readImage(args, api, context) {
    if (!(api.env instanceof GondolinExecutionEnv)) return undefined;
    const env = api.env;
    const ops = createGondolinReadOps(env.vm, env.workspaceRoot, env.workspaceRoot);
    const path = await env.absolutePath(args.path, context);
    if (!path.ok) throw path.error;
    if (!(await ops.detectImageMimeType?.(path.value))) return undefined;
    const result = await createSdkReadTool(env.cwd, { operations: ops }).execute(
      api.callId,
      args,
      context.abortSignal,
    );
    return { output: result.content };
  },
};

// SDK search details contain JSON data; serialize away optional undefined
// fields before crossing Durable's JSON-only storage boundary.
function jsonDetails(value: unknown): JsonValue | undefined {
  return value === undefined ? undefined : (JSON.parse(JSON.stringify(value)) as JsonValue);
}

/** Where a call runs: the host for the server's Node env, the VM for a Gondolin env. */
function runtimeOf(
  env: unknown,
): { kind: "host"; env: NodeExecutionEnv } | { kind: "sandbox"; env: GondolinExecutionEnv } {
  if (env instanceof GondolinExecutionEnv) return { kind: "sandbox", env };
  if (env instanceof NodeExecutionEnv) return { kind: "host", env };
  throw new Error("File tools require the server's host or Gondolin execution environment");
}
