import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { buildAgentMigrationCatalogs } from "../src/agent-migration-catalogs.js";
import { migrateAgentDefinitionV1 } from "../src/agent-definition-migration.js";
import { McpToolCache, mcpToolCachePath, type McpServerSnapshot } from "../src/mcp-tool-cache.js";
import { loadPiMcpInternals, type McpTool } from "../src/pi-mcp-internals.js";
import type { Workspace } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

/**
 * The catalogs the startup migration reads are built from the live server: Oppi's workspaces store
 * their folder in display form (`~/workspace/nanny`), and a project's `.pi/mcp.json` and its cached
 * tool list only exist under that folder. A hand-built catalog cannot show that, so these tests
 * build the catalogs the way startup does, from files on disk.
 */

/** The 34 tools the coros server reported, as the live server's cache has them. */
const COROS_TOOLS = [
  "createScheduledWorkout",
  "createSingleWorkout",
  "createTrainingPlan",
  "downloadActivityFitFiles",
  "getActivityDetail",
  "queryActivityFitFileDownloadUrls",
  "queryActivityLapData",
  "queryAvgHeartRate",
  "queryCustomActivityLapData",
  "queryDailyHealthData",
  "queryDevices",
  "queryFitnessAssessmentOverview",
  "queryHealthCheckTimeSeries",
  "queryMenstruationCycles",
  "queryRecoveryStatus",
  "queryRestingHeartRate",
  "queryScheduledWorkoutDetails",
  "querySleepHrv",
  "querySleepOverview",
  "querySportRecords",
  "queryStressLevel",
  "queryStressTimeSeries",
  "queryTrainingLoadAssessment",
  "queryTrainingPlanDetails",
  "queryTrainingPlanLibrary",
  "queryTrainingSchedule",
  "queryUserInfo",
  "queryWorkoutDetails",
  "queryWorkoutLibrary",
  "scheduleWorkout",
  "updateScheduledWorkout",
  "updateTrainingPlan",
  "uploadRouteFile",
];

const COROS_SERVER = { command: "bun", args: ["coros.ts"] };
const XCODE_SERVER = { command: "xcrun", args: ["mcpbridge"] };

const originalHome = process.env.HOME;

/** A machine whose home is a temp folder, so a workspace can store `~/projects/…` as Oppi does. */
function homeDir(): string {
  const home = makeTempDir("oppi-migration-home-");
  process.env.HOME = home;
  return home;
}

function writeProject(home: string, folder: string, servers: Record<string, unknown>): string {
  const root = join(home, "projects", folder);
  mkdirSync(join(root, ".pi"), { recursive: true });
  writeFileSync(join(root, ".pi", "mcp.json"), JSON.stringify({ mcpServers: servers }));
  return root;
}

const workspace = (id: string, hostMount: string): Workspace =>
  ({ id, name: id, hostMount, runtime: "host" }) as Workspace;

/** Cache the server's tools the way a host session in `cwd` saved them. */
async function cacheProjectTools(
  dataDir: string,
  agentDir: string,
  cwd: string,
  server: string,
  tools: readonly string[],
): Promise<void> {
  const internals = await loadPiMcpInternals();
  const entry = internals
    .loadMcpConfig({ agentDir, cwd, projectTrusted: true })
    .servers.find((candidate) => candidate.name === server);
  if (!entry) throw new Error(`${server} is not configured in ${cwd}`);
  const cache = new McpToolCache(mcpToolCachePath(dataDir), "host");
  const snapshot: McpServerSnapshot = {
    tools: tools.map((name): McpTool => ({ name, inputSchema: { type: "object" } })),
    hasResources: false,
    instructions: undefined,
  };
  cache.save(cache.key(entry), snapshot);
}

/** A v1 Agent: a write tool for the full tier, the MCP rule, and nothing else. */
function v1Agent(tools: readonly string[], excludeTools: readonly string[] = []): unknown {
  return {
    name: "Agent",
    sessionDefaults: {
      model: "anthropic/claude-sonnet-5-5",
      thinkingLevel: "high",
      tools,
      ...(excludeTools.length ? { excludeTools } : {}),
    },
  };
}

