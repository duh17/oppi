import { spawnSync } from "node:child_process";
import {
  closeSync,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import {
  inspectSlot,
  lockPath,
  recordOwnedPgid,
  releaseReusable,
  releaseUncertain,
  tryAcquireSlot,
  type OwnedSlot,
} from "./sim-pool-lock";
import {
  buildAttemptCommand,
  deviceState,
  findMatchingPoolDevice,
  parseDevicesJson,
  parseRuntimesJson,
  poolDeviceName,
  selectIosRuntime,
  type SimulatorDevice,
} from "./sim-pool-simctl";
import {
  CommandSession,
  waitExitStatus,
  type StopResult,
  type Supervised,
} from "./sim-pool-supervise";

export class PoolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PoolError";
  }
}

export type VideoPolicy = "off" | "on-failure" | "always";
export type RuntimePolicy = "latest" | "latest-stable";

export type PoolConfig = {
  count: number;
  slotStart: number;
  deviceType: string;
  runtime: string;
  runtimePolicy: RuntimePolicy;
  waitSeconds: number;
  bootTimeout: number;
  bootRetries: number;
  silenceTimeout: number;
  heartbeatInterval: number;
  hangRetries: number;
  keepBooted: boolean;
  forceCleanBoot: boolean;
  slim: boolean;
  indexStore: boolean;
  lockDir: string;
  videoPolicy: VideoPolicy;
  videoReadyTimeout: number;
  videoDir: string;
  videoName: string;
  allowSlowUnitTestScheme: boolean;
  progressPollSeconds: number;
  oppiRoot: string;
  oppiRootFromEnv: boolean;
  appleDir: string;
  buildBase: string;
  slimScript: string;
  homeDir: string;
};

export function die(message: string): never {
  throw new PoolError(message);
}

function parsePositiveInt(raw: string, name: string, minimum = 1): number {
  if (!/^[0-9]+$/.test(raw)) {
    die(`invalid ${name} '${raw}' (expected ${minimum === 0 ? "non-negative" : "positive"} integer)`);
  }
  const value = Number(raw);
  if (value < minimum) {
    die(`invalid ${name} '${raw}' (expected ${minimum === 0 ? "non-negative" : "positive"} integer)`);
  }
  return value;
}

export function normalizeVideoPolicy(raw: string): VideoPolicy {
  switch (raw) {
    case "1":
    case "true":
    case "TRUE":
    case "yes":
    case "YES":
    case "always":
      return "always";
    case "on-failure":
    case "on_failure":
    case "failure":
    case "fail":
    case "failed":
      return "on-failure";
    case "0":
    case "false":
    case "FALSE":
    case "no":
    case "NO":
    case "off":
    case "":
      return "off";
    default:
      die(`invalid simulator video policy '${raw}' (expected off, on-failure, or always)`);
  }
}

export function normalizeRuntimePolicy(raw: string): RuntimePolicy {
  switch (raw) {
    case "latest-stable":
    case "stable":
    case "latest-non-beta":
    case "non-beta":
      return "latest-stable";
    case "latest":
    case "latest-any":
    case "any":
    case "":
      return "latest";
    default:
      die(`invalid OPPI_SIM_RUNTIME_POLICY '${raw}' (expected latest-stable or latest)`);
  }
}

function gitTopLevel(cwd: string): string | null {
  const result = spawnSync("git", ["rev-parse", "--show-toplevel"], {
    cwd,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    return null;
  }
  return result.stdout.trim();
}

export function loadConfig(env: NodeJS.ProcessEnv, cwd: string, scriptDir: string): PoolConfig {
  let oppiRootFromEnv = false;
  let oppiRoot = env.OPPI_ROOT ?? "";
  if (oppiRoot) {
    oppiRootFromEnv = true;
  } else {
    const gitRoot = gitTopLevel(cwd);
    if (gitRoot && existsSync(join(gitRoot, "clients", "apple"))) {
      oppiRoot = gitRoot;
    } else {
      oppiRoot = env.PIOS_ROOT ?? join(homedir(), "workspace", "oppi");
    }
  }
  const appleDir = join(oppiRoot, "clients", "apple");
  const buildBase = join(appleDir, ".build");
  const count = parsePositiveInt(env.OPPI_SIM_POOL_COUNT ?? "6", "OPPI_SIM_POOL_COUNT", 1);
  const slotStart = parsePositiveInt(
    env.OPPI_SIM_POOL_SLOT_START ?? env.OPPI_SIM_POOL_SLOT_OFFSET ?? "0",
    "OPPI_SIM_POOL_SLOT_START",
    0,
  );
  return {
    count,
    slotStart,
    deviceType: env.OPPI_SIM_DEVICE_TYPE ?? "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
    runtime: env.OPPI_SIM_RUNTIME ?? "",
    runtimePolicy: normalizeRuntimePolicy(env.OPPI_SIM_RUNTIME_POLICY ?? ""),
    waitSeconds: parsePositiveInt(env.OPPI_SIM_POOL_WAIT ?? "60", "OPPI_SIM_POOL_WAIT", 0),
    bootTimeout: parsePositiveInt(env.OPPI_SIM_POOL_BOOT_TIMEOUT ?? "120", "OPPI_SIM_POOL_BOOT_TIMEOUT", 1),
    bootRetries: parsePositiveInt(env.OPPI_SIM_POOL_BOOT_RETRIES ?? "1", "OPPI_SIM_POOL_BOOT_RETRIES", 0),
    silenceTimeout: parsePositiveInt(
      env.OPPI_SIM_POOL_SILENCE_TIMEOUT ?? "180",
      "OPPI_SIM_POOL_SILENCE_TIMEOUT",
      0,
    ),
    heartbeatInterval: parsePositiveInt(
      env.OPPI_SIM_POOL_HEARTBEAT_INTERVAL ?? "60",
      "OPPI_SIM_POOL_HEARTBEAT_INTERVAL",
      0,
    ),
    hangRetries: parsePositiveInt(env.OPPI_SIM_POOL_HANG_RETRIES ?? "1", "OPPI_SIM_POOL_HANG_RETRIES", 0),
    keepBooted: (env.OPPI_SIM_POOL_KEEP_BOOTED ?? "1") === "1",
    forceCleanBoot: env.OPPI_SIM_POOL_FORCE_CLEAN_BOOT === "1",
    slim: (env.OPPI_SIM_SLIM ?? env.OPPI_SIM_POOL_SLIM ?? "1") === "1",
    indexStore: env.OPPI_SIM_POOL_INDEX_STORE === "1",
    lockDir: env.OPPI_SIM_POOL_LOCK_DIR ?? "/tmp/oppi-sim-pool",
    videoPolicy: normalizeVideoPolicy(env.OPPI_SIM_POOL_VIDEO_POLICY ?? env.OPPI_SIM_POOL_RECORD_VIDEO ?? "off"),
    videoReadyTimeout: parsePositiveInt(
      env.OPPI_SIM_POOL_VIDEO_READY_TIMEOUT ?? "10",
      "OPPI_SIM_POOL_VIDEO_READY_TIMEOUT",
      0,
    ),
    videoDir: env.OPPI_SIM_POOL_VIDEO_DIR ?? join(buildBase, "videos"),
    videoName: env.OPPI_SIM_POOL_VIDEO_NAME ?? "",
    allowSlowUnitTestScheme: env.OPPI_SIM_POOL_ALLOW_SLOW_UNIT_TEST_SCHEME === "1",
    progressPollSeconds: Number(env.OPPI_SIM_POOL_PROGRESS_POLL ?? "5"),
    oppiRoot,
    oppiRootFromEnv,
    appleDir,
    buildBase,
    slimScript: join(scriptDir, "sim-slim.sh"),
    homeDir: env.HOME ?? homedir(),
  };
}

export function poolSlotEnd(config: PoolConfig): number {
  return config.slotStart + config.count - 1;
}

export function poolSlotRange(config: PoolConfig): string {
  const end = poolSlotEnd(config);
  return config.slotStart === end ? String(config.slotStart) : `${config.slotStart}-${end}`;
}

export function slotNumbers(config: PoolConfig): number[] {
  const slots: number[] = [];
  for (let slot = config.slotStart; slot <= poolSlotEnd(config); slot += 1) {
    slots.push(slot);
  }
  return slots;
}

export function splitRunCommand(args: string[]): { command: string; argv: string[] } {
  if (args.length === 0) {
    die("run requires a command after --");
  }
  return { command: args[0], argv: args.slice(1) };
}

export function extractFlagValue(flag: string, args: string[]): string | undefined {
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === flag) {
      return args[i + 1];
    }
  }
  return undefined;
}

