import {
  defineExtension,
  defineTool,
  wrapTool,
  type Extension,
  type ToolRegistration,
} from "@earendil-works/pi-durable";
import { createReadTool } from "@earendil-works/pi-durable/tools";
import { oppiHost, type OppiSandboxTool } from "oppi/durable";

// ls, find, and grep over a sandbox session's Gondolin VM, and `read` that also reads images
// there. The VM operations are the server's (`oppiHost().sandbox`); this package names the tools,
// their replay policy, and the `read` wrap.

const { sandbox } = oppiHost();

const tool = (name: string, host: OppiSandboxTool): ToolRegistration =>
  defineTool({
    name,
    description: host.description,
    parameters: host.parameters,
    replay: "safe",
    execute: (args, api, context) => host.execute(args, api, context),
  });

/** The durable entry (`package.json` `oppi.durable`); sandbox sessions only. */
const DurableSandboxTools: Extension = defineExtension<ToolRegistration>({
  name: "oppi.sandbox-tools",
  tools: [tool("ls", sandbox.ls), tool("find", sandbox.find), tool("grep", sandbox.grep)],
  wraps: [
    wrapTool(createReadTool(), (read) => ({
      ...read,
      description: `${read.description} Sandbox sessions can also read PNG, JPEG, GIF and WebP images.`,
      async execute(args, api, context) {
        return (await sandbox.readImage(args, api, context)) ?? read.execute(args, api, context);
      },
    })),
  ],
});

export default DurableSandboxTools;
