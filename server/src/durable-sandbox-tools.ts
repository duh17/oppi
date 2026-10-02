import {
  createLsTool,
  createFindTool,
  createReadTool as createSdkReadTool,
  type ExtensionToolContext,
} from "@earendil-works/pi-coding-agent";
import {
  defineExtension,
  defineTool,
  wrapTool,
  type Extension,
  type ToolRegistration,
} from "@earendil-works/pi-durable";
import { createReadTool } from "@earendil-works/pi-durable/tools";
import type { JsonValue } from "@earendil-works/chord";
import {
  createSandboxLsOps,
  createGondolinFindOps,
  createSandboxGrepToolDefinition,
  createGondolinReadOps,
  sandboxGrepSchema,
} from "./gondolin-ops.js";
import { shouldShadowSandboxWorkspacePath } from "./gondolin-manager.js";
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";

// Only schema/description are taken from host definitions. Execution always
// constructs operations over the invocation's sandbox VM, never host rg/fd.
const ls = createLsTool("/workspace");
const find = createFindTool("/workspace");
export const DurableSandboxTools: Extension = defineExtension<ToolRegistration>({
  name: "oppi.sandbox-tools",
  tools: [
    defineTool({
      name: "ls",
      description: ls.description,
      parameters: ls.parameters,
      replay: "safe",
      async execute(args, api, context) {
        const env = sandbox(api.env);
        const tool = createLsTool(env.cwd, {
          operations: createSandboxLsOps(env.vm, env.workspaceRoot, env.workspaceRoot, {
            shouldShadow: (path) => shouldShadowSandboxWorkspacePath({ op: "readdir", path }),
          }),
        });
        const result = await tool.execute(api.callId, args, context.abortSignal);
        return { content: result.content, details: jsonDetails(result.details) };
      },
    }),
    defineTool({
      name: "find",
      description: find.description,
      parameters: find.parameters,
      replay: "safe",
      async execute(args, api, context) {
        const env = sandbox(api.env);
        const result = await createFindTool(env.cwd, {
          operations: createGondolinFindOps(
            env.cancellableVm(context),
            env.workspaceRoot,
            env.workspaceRoot,
          ),
        }).execute(api.callId, args, context.abortSignal);
        return { content: result.content, details: jsonDetails(result.details) };
      },
    }),
    defineTool({
      name: "grep",
      description: "Search file contents inside the sandbox workspace using guest rg or grep.",
      parameters: sandboxGrepSchema,
      replay: "safe",
      async execute(args, api, context) {
        const env = sandbox(api.env);
        // This Oppi definition does not consume an SDK extension context.
        const result = await createSandboxGrepToolDefinition(
          env.cancellableVm(context),
          env.workspaceRoot,
          env.workspaceRoot,
        ).execute(
          api.callId,
          args,
          context.abortSignal,
          undefined,
          undefined as unknown as ExtensionToolContext,
        );
        return { content: result.content };
      },
    }),
  ],
  wraps: [
    wrapTool(createReadTool(), (read) => ({
      ...read,
      description: `${read.description} Sandbox sessions can also read PNG, JPEG, GIF and WebP images.`,
      async execute(args, api, context) {
        if (!(api.env instanceof GondolinExecutionEnv)) return read.execute(args, api, context);
        const env = api.env;
        const ops = createGondolinReadOps(env.vm, env.workspaceRoot, env.workspaceRoot);
        const path = await env.absolutePath(args.path, context);
        if (!path.ok) throw path.error;
        if (!(await ops.detectImageMimeType?.(path.value))) return read.execute(args, api, context);
        const result = await createSdkReadTool(env.cwd, { operations: ops }).execute(
          api.callId,
          args,
          context.abortSignal,
        );
        return { content: result.content };
      },
    })),
  ],
});

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
