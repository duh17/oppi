import { createInterface } from "node:readline/promises";
import * as c from "../../ansi.js";
import { runMachineChecks } from "../../machines/checks.js";
import { placementsFor, type Placement } from "../../machines/placements.js";
import { MachineRegistry, type Machine } from "../../machines/registry.js";
import {
  addMachine,
  forgetMachine,
  keyBlob,
  removeAuthorizedKey,
  type SetupIo,
} from "../../machines/setup.js";
import { handleModelResolvingCliError } from "../command-support.js";
import {
  captureHumanCliOutput,
  setCapturedCliExitCode,
  writeHumanLine,
  writeHumanLineRaw,
  writeJsonEnvelope,
  writeStderrLine,
} from "../output.js";

/** Progress goes to the terminal; with `--json` it goes to stderr so stdout stays one envelope. */
function terminalIo(json: boolean): SetupIo {
  return {
    say: (line) => (json ? writeStderrLine(`  ${line}`) : writeHumanLine(`  ${line}`)),
    sayRaw: (line) => (json ? writeStderrLine(`  ${line}`) : writeHumanLineRaw(`  ${line}`)),
    confirm: async (question) => {
      // Nothing to ask without a terminal: the caller's flags are the approval.
      if (!process.stdin.isTTY) return false;
      const rl = createInterface({
        input: process.stdin,
        output: json ? process.stderr : process.stdout,
      });
      try {
        return /^y(es)?$/i.test((await rl.question(`  ${question} [y/N] `)).trim());
      } finally {
        rl.close();
      }
    },
  };
}

const ago = (at: number): string => {
  const minutes = Math.max(0, Math.round((Date.now() - at) / 60_000));
  if (minutes < 90) return `${minutes} min ago`;
  return minutes < 2 * 24 * 60
    ? `${Math.round(minutes / 60)} h ago`
    : `${Math.round(minutes / 1440)} d ago`;
};

const target = (machine: Machine): string =>
  `${machine.user}@${machine.host}${machine.port === undefined ? "" : `:${machine.port}`}`;

/** Workers that hold work on `machine`: running ones, and branches not fetched home yet. */
function holds(dataDir: string, machine: string): { running: Placement[]; unfetched: Placement[] } {
  const here = placementsFor(dataDir)
    .list()
    .filter((placement) => placement.machine === machine);
  return {
    running: here.filter((placement) => placement.active),
    unfetched: here.filter((placement) => !placement.fetched),
  };
}

function required(registry: MachineRegistry, name: string | undefined): Machine {
  if (!name) throw new Error("Name a machine: oppi machines <add|test|remove> <name>");
  const machine = registry.get(name);
  if (!machine) throw new Error(`No machine named ${name}. \`oppi machines list\` shows them.`);
  return machine;
}

/** `oppi machines add|test|list|remove`. Works on the data directory; the server need not run. */
export async function cmdMachines(
  dataDir: string,
  action: string | undefined,
  args: string[],
  flags: Record<string, string>,
): Promise<void> {
  const json = flags.json === "true";
  try {
    await runMachines(dataDir, action, args, flags, json);
  } catch (error) {
    handleModelResolvingCliError(error, json);
  }
}

async function runMachines(
  dir: string,
  action: string | undefined,
  args: string[],
  flags: Record<string, string>,
  json: boolean,
): Promise<void> {
  const registry = new MachineRegistry(dir);
  const io = terminalIo(json);
  const output = (data: Record<string, unknown>, human: () => void): void => {
    if (json) {
      writeJsonEnvelope({ ok: true, data });
      captureHumanCliOutput(human);
    } else human();
  };
  switch (action ?? "list") {
    case "add": {
      const name = args[0];
      if (!name || !flags.ssh || flags.ssh === "true")
        throw new Error("Usage: oppi machines add <name> --ssh [user@]host[:port]");
      const machine = await addMachine(
        registry,
        {
          name,
          ssh: flags.ssh,
          ...(flags.from && flags.from !== "true" ? { from: flags.from } : {}),
          install: flags.yes === "true",
          ...(flags["host-key"] && flags["host-key"] !== "true"
            ? { hostKey: flags["host-key"] }
            : {}),
        },
        io,
      );
      output({ machine }, () => writeHumanLine(c.green(`  ${name} is set up.`)));
      return;
    }
    case "test": {
      const machine = required(registry, args[0]);
      const test = await runMachineChecks(registry, machine);
      registry.save({ ...machine, test });
      output({ machine: machine.name, test }, () => {
        for (const check of test.checks)
          writeHumanLine(
            `  ${check.ok ? c.green("ok  ") : c.red("FAIL")} ${check.name}: ${check.detail}`,
          );
      });
      if (!test.ok) setCapturedCliExitCode(1);
      return;
    }
    case "list": {
      const rows = registry.list().map((machine) => ({
        name: machine.name,
        ssh: target(machine),
        platform: `${machine.platform} ${machine.arch}`,
        test: machine.test ? { ok: machine.test.ok, at: machine.test.at } : null,
        runningWorkers: holds(dir, machine.name).running.length,
      }));
      output({ machines: rows }, () => {
        if (rows.length === 0) writeHumanLine("  No machines. `oppi machines add` sets one up.");
        for (const row of rows)
          writeHumanLine(
            `  ${c.bold(row.name)}  ${row.ssh}  ${row.platform}  ` +
              (row.test
                ? `${row.test.ok ? "passed" : "FAILED"} ${ago(row.test.at)}`
                : "not tested") +
              `  ${row.runningWorkers} running`,
          );
      });
      return;
    }
    case "remove": {
      const machine = required(registry, args[0]);
      const { running, unfetched } = holds(dir, machine.name);
      if ((running.length > 0 || unfetched.length > 0) && flags.force !== "true")
        throw new Error(
          running.length > 0
            ? `${machine.name} still has ${running.length} running worker(s). Wait for them, or use --force.`
            : `${machine.name} holds ${unfetched.length} branch(es) not fetched yet (${unfetched.map((p) => p.branch).join(", ")}). Use --force to drop them.`,
        );
      const publicKey = await registry.publicKey();
      const approved =
        flags.yes === "true" ||
        (await io.confirm(
          `Remove this server's key from ${machine.name}'s authorized_keys with your own ssh?`,
        ));
      if (approved) {
        await removeAuthorizedKey(`${target(machine)}`, keyBlob(publicKey));
        io.say(`Removed the key from ${machine.name}'s ~/.ssh/authorized_keys.`);
      } else {
        io.say(`Delete the line holding this key from ${machine.name}'s ~/.ssh/authorized_keys:`);
        io.sayRaw(publicKey);
      }
      await forgetMachine(registry, machine);
      output({ removed: machine.name, keyRemoved: approved }, () =>
        writeHumanLine(c.green(`  ${machine.name} removed.`)),
      );
      return;
    }
    default:
      throw new Error("Usage: oppi machines <add|test|list|remove>");
  }
}