afterEach(() => {
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
});

describe("the migration's startup catalogs", () => {
  it("keeps a server a project configures under a display-form home folder, with its cached tools", async () => {
    const home = homeDir();
    const dataDir = makeTempDir("oppi-migration-data-");
    const agentDir = makeTempDir("oppi-migration-agent-");
    const nanny = writeProject(home, "nanny", { coros: COROS_SERVER });
    await cacheProjectTools(dataDir, agentDir, nanny, "coros", COROS_TOOLS);

    const catalogs = await buildAgentMigrationCatalogs({
      extensions: [],
      workspaces: [workspace("nanny-id", "~/projects/nanny")],
      agentDir,
      dataDir,
    });

    // coros is configured in the project scope, not the user scope.
    expect(catalogs.workspaceMcpServers.get("nanny-id")).toEqual(["coros"]);
    expect(catalogs.userMcpServers).toEqual([]);

    // A wildcard minus two tools states the 32 tools that are left, because the list is known.
    const result = migrateAgentDefinitionV1(
      v1Agent(
        ["read", "write", "bash", "mcp__coros__*"],
        ["mcp__coros__createSingleWorkout", "mcp__coros__updateWorkoutDetails"],
      ),
      catalogs,
    );
    expect(result.definition?.capabilities.mcp).toEqual({
      coros: COROS_TOOLS.filter(
        (tool) => tool !== "createSingleWorkout" && tool !== "updateWorkoutDetails",
      ),
    });
    expect(result.notes.filter((note) => note.includes("coros"))).toEqual([
      "listed coros's 32 other tools instead of all but createSingleWorkout",
      "listed coros's 32 other tools instead of all but updateWorkoutDetails",
    ]);
  });

  it("keeps a server only a project scope configures, when the Agent names the whole server", async () => {
    const home = homeDir();
    const dataDir = makeTempDir("oppi-migration-data-");
    const agentDir = makeTempDir("oppi-migration-agent-");
    writeProject(home, "oppi", { aws: { command: "aws-mcp" }, xcode: XCODE_SERVER });

    const catalogs = await buildAgentMigrationCatalogs({
      extensions: [],
      workspaces: [workspace("oppi-id", "~/projects/oppi")],
      agentDir,
      dataDir,
    });

    const result = migrateAgentDefinitionV1(
      v1Agent(["read", "grep", "ls", "find", "bash", "mcp__xcode__*"]),
      catalogs,
    );
    expect(result.definition?.capabilities.mcp).toEqual({ xcode: "all" });
    // The only note is the one every v1 allow list gets: it became the Agent's own Pi tools.
    expect(result.definition?.capabilities.tools).toEqual(["read", "grep", "ls", "find", "bash"]);
    expect(result.notes).toEqual([
      "sessionDefaults.tools became the Agent's own Pi tools: read, grep, ls, find, bash",
    ]);
  });

  it("keeps a whole-server rule whose tools no scope has listed, and asks the owner to check", async () => {
    const home = homeDir();
    const dataDir = makeTempDir("oppi-migration-data-");
    const agentDir = makeTempDir("oppi-migration-agent-");
    writeProject(home, "nanny", { coros: COROS_SERVER });

    const catalogs = await buildAgentMigrationCatalogs({
      extensions: [],
      workspaces: [workspace("nanny-id", "~/projects/nanny")],
      agentDir,
      dataDir,
    });

    // Never listed, so the two exclusions cannot be subtracted: the server stays, and the note says
    // which tools come back with it.
    const result = migrateAgentDefinitionV1(
      v1Agent(
        ["read", "write", "mcp__coros__*"],
        ["mcp__coros__createSingleWorkout", "mcp__coros__updateWorkoutDetails"],
      ),
      catalogs,
    );
    expect(result.definition?.capabilities.mcp).toEqual({ coros: "all" });
    // One note for the server, not one per refused tool, after the tool set's own.
    expect(result.notes).toEqual([
      "sessionDefaults.tools became the Agent's own Pi tools: read, write",
      "kept all of coros: no session has listed its tools here, so createSingleWorkout, updateWorkoutDetails stay reachable. Check this Agent.",
    ]);
  });
});
