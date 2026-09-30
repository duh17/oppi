// A stdio MCP server that never answers initialization and stays alive after EOF.
// The optional TERM handler forces the supervisor's escalation path.
if (process.argv[3] === "ignore-term") process.on("SIGTERM", () => {});
process.stdin.resume();
setInterval(() => {}, 1000);
require("node:fs").writeFileSync(process.argv[2], String(process.pid));
