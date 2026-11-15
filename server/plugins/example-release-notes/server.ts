/**
 * Example plugin: a tool that runs a command and returns what it printed.
 *
 * `example_release_notes` reads the top of `CHANGELOG.md` in the session's working directory.
 * It runs the command through `api.env`, the session's own environment, so it works the same in
 * host and sandbox sessions.
 *
 * It ships off. Turn it on with `oppi extensions enable example-release-notes`; see README.md.
 */
import { defineExtension, defineFacet, defineTool, Extensions } from "oppi/v1";
import { num, obj, opt } from "oppi/v1/schema";

const DEFAULT_LINES = 60;

const releaseNotes = defineTool({
  name: "example_release_notes",
  description: "Read the latest release notes: the top of CHANGELOG.md in the working directory.",
  parameters: obj({ lines: opt(num({ description: `How many lines; default ${DEFAULT_LINES}` })) }),
  // A read: safe to run again if the server stops during the call.
  replay: "safe",
  async execute(args, api, context) {
    // A thrown error becomes the tool's error result.
    if (!api.env) throw new Error("No execution environment is available.");
    // `exec` resolves to an exit code, not to the output: the output arrives in `onOutput`
    // chunks, stdout and stderr in the order they were written.
    let text = "";
    const result = await api.env.exec(
      // An argument list runs the program directly, with no shell parsing the arguments.
      ["head", "-n", String(args.lines ?? DEFAULT_LINES), "CHANGELOG.md"],
      { onOutput: (chunk) => (text += chunk) },
      context,
    );
    // `ok: false` means the command could not run at all; a nonzero exit code means it failed
    // (no CHANGELOG.md, say), and `text` then holds its error message.
    if (!result.ok)
      return { output: [{ type: "text", text: result.error.message }], isError: true };
    return { output: [{ type: "text", text }], isError: result.value.exitCode !== 0 };
  },
});

const ExampleReleaseNotes = defineExtension({
  name: "example-release-notes",
  // Every command goes through `api.env`, so sandbox sessions can use it too.
  runtimes: ["host", "sandbox"],
  tools: [releaseNotes],
});

export default defineFacet((_host, self) => self.contribute(Extensions, ExampleReleaseNotes));
