// A stdio MCP server that never answers initialization and stays alive after EOF.
// The optional TERM handler forces the supervisor's escalation path, and records each
// SIGTERM beside the pid file so a test can tell a grace period from an immediate kill.
if (process.argv[3] === "ignore-term")
  process.on("SIGTERM", () =>
    require("node:fs").appendFileSync(`${process.argv[2]}.term`, "TERM\n"),
  );
process.stdin.resume();
setInterval(() => {}, 1000);
require("node:fs").writeFileSync(process.argv[2], String(process.pid));
