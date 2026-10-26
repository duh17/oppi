import {
  defineExtension,
  defineTool,
  wrapTool,
  type Extension,
  type ToolRegistration,
} from "@earendil-works/pi-durable";
import { createReadTool } from "@earendil-works/pi-durable/tools";
import { oppiHost, type OppiFileTool } from "oppi/durable";

// Pi's ls, find, and grep for durable sessions, and `read` that also reads images in a sandbox.
// The operations are the server's (`oppiHost().files`): Pi's own tools over the host for a host
// session, over the Gondolin VM for a sandbox session. This package names the tools, their replay
// policy, and the `read` wrap. Whether a session offers ls, find, and grep is the Pi Tools
// setting's, as in classic.

const { files } = oppiHost();

const tool = (name: string, host: OppiFileTool): ToolRegistration =>
  defineTool({
    name,
    description: host.description,
    parameters: host.parameters,
    replay: "safe",
    execute: (args, api, context) => host.execute(args, api, context),
  });

/** The durable entry (`package.json` `oppi.durable`). */
const DurableFileTools: Extension = defineExtension<ToolRegistration>({
  name: "oppi.file-tools",
  tools: [tool("ls", files.ls), tool("find", files.find), tool("grep", files.grep)],
  wraps: [
    wrapTool(createReadTool(), (read) => ({
      ...read,
      description: `${read.description} Sandbox sessions can also read PNG, JPEG, GIF and WebP images.`,
      async execute(args, api, context) {
        return (await files.readImage(args, api, context)) ?? read.execute(args, api, context);
      },
    })),
  ],
});

export default DurableFileTools;
