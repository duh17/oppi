import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { RemoteExecutionEnv, sshConnection, type Connection } from "@earendil-works/pi-env";
import { machineFailure } from "./errors.js";
import type { Machine, MachineCheck, MachineRegistry, MachineTest } from "./registry.js";

/** PATH for the commands that find the real PATH (`add` runs before the machine has one). */
const BASE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin";

/** A short-lived connection and environment on a machine, closed by `close`. */
export function openProbe(
  registry: MachineRegistry,
  machine: Pick<Machine, "name" | "host" | "user" | "port" | "path" | "home">,
): { connection: Connection; env: RemoteExecutionEnv; close: () => void } {
  const { connection } = sshConnection(registry.target(machine));
  const env = new RemoteExecutionEnv({
    connection,
    id: `pi-env:${machine.name}:probe`,
    cwd: machine.home || "/",
    shellEnv: { PATH: machine.path || BASE_PATH },
  });
  return { connection, env, close: () => connection.close() };
}

/** Run `command` on the machine: whether it exited 0, and its output. */
export async function run(
  env: RemoteExecutionEnv,
  command: string,
  timeoutSeconds = 30,
): Promise<{ ok: boolean; out: string }> {
  let out = "";
  const result = await env.exec(
    command,
    {
      timeout: timeoutSeconds,
      onOutput: (text) => {
        out += text;
      },
    },
    BACKGROUND_CONTEXT,
  );
  if (!result.ok) return { ok: false, out: result.error.message };
  return { ok: result.value.exitCode === 0, out: out.trim() };
}

/** The PATH of the machine's login shell, whatever the shell is (fish prints it colon-separated too). */
export async function capturePath(env: RemoteExecutionEnv): Promise<string> {
  const { ok, out } = await run(env, `sh -c '"$SHELL" -l -c "printenv PATH"'`);
  const path = out.split("\n").pop()?.trim() ?? "";
  if (!ok || !path.includes(":"))
    throw new Error(`Could not read PATH from the login shell: ${out}`);
  return path;
}

/**
 * `oppi machines test`: connect, start the helper, and run one trivial command. Never prompts.
 * What else the machine has (git, toolchains, disk, sleep) is the owner's setup: a command that
 * needs a missing tool fails with that tool's own error.
 */
export async function runMachineChecks(
  registry: MachineRegistry,
  machine: Machine,
): Promise<MachineTest> {
  const checks: MachineCheck[] = [];
  const add = (name: string, ok: boolean, detail: string): void => {
    checks.push({ name, required: true, ok, detail });
  };
  const probe = openProbe(registry, machine);
  try {
    try {
      const info = await probe.connection.info();
      add("connect", true, `${info.os ?? machine.platform} ${info.arch ?? machine.arch}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      add("connect", false, machineFailure(machine.name, message) ?? message);
      return { at: Date.now(), ok: false, checks };
    }
    const { ok, out } = await run(probe.env, "echo oppi");
    add("command", ok && out === "oppi", ok ? "ran a command" : out);
  } finally {
    probe.close();
  }
  return { at: Date.now(), ok: checks.every((check) => check.ok), checks };
}
