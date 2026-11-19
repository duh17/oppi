// A stdio MCP server that never answers initialization and stays alive after EOF.
// The optional TERM handler forces the supervisor's escalation path, and records each
// SIGTERM beside the pid file so a test can tell a grace period from an immediate kill.
const fs = require("node:fs");
if (process.argv[3] === "ignore-term")
  process.on("SIGTERM", () => fs.appendFileSync(`${process.argv[2]}.term`, "TERM\n"));
process.stdin.resume();
setInterval(() => {}, 1000);
// Written whole, then renamed into place: a test that sees the pid file reads the pid,
// never the empty file between create and write.
fs.writeFileSync(`${process.argv[2]}.tmp`, String(process.pid));
fs.renameSync(`${process.argv[2]}.tmp`, process.argv[2]);
