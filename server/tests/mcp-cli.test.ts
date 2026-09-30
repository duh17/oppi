import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { McpCli, type McpCliProcess } from "../src/mcp-cli.js";

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

describe("MCP CLI subprocess supervision", () => {
  it.each([
    ["timeout", "default-term", "stdio"],
    ["timeout", "ignore-term", "stdio"],
    ["cancel", "default-term", "stdio"],
    ["cancel", "ignore-term", "stdio"],
    ["timeout", "ignore-term", "synchronous-reference"],
    ["shutdown", "ignore-term", "stdio"],
  ])(
    "%s leaves no server helper alive (%s, %s)",
    async (reason, term, transport) => {
      const agentDir = mkdtempSync(join(tmpdir(), "oppi-mcp-stdio-"));
      const pidFile = join(agentDir, "fixture.pid");
      const args = [resolve("tests/fixtures/mcp-hang.cjs"), pidFile, term];
      writeFileSync(
        join(agentDir, "mcp.json"),
        JSON.stringify({
          mcpServers: {
            hang:
              transport === "stdio"
                ? { command: process.execPath, args }
                : {
                    url: "http://127.0.0.1:1/mcp",
                    // Pi blocks in synchronous !command resolution. This helper shares
                    // the CLI group and must still be killed after the CLI itself closes.
                    headers: {
                      Authorization: `!${[process.execPath, ...args].map((arg) => `'${arg.replaceAll("'", "'\\''")}'`).join(" ")}`,
                    },
                  },
          },
        }),
      );
      const cli = new McpCli(agentDir);
      let command: McpCliProcess | undefined;
      let pid: number | undefined;
      try {
        command = cli.start(["list", "--json"], cli.globalCwd, { timeoutMs: 5000 });
        // Handle rejection immediately while synchronizing with real fixture startup.
        const result = command.done.catch((error: unknown) => error);
        await expect.poll(() => existsSync(pidFile), { timeout: 4000 }).toBe(true);
        pid = Number(readFileSync(pidFile, "utf8"));
        expect(Number.isSafeInteger(pid) && pid > 1).toBe(true);
        expect(alive(pid)).toBe(true);
        const stoppingAt = performance.now();
        if (reason === "cancel" || reason === "shutdown") {
          command.stop();
          command.stop(); // Repeated cancellation must not abandon the original snapshot.
          if (reason === "shutdown") command.stop(true);
        }
        const settled = await result;
        if (reason === "timeout")
          expect(settled).toMatchObject({ statusCode: 504, message: "Pi MCP command timed out" });
        else expect(settled).toMatchObject({ code: 1 });
        if (reason === "shutdown") expect(performance.now() - stoppingAt).toBeLessThan(1500);
        // Child close alone is not proof: Pi launches the server in a detached group.
        const fixturePid = pid;
        await expect.poll(() => alive(fixturePid), { timeout: 3000 }).toBe(false);
      } finally {
        command?.stop();
        // Only this test's PID, even on a red run. Keep its temp config as evidence.
        if (pid && alive(pid)) process.kill(pid, "SIGKILL");
        await command?.done.catch(() => {});
      }
    },
    20_000,
  );
});
