import {
  createLsTool,
  createFindTool,
  createReadTool as createSdkReadTool,
  type ExtensionToolContext,
} from "@earendil-works/pi-coding-agent";
import type { JsonValue } from "@earendil-works/chord";
import type { OppiSandboxHost } from "./durable-extension-api.js";
import {
  createSandboxLsOps,
  createGondolinFindOps,
  createSandboxGrepToolDefinition,
  createGondolinReadOps,
  sandboxGrepSchema,
} from "./gondolin-ops.js";
import { shouldShadowSandboxWorkspacePath } from "./gondolin-manager.js";
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";

// The host side of the `oppi.sandbox-tools` built-in (`extensions/durable/sandbox-tools`), bound
// through `oppi/durable`. Only schema/description are taken from host definitions. Execution
// always constructs operations over the invocation's sandbox VM, never host rg/fd.
const ls = createLsTool("/workspace");
const find = createFindTool("/workspace");
type LsArgs = Parameters<typeof ls.execute>[1];
type FindArgs = Parameters<typeof find.execute>[1];
type GrepArgs = Parameters<ReturnType<typeof createSandboxGrepToolDefinition>["execute"]>[1];

export const sandboxHost: OppiSandboxHost = {
  ls: {
    description: ls.description,
    parameters: ls.parameters,
    async execute(args, api, context) {
      const env = sandbox(api.env);
      const tool = createLsTool(env.cwd, {
        operations: createSandboxLsOps(env.vm, env.workspaceRoot, env.workspaceRoot, {
          shouldShadow: (path) => shouldShadowSandboxWorkspacePath({ op: "readdir", path }),
        }),
      });
      const result = await tool.execute(api.callId, args as LsArgs, context.abortSignal);
      return { output: result.content, details: jsonDetails(result.details) };
    },
  },
  find: {
    description: find.description,
    parameters: find.parameters,
    async execute(args, api, context) {
      const env = sandbox(api.env);
      const result = await createFindTool(env.cwd, {
        operations: createGondolinFindOps(
          env.cancellableVm(context),
          env.workspaceRoot,
          env.workspaceRoot,
        ),
      }).execute(api.callId, args as FindArgs, context.abortSignal);
      return { output: result.content, details: jsonDetails(result.details) };
    },
  },
  grep: {
    description: "Search file contents inside the sandbox workspace using guest rg or grep.",
    parameters: sandboxGrepSchema,
    async execute(args, api, context) {
      const env = sandbox(api.env);
      // This Oppi definition does not consume an SDK extension context.
      const result = await createSandboxGrepToolDefinition(
        env.cancellableVm(context),
        env.workspaceRoot,
        env.workspaceRoot,
      ).execute(
        api.callId,
        args as GrepArgs,
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

function sandbox(env: unknown): GondolinExecutionEnv {
  if (!(env instanceof GondolinExecutionEnv))
    throw new Error("Sandbox tools require a Gondolin execution environment");
  return env;
}