export function commandHasBuildSetting(key: string, args: string[]): boolean {
  const prefix = `${key}=`;
  return args.some((arg) => arg.startsWith(prefix));
}

export function applyPoolBuildSettings(config: PoolConfig, args: string[]): string[] {
  if (config.indexStore) {
    return [];
  }
  if (commandHasBuildSetting("COMPILER_INDEX_STORE_ENABLE", args)) {
    return [];
  }
  return ["COMPILER_INDEX_STORE_ENABLE=NO"];
}

function isTestAction(args: string[]): boolean {
  return args.some((arg) => arg === "test" || arg === "build-for-testing" || arg === "test-without-building");
}

export function hasOnlyTestingTarget(bundle: string, args: string[]): boolean {
  return args.some((arg) => arg === `-only-testing:${bundle}` || arg.startsWith(`-only-testing:${bundle}/`));
}

export function onlyTestingTargetsAre(bundle: string, args: string[]): boolean {
  let saw = false;
  for (const arg of args) {
    if (arg === `-only-testing:${bundle}` || arg.startsWith(`-only-testing:${bundle}/`)) {
      saw = true;
      continue;
    }
    if (arg.startsWith("-only-testing:")) {
      return false;
    }
  }
  return saw;
}

export function rewriteSchemeInArgs(oldScheme: string, newScheme: string, args: string[]): string[] {
  const rewritten: string[] = [];
  let previous = "";
  for (const arg of args) {
    rewritten.push(previous === "-scheme" && arg === oldScheme ? newScheme : arg);
    previous = arg;
  }
  return rewritten;
}

export function normalizeCommandArgs(config: PoolConfig, args: string[]): { args: string[]; log?: string } {
  const scheme = extractFlagValue("-scheme", args);
  if (
    !config.allowSlowUnitTestScheme &&
    isTestAction(args) &&
    scheme === "Oppi" &&
    onlyTestingTargetsAre("OppiTests", args)
  ) {
    return {
      args: rewriteSchemeInArgs("Oppi", "OppiUnitTests", args),
      log: "[sim-pool] Rewriting -scheme Oppi -> OppiUnitTests for OppiTests-only run",
    };
  }
  return { args };
}

export function validateCommandGuardrails(config: PoolConfig, args: string[]): void {
  for (const arg of args) {
    if (arg === "-destination" || arg === "-derivedDataPath") {
      die(`do not pass ${arg} — sim-pool.sh auto-injects it`);
    }
  }
  const scheme = extractFlagValue("-scheme", args);
  if (
    !config.allowSlowUnitTestScheme &&
    isTestAction(args) &&
    scheme === "Oppi" &&
    onlyTestingTargetsAre("OppiTests", args)
  ) {
    die(
      "slow unit-test invocation detected: '-scheme Oppi' still builds OppiPerfTests/OppiUITests/OppiE2ETests. Use '-scheme OppiUnitTests' for OppiTests (override with OPPI_SIM_POOL_ALLOW_SLOW_UNIT_TEST_SCHEME=1).",
    );
  }
}

export function extractCompilerLinkerErrors(logText: string): string[] {
  const lines = logText.split("\n").filter((line) =>
    /^([^:]+:[0-9]+:[0-9]+: (fatal )?error:|[ \t]*(error:|clang: error:|swiftc: error:|ld: ))/.test(line),
  );
  return [...new Set(lines)];
}

export function extractBuildTimingSummary(logText: string): string[] {
  const lines = logText.split("\n");
  const output: string[] = [];
  let capturing = false;
  let sawRow = false;
  for (const line of lines) {
    if (/^Build Timing Summary$/.test(line)) {
      capturing = true;
      output.push(line);
      continue;
    }
    if (capturing && line.trim() !== "") {
      output.push(line);
      sawRow = true;
      continue;
    }
    if (capturing && sawRow) {
      break;
    }
  }
  return output;
}

export function progressMtime(logFile: string, derivedData?: string): number {
  const paths = [logFile];
  if (derivedData) {
    paths.push(join(derivedData, "Build"), join(derivedData, "Index.noindex"), join(derivedData, "ModuleCache.noindex"));
  }
  let latest = 0;
  for (const path of paths) {
    if (!existsSync(path)) {
      continue;
    }
    const mtime = Math.floor(statSync(path).mtimeMs / 1000);
    if (mtime > latest) {
      latest = mtime;
    }
  }
  return latest;
}

function log(message: string): void {
  process.stderr.write(`${message}\n`);
}

function nowEpoch(): number {
  return Math.floor(Date.now() / 1000);
}

function iso8601(epoch: number): string {
  return new Date(epoch * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function fileSize(path: string): number {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}

function fileMtime(path: string): number {
  try {
    return Math.floor(statSync(path).mtimeMs / 1000);
  } catch {
    return 0;
  }
}

function requireQuiescent<T extends { stop: StopResult }>(result: T, action: string): T {
  if (!result.stop.quiescent) {
    die(`${action}: ${result.stop.note ?? "owned process group still running"}`);
  }
  return result;
}

export async function runXcrun(
  session: CommandSession,
  args: string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv } = {},
): Promise<{ code: number; stdout: string; stderr: string; stop: StopResult }> {
  const completed = await session.run("xcrun", args, {
    cwd: options.cwd,
    env: options.env,
  });
  return {
    code: completed.code,
    stdout: completed.stdout,
    stderr: completed.stderr,
    stop: completed.stop,
  };
}

async function listDevices(session: CommandSession, config: PoolConfig): Promise<SimulatorDevice[]> {
  const result = requireQuiescent(await runXcrun(session, ["simctl", "list", "devices", "-j"]), "simctl list");
  if (session.canceled) {
    die("canceled while listing simulators");
  }
  if (result.code !== 0) {
    die("failed to list simulators");
  }
  return parseDevicesJson(result.stdout);
}

async function resolveRuntime(session: CommandSession, config: PoolConfig): Promise<string> {
  if (config.runtime) {
    return config.runtime;
  }
  const result = requireQuiescent(await runXcrun(session, ["simctl", "list", "runtimes", "-j"]), "simctl list runtimes");
  if (session.canceled) {
    die("canceled while listing simulator runtimes");
  }
  if (result.code !== 0) {
    die("failed to list simulator runtimes");
  }
  const selected = selectIosRuntime(parseRuntimesJson(result.stdout), config.runtimePolicy);
  if (typeof selected !== "string") {
    die(selected.error);
  }
  return selected;
}

export async function ensureSim(session: CommandSession, config: PoolConfig, slot: number): Promise<string> {
  const runtime = await resolveRuntime(session, config);
  const devices = await listDevices(session, config);
  const found = findMatchingPoolDevice(devices, slot, runtime, config.deviceType);
  if (found.match) {
    return found.match.udid;
  }
  if (found.mismatches.length > 0) {
    const details = found.mismatches
      .map((device) => `${device.udid} runtime=${device.runtime} device=${device.deviceTypeIdentifier}`)
      .join("; ");
    die(
      `${poolDeviceName(slot)} exists but does not match runtime=${runtime} device=${config.deviceType} (${details}). Refusing to delete it.`,
    );
  }
  log(`[sim-pool] Creating simulator: ${poolDeviceName(slot)}`);
  const created = requireQuiescent(
    await runXcrun(session, ["simctl", "create", poolDeviceName(slot), config.deviceType, runtime]),
    "simctl create",
  );
  if (session.canceled) {
    die("canceled while creating simulator");
  }
  if (created.code !== 0) {
    die(`failed to create simulator: ${created.stderr.trim()}`);
  }
  return created.stdout.trim();
}

async function waitForBootReady(
  session: CommandSession,
  config: PoolConfig,
  udid: string,
): Promise<{ status: number; stop: StopResult }> {
  const spawned = await session.spawn("xcrun", ["simctl", "bootstatus", udid, "-b"]);
  if (!spawned.ok) {
    return {
      status: 127,
      stop: spawned.stop ?? { quiescent: true, note: spawned.reason },
    };
  }
  const completed = await session.complete(spawned.owned, { timeoutMs: config.bootTimeout * 1000 });
  if (!completed.stop.quiescent) {
    return { status: 1, stop: completed.stop };
  }
  if (completed.timedOut) {
    return { status: 124, stop: completed.stop };
  }
  return { status: waitExitStatus(completed.wait), stop: completed.stop };
}

async function waitForBootReadyWithRetries(session: CommandSession, config: PoolConfig, udid: string): Promise<boolean> {
  let attempt = 0;
  while (true) {
    if (session.canceled) {
      return false;
    }
    const result = await waitForBootReady(session, config, udid);
    if (!result.stop.quiescent) {
      die(result.stop.note ?? "bootstatus did not prove process-group quiescence");
    }
    if (result.status === 0) {
      return true;
    }
    if (attempt >= config.bootRetries) {
      return false;
    }
    attempt += 1;
    log(
      `[sim-pool] Simulator is still starting after ${config.bootTimeout}s; continuing readiness wait ${attempt + 1}/${config.bootRetries + 1}`,
    );
  }
}

async function slimSimulator(session: CommandSession, config: PoolConfig, udid: string): Promise<StopResult> {
  if (!config.slim) {
    return { quiescent: true };
  }
  const spawned = await session.spawn("bash", [
    config.slimScript,
    "apply",
    udid,
  ], {
    env: {
      ...process.env,
      OPPI_SIM_POOL_BOOT_TIMEOUT: String(config.bootTimeout),
      OPPI_SIM_POOL_BOOT_RETRIES: String(config.bootRetries),
    },
  });
  if (!spawned.ok) {
    if (spawned.stop && !spawned.stop.quiescent) {
      return spawned.stop;
    }
    die(spawned.reason);
  }
  const completed = await session.complete(spawned.owned);
  if (completed.stderr) {
    process.stderr.write(completed.stderr);
  }
  if (!completed.stop.quiescent) {
    return completed.stop;
  }
  if (waitExitStatus(completed.wait) !== 0) {
    die(`sim-slim apply failed for ${udid}`);
  }
  return completed.stop;
}

function simctlAlreadyInRequestedState(args: string[], stderr: string): boolean {
  const verb = args[0];
  if (verb === "shutdown" && /current state:\s*Shutdown/i.test(stderr)) {
    return true;
  }
  if (verb === "boot" && /current state:\s*Booted/i.test(stderr)) {
    return true;
  }
  return false;
}

async function runSimctl(session: CommandSession, args: string[], action: string): Promise<void> {
  if (session.canceled) {
    die(`canceled before ${action}`);
  }
  const result = requireQuiescent(await runXcrun(session, ["simctl", ...args]), action);
  if (session.canceled) {
    die(`canceled during ${action}`);
  }
  if (result.code === 0 || simctlAlreadyInRequestedState(args, result.stderr)) {
    return;
  }
  die(`${action} failed: ${result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`}`);
}

export async function prepareSimulator(
  session: CommandSession,
  config: PoolConfig,
  udid: string,
  mode: "normal" | "recovery",
): Promise<void> {
  if (mode === "recovery") {
    log(`[sim-pool] Recovery: shutting down + erasing simulator ${udid}`);
    await runSimctl(session, ["shutdown", udid], "simctl shutdown");
    await runSimctl(session, ["erase", udid], "simctl erase");
  } else if (config.forceCleanBoot) {
    log(`[sim-pool] Preparing clean simulator boot for ${udid}`);
    await runSimctl(session, ["shutdown", udid], "simctl shutdown");
  } else {
    const devices = await listDevices(session, config);
    if (deviceState(devices, udid) === "Booted") {
      log(`[sim-pool] Reusing already-booted simulator ${udid}`);
      if (await waitForBootReadyWithRetries(session, config, udid)) {
        const slim = await slimSimulator(session, config, udid);
        if (!slim.quiescent) {
          die(slim.note ?? "slim did not reach quiescence");
        }
        return;
      }
      log(`[sim-pool] Booted simulator was not ready; recycling ${udid}`);
      await runSimctl(session, ["shutdown", udid], "simctl shutdown");
    } else {
      log(`[sim-pool] Preparing simulator boot for ${udid}`);
      await runSimctl(session, ["shutdown", udid], "simctl shutdown");
    }
  }
  await runSimctl(session, ["boot", udid], "simctl boot");
  if (!(await waitForBootReadyWithRetries(session, config, udid))) {
    die(
      session.canceled
        ? "canceled while waiting for boot-ready"
        : `simulator ${udid} failed to reach boot-ready state after ${config.bootRetries + 1} readiness waits of ${config.bootTimeout}s`,
    );
  }
  const slim = await slimSimulator(session, config, udid);
  if (!slim.quiescent) {
    die(slim.note ?? "slim did not reach quiescence");
  }
}

async function acquireRunSlot(
  config: PoolConfig,
  argv: string[],
  session: CommandSession,
): Promise<OwnedSlot> {
  const deadline = Date.now() + config.waitSeconds * 1000;
  let announced = false;
  while (true) {
    if (session.canceled) {
      die("canceled while waiting for a simulator slot");
    }
    for (const slot of slotNumbers(config)) {
      if (session.canceled) {
        die("canceled while waiting for a simulator slot");
      }
      const result = tryAcquireSlot({ lockDir: config.lockDir, slot, argv });
      if (result.ok) {
        return result.owned;
      }
    }
    if (Date.now() >= deadline) {
      die(
        `all ${config.count} simulator slots (slots ${poolSlotRange(config)}) are busy or quarantined (waited ${config.waitSeconds}s)`,
      );
    }
    if (!announced) {
      log(
        `[sim-pool] All ${config.count} slots (slots ${poolSlotRange(config)}) busy, waiting up to ${config.waitSeconds}s...`,
      );
      announced = true;
    }
    await session.waitWhileIdle(3000);
  }
}

type ArtifactInput = {
  artifactPath: string;
  scope: "attempt" | "final";
  startedAt: number;
  endedAt: number;
  attemptNumber: number;
  attemptCount: number;
  hangDetected: boolean;
  slot: number;
  udid: string;
  derivedData: string;
  logFile: string;
  exitCode: number;
  extra?: Record<string, unknown>;
};

function writeJsonArtifact(input: ArtifactInput): void {
  const payload: Record<string, unknown> = {
    scope: input.scope,
    started_at: iso8601(input.startedAt),
    ended_at: iso8601(input.endedAt),
    started_at_epoch: input.startedAt,
    ended_at_epoch: input.endedAt,
    elapsed_seconds: input.endedAt - input.startedAt,
    attempt_number: input.attemptNumber,
    attempt_count: input.attemptCount,
    hang_detected: input.hangDetected,
    simulator_slot: input.slot,
    simulator_udid: input.udid,
    derived_data_path: input.derivedData,
    log_path: input.logFile,
    last_log_update_age_seconds: input.endedAt - fileMtime(input.logFile),
    exit_code: input.exitCode,
  };
  if (input.extra) {
    Object.assign(payload, input.extra);
  }
  writeFileSync(input.artifactPath, `${JSON.stringify(payload, null, 2)}\n`);
}

function logTestFailureLines(logText: string): string[] {
  return [
    ...new Set(
      logText.split("\n").filter((line) =>
        /failed\b.*-\[|Test Case .* failed|error:.*assert|#expect.* failed|Issue recorded|Expectation failed/.test(
          line,
        ),
      ),
    ),
  ];
}

function extractTestFailures(logText: string, derivedData?: string): { lines: string[]; uncertain: boolean } {
  const fallback = logTestFailureLines(logText);
  if (derivedData) {
    const testLogs = join(derivedData, "Logs", "Test");
    if (existsSync(testLogs)) {
      const bundles = readdirSync(testLogs)
        .filter((name) => name.endsWith(".xcresult"))
        .map((name) => join(testLogs, name))
        .sort();
      const latest = bundles.at(-1);
      if (latest) {
        const tool = spawnSync(
          "xcrun",
          ["xcresulttool", "get", "test-results", "failures", "--path", latest],
          { encoding: "utf8", timeout: 15_000, killSignal: "SIGKILL" },
        );
        if (tool.error || tool.signal != null || tool.status == null) {
          return { lines: fallback, uncertain: true };
        }
        if (tool.status === 0 && tool.stdout.trim() && tool.stdout.trim() !== "[]" && !tool.stdout.includes("No failures")) {
          return { lines: [tool.stdout.trim()], uncertain: false };
        }
      }
    }
  }
  return { lines: fallback, uncertain: false };
}

function printSummary(input: {
  logFile: string;
  exitCode: number;
  startedAt: number;
  endedAt: number;
  totalStartedAt: number;
  totalEndedAt: number;
  attemptCount: number;
  hangDetected: boolean;
  slotWait: number;
  simPrep: number;
  artifactPath: string;
  videoPath?: string;
  derivedData?: string;
}): boolean {
  const duration = input.endedAt - input.startedAt;
  const totalDuration = input.totalEndedAt - input.totalStartedAt;
  const lines: string[] = ["", `Started: ${new Date(input.totalStartedAt * 1000).toLocaleString()}`, `Ended:   ${new Date(input.totalEndedAt * 1000).toLocaleString()}`];
  if (totalDuration !== duration) {
    lines.push(`Total elapsed: ${totalDuration}s`);
    lines.push(`xcodebuild elapsed: ${duration}s`);
    lines.push(
      `Breakdown: slot wait ${input.slotWait}s + simulator prep ${input.simPrep}s + xcodebuild ${duration}s`,
    );
  } else {
    lines.push(`Elapsed: ${duration}s`);
  }
  lines.push(`Attempts: ${input.attemptCount}`);
  lines.push(`Log size: ${fileSize(input.logFile)} bytes`);
  lines.push(`Last log update age: ${input.endedAt - fileMtime(input.logFile)}s`);
  const logText = existsSync(input.logFile) ? readFileSync(input.logFile, "utf8") : "";
  const timing = extractBuildTimingSummary(logText);
  if (timing.length > 0) {
    lines.push("", ...timing);
  }
  if (input.hangDetected) {
    lines.push(`Hang detection: triggered (no log or DerivedData growth for timeout)`);
  }
  lines.push("");
  let extractUncertain = false;
  if (input.exitCode === 0) {
    lines.push("========== BUILD SUCCEEDED ==========");
    const swift = logText
      .split("\n")
      .filter((line) =>
        /^\*\* TEST SUCCEEDED \*\*|Test run with [0-9]+ test|Suite .* passed after/.test(line),
      )
      .slice(-5);
    const xctest = logText.split("\n").filter((line) => /Executed [1-9][0-9]* test/.test(line)).slice(-5);
    const testSummary = swift.length > 0 ? swift : xctest;
    if (testSummary.length > 0) {
      lines.push("", ...testSummary);
    }
  } else {
    lines.push("========== BUILD FAILED ==========", "");
    const errors = extractCompilerLinkerErrors(logText);
    if (errors.length > 0) {
      lines.push(`Compiler/linker errors (${errors.length}):`, ...errors, "");
    }
    const failures = extractTestFailures(logText, input.derivedData);
    extractUncertain = failures.uncertain;
    if (failures.lines.length > 0) {
      lines.push("Test failures:", ...failures.lines, "");
    }
    if (errors.length === 0 && failures.lines.length === 0 && !input.hangDetected) {
      lines.push("(no specific errors extracted — check full log)", "");
    }
  }
  lines.push(`Full log: ${input.logFile}`);
  lines.push(`Artifact: ${input.artifactPath}`);
  if (input.videoPath && existsSync(input.videoPath)) {
    lines.push(`Video: ${input.videoPath}`);
  }
  lines.push("======================================");
  process.stdout.write(`${lines.join("\n")}\n`);
  return extractUncertain;
}

async function runXcodebuildAttempt(input: {
  session: CommandSession;
  config: PoolConfig;
  command: string;
  argv: string[];
  logFile: string;
  derivedData: string;
  udid: string;
  extraSettings: string[];
}): Promise<{ code: number; hung: boolean; stop: StopResult }> {
  writeFileSync(input.logFile, "");
  const logFd = openSync(input.logFile, "a");
  const spawned = await input.session.spawn(
    input.command,
    [
      ...input.argv,
      ...input.extraSettings,
      "-destination",
      `platform=iOS Simulator,id=${input.udid}`,
      "-derivedDataPath",
      input.derivedData,
    ],
    {
      stdio: ["ignore", logFd, logFd],
    },
  );
  closeSync(logFd);
  if (!spawned.ok) {
    return { code: 127, hung: false, stop: spawned.stop ?? { quiescent: true, note: spawned.reason } };
  }
  const start = nowEpoch();
  let lastProgress = start;
  let lastHeartbeat = start;
  let lastMtime = 0;
  let hung = false;
  const exitPromise = spawned.owned.exit;
  const pollMs = Math.max(50, Math.floor(input.config.progressPollSeconds * 1000));
  while (true) {
    if (input.session.canceled) {
      hung = false;
      break;
    }
    const winner = await Promise.race([
      exitPromise.then(() => "exit" as const),
      sleep(pollMs).then(() => "tick" as const),
    ]);
    if (winner === "exit") {
      break;
    }
    const now = nowEpoch();
    const current = progressMtime(input.logFile, input.derivedData);
    if (current > lastMtime) {
      lastMtime = current;
      lastProgress = now;
    }
    if (
      input.config.heartbeatInterval > 0 &&
      now - lastHeartbeat >= input.config.heartbeatInterval
    ) {
      log(
        `[sim-pool] heartbeat: elapsed=${now - start}s idle=${now - lastProgress}s log=${fileSize(input.logFile)}B pid=${spawned.owned.pid}`,
      );
      lastHeartbeat = now;
    }
    if (input.config.silenceTimeout > 0 && now - lastProgress >= input.config.silenceTimeout) {
      log(
        `[sim-pool] hang detected: no log or DerivedData growth for ${input.config.silenceTimeout}s (pid ${spawned.owned.pid})`,
      );
      hung = true;
      break;
    }
  }
  const completed = await input.session.complete(spawned.owned, {
    stopFirst: hung || input.session.canceled,
  });
  if (hung && !completed.stop.quiescent) {
    return { code: 1, hung: true, stop: completed.stop };
  }
  return { code: waitExitStatus(completed.wait), hung, stop: completed.stop };
}

function pruneOldLogs(logDir: string): void {
  if (!existsSync(logDir)) {
    return;
  }
  const cutoff = Date.now() - 3 * 24 * 60 * 60 * 1000;
  for (const name of readdirSync(logDir)) {
    if (!/^pool-.*\.(log|json|summary\.json)$/.test(name)) {
      continue;
    }
    const path = join(logDir, name);
    try {
      if (statSync(path).mtimeMs < cutoff) {
        rmSync(path, { force: true });
      }
    } catch {
      // keep going
    }
  }
}

type VideoSession = {
  supervised: Supervised;
  path: string;
  logPath: string;
  ready: boolean;
};

async function startVideoRecording(
  session: CommandSession,
  config: PoolConfig,
  slot: number,
  udid: string,
  stamp: string,
): Promise<VideoSession | null> {
  if (config.videoPolicy === "off") {
    return null;
  }
  mkdirSync(config.videoDir, { recursive: true });
  const baseName = config.videoName || `pool-${slot}-${stamp}`;
  const path = join(config.videoDir, `${baseName}.mp4`);
  const logPath = join(config.videoDir, `${baseName}.recordVideo.log`);
  writeFileSync(logPath, "");
  log(`[sim-pool] Recording simulator video (${config.videoPolicy}): ${path}`);
  const errFd = openSync(logPath, "a");
  const spawned = await session.spawn(
    "xcrun",
    ["simctl", "io", udid, "recordVideo", "--codec=h264", path],
    { stdio: ["ignore", "ignore", errFd] },
  );
  closeSync(errFd);
  if (!spawned.ok) {
    log(`[sim-pool] WARNING: simulator video recorder failed to start`);
    return null;
  }
  const deadline = Date.now() + config.videoReadyTimeout * 1000;
  let ready = false;
  while (Date.now() < deadline) {
    if (session.canceled) {
      break;
    }
    const text = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
    if (text.includes("Recording started")) {
      ready = true;
      log("[sim-pool] Simulator video recording is ready");
      break;
    }
    if (spawned.owned.child.exitCode != null) {
      log(`[sim-pool] WARNING: simulator video recorder exited before readiness; log: ${logPath}`);
      break;
    }
    await sleep(200);
  }
  if (!ready && spawned.owned.child.exitCode == null) {
    log(
      `[sim-pool] WARNING: simulator video recorder did not report readiness within ${config.videoReadyTimeout}s; continuing`,
    );
  }
  return { supervised: spawned.owned, path, logPath, ready };
}

function commandRunExitCode(input: {
  canceled: boolean;
  cancelExitCode: number;
  uncertain: boolean;
  exitCode: number;
}): number {
  if (input.canceled) {
    return input.cancelExitCode;
  }
  if (input.uncertain && input.exitCode === 0) {
    return 1;
  }
  return input.exitCode;
}

export async function commandRun(config: PoolConfig, rawArgs: string[]): Promise<number> {
  const session = new CommandSession();
  session.installHandlers();
  if (rawArgs[0] !== "--" || rawArgs.length < 2) {
    usage();
  }
  let args = rawArgs.slice(1);
  const cwdPbx = join(process.cwd(), "Oppi.xcodeproj", "project.pbxproj");
  const scriptPbx = join(config.appleDir, "Oppi.xcodeproj", "project.pbxproj");
  if (!existsSync(cwdPbx) && existsSync(scriptPbx)) {
    process.chdir(config.appleDir);
    log(`[sim-pool] Using Apple checkout ${process.cwd()}`);
  }
  const normalized = normalizeCommandArgs(config, args);
  args = normalized.args;
  if (normalized.log) {
    log(normalized.log);
  }
  validateCommandGuardrails(config, args);
  const split = splitRunCommand(args);
  const extraSettings = applyPoolBuildSettings(config, split.argv);
  const runStart = nowEpoch();
  let owned: OwnedSlot | undefined;
  const slotWaitEndHolder = { value: runStart };
  let uncertain = false;
  let videoSession: VideoSession | null = null;
  let simUdId = "";
  let finalArtifact = "";
  let logFile = "";
  let derivedData = "";
  let exitCode = 1;
  let hangDetected = false;
  let attemptsUsed = 0;
  let prepStart = runStart;
  let prepEnd = runStart;
  let simPrep = 0;
  let xcodeStart = runStart;
  let xcodeEnd = runStart;
  let videoPath: string | undefined;
  let videoRecording: Record<string, unknown> | undefined;
  const attemptArtifacts: string[] = [];
  try {
    owned = await acquireRunSlot(config, ["run", ...args], session);
    slotWaitEndHolder.value = nowEpoch();
    const slotOwner = owned;
    session.onSpawned = (child) => {
      recordOwnedPgid(slotOwner, child.pgid);
    };
    if (session.canceled) {
      uncertain = true;
      return session.cancelExitCode();
    }
    log(`[sim-pool] Acquired slot ${owned.slot}`);
    simUdId = await ensureSim(session, config, owned.slot);
    derivedData = join(config.buildBase, `pool-${owned.slot}`);
    mkdirSync(derivedData, { recursive: true });
    log(`[sim-pool] Simulator: ${poolDeviceName(owned.slot)} (${simUdId})`);
    log(`[sim-pool] DerivedData: ${derivedData}`);
    prepStart = nowEpoch();
    await prepareSimulator(session, config, simUdId, "normal");
    prepEnd = nowEpoch();
    const logDir = join(config.buildBase, "logs");
    mkdirSync(logDir, { recursive: true });
    pruneOldLogs(logDir);
    const stamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
    const baseLog = join(logDir, `pool-${owned.slot}-${stamp}.log`);
    const baseArtifact = baseLog.replace(/\.log$/, ".json");
    finalArtifact = baseLog.replace(/\.log$/, ".summary.json");
    log(`[sim-pool] Log: ${baseLog}`);
    videoSession = await startVideoRecording(session, config, owned.slot, simUdId, stamp);
    logFile = baseLog;
    xcodeStart = nowEpoch();
    let attempt = 0;
    exitCode = 0;
    simPrep = prepEnd - prepStart;
    while (true) {
      if (session.canceled) {
        uncertain = true;
        exitCode = session.cancelExitCode();
        break;
      }
      attemptsUsed = attempt + 1;
      let artifactFile = baseArtifact;
      const attemptStart = nowEpoch();
      if (attempt > 0) {
        logFile = baseLog.replace(/\.log$/, `-retry${attempt}.log`);
        artifactFile = baseArtifact.replace(/\.json$/, `-retry${attempt}.json`);
        log(`[sim-pool] Retry ${attemptsUsed}/${config.hangRetries + 1} — log: ${logFile}`);
        const recoveryStart = nowEpoch();
        await prepareSimulator(session, config, simUdId, "recovery");
        simPrep += nowEpoch() - recoveryStart;
      }
      const attemptArgs = buildAttemptCommand(attempt, split.argv);
      if (attempt > 0) {
        const bundle = extractFlagValue("-resultBundlePath", attemptArgs);
        if (bundle) {
          log(`[sim-pool] Retry result bundle: ${bundle}`);
        }
      }
      const result = await runXcodebuildAttempt({
        session,
        config,
        command: split.command,
        argv: attemptArgs,
        logFile,
        derivedData,
        udid: simUdId,
        extraSettings,
      });
      exitCode = result.code;
      hangDetected = hangDetected || result.hung;
      if (!result.stop.quiescent) {
        uncertain = true;
        exitCode = exitCode || 1;
        break;
      }
      const attemptEnd = nowEpoch();
      writeJsonArtifact({
        artifactPath: artifactFile,
        scope: "attempt",
        startedAt: attemptStart,
        endedAt: attemptEnd,
        attemptNumber: attemptsUsed,
        attemptCount: attemptsUsed,
        hangDetected: result.hung,
        slot: owned.slot,
        udid: simUdId,
        derivedData,
        logFile,
        exitCode,
      });
      attemptArtifacts.push(artifactFile);
      if (result.hung && attempt < config.hangRetries) {
        log("[sim-pool] Retrying after simulator hang recovery...");
        attempt += 1;
        continue;
      }
      break;
    }
    xcodeEnd = nowEpoch();
    if (videoSession) {
      const completed = await session.complete(videoSession.supervised, {
        stopFirst: true,
        firstSignal: "SIGINT",
      });
      if (!completed.stop.quiescent) {
        uncertain = true;
      }
      const keep =
        config.videoPolicy === "always" ||
        (config.videoPolicy === "on-failure" && (exitCode !== 0 || hangDetected));
      const size = existsSync(videoSession.path) ? fileSize(videoSession.path) : 0;
      let deletedReason: string | undefined;
      if (keep && existsSync(videoSession.path)) {
        videoPath = videoSession.path;
        log(`[sim-pool] Video saved: ${videoSession.path}`);
      } else if (existsSync(videoSession.path)) {
        rmSync(videoSession.path, { force: true });
        deletedReason = config.videoPolicy === "on-failure" && exitCode === 0 && !hangDetected ? "passed" : "missing";
        if (deletedReason === "passed") {
          log("[sim-pool] Video discarded after passing run (policy: on-failure)");
        }
      }
      videoRecording = {
        policy: config.videoPolicy,
        path: videoSession.path,
        retained: Boolean(videoPath),
        ready: videoSession.ready,
        log_path: videoSession.logPath,
        stop_status: completed.stop.quiescent ? 0 : 1,
        size_bytes: size,
        ...(deletedReason ? { deleted_reason: deletedReason } : {}),
      };
      videoSession = null;
    }
    if (!config.keepBooted && simUdId) {
      log(`[sim-pool] Shutting down pool simulator ${simUdId}`);
      const shutdown = await runXcrun(session, ["simctl", "shutdown", simUdId]);
      if (
        !shutdown.stop.quiescent ||
        (shutdown.code !== 0 && !simctlAlreadyInRequestedState(["shutdown"], shutdown.stderr))
      ) {
        uncertain = true;
      }
    }
    if (session.canceled) {
      uncertain = true;
      exitCode = session.cancelExitCode();
    }
  } catch (error) {
    uncertain = true;
    if (session.canceled) {
      exitCode = session.cancelExitCode();
    } else {
      throw error;
    }
  } finally {
    if (videoSession && !videoSession.supervised.retired) {
      const completed = await session.complete(videoSession.supervised, {
        stopFirst: true,
        firstSignal: "SIGINT",
      });
      if (!completed.stop.quiescent) {
        uncertain = true;
      }
    }
    const stopped = await session.dispose();
    if (!stopped.quiescent) {
      uncertain = true;
    }
    const slotWaitEnd = slotWaitEndHolder.value;
    const runEnd = nowEpoch();
    if (owned && finalArtifact && !uncertain) {
      try {
        writeJsonArtifact({
          artifactPath: finalArtifact,
          scope: "final",
          startedAt: xcodeStart,
          endedAt: xcodeEnd,
          attemptNumber: attemptsUsed,
          attemptCount: attemptsUsed,
          hangDetected,
          slot: owned.slot,
          udid: simUdId,
          derivedData,
          logFile,
          exitCode,
          extra: {
            attempt_artifacts: attemptArtifacts,
            ...(videoPath ? { video_path: videoPath } : {}),
            ...(videoRecording ? { video_recording: videoRecording } : {}),
            timing_breakdown_seconds: {
              slot_wait: slotWaitEnd - runStart,
              simulator_prepare: simPrep,
              xcodebuild: xcodeEnd - xcodeStart,
              total_wall: runEnd - runStart,
            },
            timing_phase_epochs: {
              run_start: runStart,
              run_end: runEnd,
              slot_wait_start: runStart,
              slot_wait_end: slotWaitEnd,
              simulator_prepare_start: prepStart,
              simulator_prepare_end: prepEnd,
              xcodebuild_start: xcodeStart,
              xcodebuild_end: xcodeEnd,
            },
          },
        });
        log(`[sim-pool] Artifact: ${finalArtifact}`);
        printSummary({
          logFile,
          exitCode,
          startedAt: xcodeStart,
          endedAt: xcodeEnd,
          totalStartedAt: runStart,
          totalEndedAt: runEnd,
          attemptCount: attemptsUsed,
          hangDetected,
          slotWait: slotWaitEnd - runStart,
          simPrep,
          artifactPath: finalArtifact,
          videoPath,
          derivedData,
        });
      } catch {
        uncertain = true;
      }
    } else if (owned && finalArtifact && uncertain) {
      try {
        writeJsonArtifact({
          artifactPath: finalArtifact,
          scope: "final",
          startedAt: runStart,
          endedAt: runEnd,
          attemptNumber: attemptsUsed,
          attemptCount: attemptsUsed,
          hangDetected,
          slot: owned.slot,
          udid: simUdId,
          derivedData,
          logFile: logFile || finalArtifact,
          exitCode: session.canceled ? session.cancelExitCode() : exitCode || 1,
          extra: { incomplete: true },
        });
      } catch {
        // keep original error
      }
    }
    if (owned) {
      if (!stopped.quiescent) {
        releaseUncertain(owned, stopped.note ?? "run ended without proven quiescence");
      } else {
        releaseReusable(owned);
      }
    }
  }
  return commandRunExitCode({
    canceled: session.canceled,
    cancelExitCode: session.cancelExitCode(),
    uncertain,
    exitCode,
  });
}

export type PruneKeep = { start: number; end: number } | null;

export function parsePruneKeepSlots(spec: string): { start: number; end: number } {
  const match = /^([0-9]+)-([0-9]+)$/.exec(spec);
  if (!match) {
    die(`invalid --keep-slots '${spec}' (expected START-END)`);
  }
  const start = Number(match[1]);
  const end = Number(match[2]);
  if (end < start) {
    die(`invalid --keep-slots '${spec}' (END must be >= START)`);
  }
  return { start, end };
}

export function pruneBuildKind(base: string): "pool" | "derived" | "mac-stale" | null {
  switch (base) {
    case "logs":
    case "videos":
    case "mac-tests":
    case "mac-debug":
    case "pre-push-mac":
    case "ci":
    case "privacy":
    case "oppi-dev":
      return null;
    default:
      break;
  }
  if (/^pool-[0-9]+$/.test(base)) {
    return "pool";
  }
  if (base.startsWith("derived-data-")) {
    return "derived";
  }
  if (base.startsWith("mac-")) {
    return "mac-stale";
  }
  return null;
}

function canonical(path: string): string {
  return realpathSync.native(path);
}

export function commandPruneCache(config: PoolConfig, args: string[]): number {
  let apply = false;
  let keep: PruneKeep = null;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--apply") {
      apply = true;
      continue;
    }
    if (arg === "--keep-slots") {
      const spec = args[i + 1];
      if (!spec) {
        die("usage: sim-pool.sh prune-cache [--apply] [--keep-slots START-END]");
      }
      keep = parsePruneKeepSlots(spec);
      i += 1;
      continue;
    }
    if (arg.startsWith("--keep-slots=")) {
      keep = parsePruneKeepSlots(arg.slice("--keep-slots=".length));
      continue;
    }
    die("usage: sim-pool.sh prune-cache [--apply] [--keep-slots START-END]");
  }

  const gitRoot = gitTopLevel(process.cwd());
  if (!gitRoot) {
    die("prune-cache requires a Git checkout");
  }
  if (!existsSync(join(gitRoot, "clients", "apple"))) {
    die("prune-cache: checkout is missing clients/apple");
  }
  if (config.oppiRootFromEnv) {
    try {
      if (canonical(config.oppiRoot) !== canonical(gitRoot)) {
        die(`prune-cache: OPPI_ROOT '${config.oppiRoot}' does not match Git checkout '${gitRoot}'`);
      }
    } catch {
      die("prune-cache: OPPI_ROOT is not resolvable");
    }
  }
  const appleDir = join(gitRoot, "clients", "apple");
  const buildBase = join(appleDir, ".build");
  for (const path of [gitRoot, appleDir, buildBase]) {
    try {
      if (statSync(path).isSymbolicLink?.() || (existsSync(path) && statSync(path).isSymbolicLink())) {
        die("prune-cache: refusing symlinked cleanup root");
      }
    } catch {
      // missing handled below
    }
  }
  if (existsSync(gitRoot) && (lstatIsSymlink(gitRoot) || lstatIsSymlink(appleDir) || (existsSync(buildBase) && lstatIsSymlink(buildBase)))) {
    die("prune-cache: refusing symlinked cleanup root");
  }
  if (!existsSync(buildBase)) {
    log(`[sim-pool] prune-cache: no ${buildBase}`);
    return 0;
  }
  if (!statSync(buildBase).isDirectory()) {
    die(`prune-cache: cleanup root is not a directory: ${buildBase}`);
  }
  if (!apply) {
    log(
      "[sim-pool] prune-cache: dry-run (pass --apply to delete idle pool dirs with a slot lease; derived-data-* and mac-* need an exclusive lease and are skipped on apply)",
    );
  }
  let status = 0;
  for (const name of readdirSync(buildBase)) {
    const path = join(buildBase, name);
    const kind = pruneBuildKind(name);
    if (!kind) {
      continue;
    }
    if (lstatIsSymlink(path)) {
      log(`[sim-pool] prune-cache: skipping symlinked ${path}`);
      continue;
    }
    if (!statSync(path).isDirectory()) {
      log(`[sim-pool] prune-cache: skipping non-directory ${path}`);
      continue;
    }
    if (kind === "pool") {
      const slot = Number(name.slice("pool-".length));
      if (keep && slot >= keep.start && slot <= keep.end) {
        log(`[sim-pool] prune-cache: keeping ${path} (--keep-slots ${keep.start}-${keep.end})`);
        continue;
      }
      if (!apply) {
        log(`[sim-pool] prune-cache: would delete ${path}`);
        continue;
      }
      const acquired = tryAcquireSlot({ lockDir: config.lockDir, slot, argv: ["prune-cache"] });
      if (!acquired.ok) {
        log(`[sim-pool] prune-cache: skipping busy or quarantined slot ${slot} (${acquired.reason})`);
        continue;
      }
      log(`[sim-pool] prune-cache: deleting ${path}`);
      try {
        rmSync(path, { recursive: true, force: false });
        if (existsSync(path)) {
          throw new Error("path remains");
        }
        releaseReusable(acquired.owned);
      } catch {
        log(`[sim-pool] prune-cache: failed to delete ${path}`);
        releaseUncertain(acquired.owned, "prune delete failed");
        status = 1;
      }
      continue;
    }
    if (!apply) {
      log(`[sim-pool] prune-cache: would delete if exclusive ${path}`);
      continue;
    }
    log(`[sim-pool] prune-cache: skipping ${path} (no exclusive lease)`);
  }
  return status;
}

function lstatIsSymlink(path: string): boolean {
  try {
    return lstatSync(path).isSymbolicLink();
  } catch {
    return false;
  }
}

export async function commandShutdownIdle(config: PoolConfig): Promise<number> {
  const session = new CommandSession();
  session.installHandlers();
  let status = 0;
  try {
    if (session.canceled) {
      return session.cancelExitCode();
    }
    const list = await runXcrun(session, ["simctl", "list", "devices", "-j"]);
    if (session.canceled) {
      return session.cancelExitCode();
    }
    if (!list.stop.quiescent) {
      log(`[sim-pool] shutdown-idle: list did not prove quiescence${list.stop.note ? ` (${list.stop.note})` : ""}`);
      return 1;
    }
    if (list.code !== 0) {
      log("[sim-pool] shutdown-idle: failed to list simulators");
      return 1;
    }
    let devices: SimulatorDevice[];
    try {
      devices = parseDevicesJson(list.stdout);
    } catch {
      log("[sim-pool] shutdown-idle: failed to parse simulator list");
      return 1;
    }
    const candidates = devices.filter((device) => {
      const match = /^Oppi-Pool-(\d+)$/.exec(device.name);
      return Boolean(match) && device.state === "Booted";
    });
    for (const device of candidates) {
      if (session.canceled) {
        status = session.cancelExitCode();
        break;
      }
      const slot = Number(/^Oppi-Pool-(\d+)$/.exec(device.name)?.[1]);
      const acquired = tryAcquireSlot({ lockDir: config.lockDir, slot, argv: ["shutdown-idle"] });
      if (!acquired.ok) {
        if (
          acquired.reason.includes("legacy") ||
          acquired.reason.includes("busy") ||
          acquired.reason.includes("in-flight") ||
          acquired.reason.includes("uncertain")
        ) {
          log(`[sim-pool] shutdown-idle: skipping existing slot lock ${slot}`);
        } else {
          log(`[sim-pool] shutdown-idle: failed to acquire slot ${slot}`);
          status = 1;
        }
        continue;
      }
      let released = false;
      const finishSlot = (kind: "reusable" | "uncertain", note?: string): void => {
        if (released) {
          return;
        }
        released = true;
        if (kind === "uncertain") {
          releaseUncertain(acquired.owned, note ?? "shutdown-idle did not prove quiescence");
        } else {
          releaseReusable(acquired.owned);
        }
      };
      try {
        if (session.canceled) {
          finishSlot("uncertain", "canceled before shutdown mutation");
          status = session.cancelExitCode();
          break;
        }
        const recheck = await runXcrun(session, ["simctl", "list", "devices", "-j"]);
        if (session.canceled) {
          finishSlot("uncertain", "canceled during locked recheck");
          status = session.cancelExitCode();
          break;
        }
        if (!recheck.stop.quiescent) {
          log(`[sim-pool] shutdown-idle: recheck did not prove quiescence for ${device.udid}`);
          finishSlot("uncertain", recheck.stop.note ?? "recheck did not prove quiescence");
          status = 1;
          continue;
        }
        if (recheck.code !== 0) {
          log(`[sim-pool] shutdown-idle: failed to recheck ${device.udid}`);
          finishSlot("reusable");
          status = 1;
          continue;
        }
        let state = "";
        try {
          state = deviceState(parseDevicesJson(recheck.stdout), device.udid) ?? "";
        } catch {
          state = "";
        }
        if (!state) {
          log(`[sim-pool] shutdown-idle: failed to recheck ${device.udid}`);
          finishSlot("reusable");
          status = 1;
          continue;
        }
        if (state !== "Booted") {
          log(`[sim-pool] shutdown-idle: ${device.udid} state is ${state} (not Booted)`);
          finishSlot("reusable");
          continue;
        }
        if (session.canceled) {
          finishSlot("uncertain", "canceled before simctl shutdown");
          status = session.cancelExitCode();
          break;
        }
        log(`[sim-pool] Shutting down idle simulator ${device.udid}`);
        const shutdown = await runXcrun(session, ["simctl", "shutdown", device.udid]);
        if (!shutdown.stop.quiescent) {
          log(`[sim-pool] shutdown-idle: shutdown did not prove quiescence for ${device.udid}`);
          finishSlot("uncertain", shutdown.stop.note ?? "shutdown did not prove quiescence");
          status = 1;
          continue;
        }
        if (shutdown.code !== 0) {
          log(`[sim-pool] shutdown-idle: failed to shut down ${device.udid}`);
          finishSlot("uncertain", "simctl shutdown failed");
          status = 1;
          continue;
        }
        if (session.canceled) {
          finishSlot("reusable");
          status = session.cancelExitCode();
          break;
        }
        finishSlot("reusable");
      } catch (error) {
        finishSlot("uncertain", error instanceof Error ? error.message : String(error));
        throw error;
      } finally {
        if (!released) {
          finishSlot("uncertain", "shutdown-idle released without completion");
        }
      }
    }
    if (session.canceled) {
      status = session.cancelExitCode();
    }
  } finally {
    const stopped = await session.dispose();
    if (!stopped.quiescent && status === 0 && !session.canceled) {
      status = 1;
    }
  }
  return status;
}

export function commandStatus(config: PoolConfig): number {
  process.stdout.write(`Pool count: ${config.count}\n`);
  process.stdout.write(`Pool slot start: ${config.slotStart}\n`);
  process.stdout.write(`Pool slot range: ${poolSlotRange(config)}\n`);
  process.stdout.write(`Lock dir: ${config.lockDir}\n`);
  process.stdout.write(`Build base: ${config.buildBase}\n\nLocks:\n`);
  mkdirSync(config.lockDir, { recursive: true });
  let found = false;
  const names = existsSync(config.lockDir) ? readdirSync(config.lockDir) : [];
  for (const name of names) {
    const match = /^slot-([0-9]+)(\.lock)?$/.exec(name);
    if (!match) {
      continue;
    }
    if (name.endsWith(".state.json")) {
      continue;
    }
  }
  const slots = new Set<number>();
  for (const name of names) {
    const lockMatch = /^slot-([0-9]+)\.lock$/.exec(name);
    const dirMatch = /^slot-([0-9]+)$/.exec(name);
    if (lockMatch) {
      slots.add(Number(lockMatch[1]));
    }
    if (dirMatch) {
      slots.add(Number(dirMatch[1]));
    }
  }
  if (slots.size === 0) {
    process.stdout.write("  none\n");
  } else {
    found = true;
    for (const slot of [...slots].sort((a, b) => a - b)) {
      const info = inspectSlot(config.lockDir, slot);
      const label = info.legacy
        ? "legacy"
        : info.flockHeld
          ? "live"
          : info.state && info.state !== "unreadable"
            ? info.state.status
            : "idle";
      process.stdout.write(`  slot-${slot} ${label}\n`);
    }
  }
  void found;
  process.stdout.write("\nPool and booted simulators:\n");
  const listed = spawnSync("xcrun", ["simctl", "list", "devices", "-j"], { encoding: "utf8" });
  if (listed.status === 0) {
    const devices = parseDevicesJson(listed.stdout);
    for (const device of devices) {
      const pool = /^Oppi-Pool-(\d+)$/.exec(device.name);
      if (!pool && device.state !== "Booted") {
        continue;
      }
      const slot = pool ? Number(pool[1]) : null;
      const info = slot != null ? inspectSlot(config.lockDir, slot) : null;
      const marker = info?.flockHeld || info?.legacy || (info?.state && info.state !== "unreadable" && info.state.status !== "reusable")
        ? "locked"
        : "idle";
      process.stdout.write(
        `  ${device.name.padEnd(18)} ${device.state.padEnd(8)} ${marker.padEnd(6)} ${device.udid}\n`,
      );
    }
  }
  return 0;
}

export function usage(): never {
  process.stderr.write(`Usage:
  sim-pool.sh run -- <xcodebuild args...>
  sim-pool.sh self-test
  sim-pool.sh status
  sim-pool.sh shutdown-idle
  sim-pool.sh prune-cache [--apply] [--keep-slots START-END]

run acquires a simulator pool slot, injects -destination and -derivedDataPath,
runs xcodebuild, and releases the slot on exit. An already-booted pool
simulator is reused unless OPPI_SIM_POOL_FORCE_CLEAN_BOOT=1. Pool simulators
stay booted after a run unless OPPI_SIM_POOL_KEEP_BOOTED=0. Unused simulator
daemons are disabled unless OPPI_SIM_SLIM=0. Compiler index store is
disabled unless OPPI_SIM_POOL_INDEX_STORE=1 or the command already sets
COMPILER_INDEX_STORE_ENABLE. Ordinary run does not delete unavailable
simulators or CoreSimulator device caches.

shutdown-idle acquires each slot with flock. Existing live, legacy, in-flight,
and uncertain slots are skipped. Booted is rechecked as device state, not
idleness. Killing xcrun does not mean CoreSimulator finished.

prune-cache dry-runs this checkout's numeric pool-* dirs, derived-data-*, and
one-off mac-* experiment dirs. --apply deletes pool-* only after acquiring the
slot lease. derived-data-* and mac-* are skipped on apply (no exclusive lease).
`);
  process.exit(1);
}
