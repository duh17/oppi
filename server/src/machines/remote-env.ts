import type { Context } from "@earendil-works/chord/context";
import {
  RemoteError,
  RemoteExecutionEnv,
  sshConnection,
  type Connection,
} from "@earendil-works/pi-env";
import { createLogger } from "../logger.js";
import { MachineRegistry, type Machine } from "./registry.js";
import { Placements } from "./placements.js";
import { machineFailure } from "./errors.js";
import { fetchPlacement } from "./provision.js";

const log = createLogger({ base: { component: "machines" } });

/**
 * A conversation's tool execution on a machine: pi-env's remote environment over this
 * conversation's own SSH connection, so one dropped link ends only this worker's commands.
 *
 * Connection failures read as `machineFailure` says, for the model, spawn answers and the CLI.
 */
export class RemoteHandsEnv extends RemoteExecutionEnv {
  readonly machine: Machine;
  readonly root: string;
  readonly #closed: () => void;

  constructor(options: {
    connection: Connection;
    id: string;
    machine: Machine;
    root: string;
    closed: () => void;
  }) {
    super({
      connection: options.connection,
      id: options.id,
      cwd: options.root,
      shellEnv: { PATH: options.machine.path },
    });
    this.machine = options.machine;
    this.root = options.root;
    this.#closed = options.closed;
  }

  override async cleanup(context: Context): Promise<void> {
    await super.cleanup(context);
    this.connection.close();
    this.#closed();
  }
}

/** Rewrite connection errors of `connection` in place, and log its first connect and each loss. */
function explainFailures(connection: Connection, machine: string): void {
  const request = connection.request.bind(connection) as Connection["request"];
  const started = Date.now();
  let connected = false;
  connection.request = (async (...args: Parameters<Connection["request"]>) => {
    try {
      const reply = await request(...args);
      if (!connected) {
        connected = true;
        log.info("machine.connect", { machine, ms: Date.now() - started });
      }
      return reply;
    } catch (error) {
      // Only the link's own failures: a file or command error is the remote system's answer.
      if (!(error instanceof RemoteError)) throw error;
      if (error.fields.lost !== true && error.code !== "spawn_error") throw error;
      log.warn("machine.lost", { machine, code: error.code });
      const text = machineFailure(machine, error.message);
      if (text === undefined) throw error;
      throw new RemoteError({ ...error.fields, message: text });
    }
  }) as Connection["request"];
}

/**
 * The execution environment of one remote conversation. `root` is the worktree on the machine;
 * the placement (when there is one) records whether the machine has an active worker.
 */
export function createRemoteEnv(options: {
  dataDir: string;
  machine: string;
  root: string;
  conversationId: string;
  worktreeId?: string;
}): RemoteHandsEnv {
  const registry = new MachineRegistry(options.dataDir);
  const machine = registry.get(options.machine);
  if (!machine)
    throw new Error(
      `Machine ${options.machine} is not set up on this server. \`oppi machines list\` shows the machines.`,
    );
  const { connection } = sshConnection(registry.target(machine));
  explainFailures(connection, machine.name);
  const placements = new Placements(options.dataDir);
  // New commits may land while a worker runs, so the fetched copy is stale until it ends.
  const mark = (active: boolean): void => {
    if (options.worktreeId)
      placements.update(options.worktreeId, active ? { active, fetched: false } : { active });
  };
  mark(true);
  return new RemoteHandsEnv({
    connection,
    id: `pi-env:${machine.name}:${options.conversationId}`,
    machine,
    root: options.root,
    closed: () => {
      mark(false);
      // The run is over: bring its branch home (a failure retries at the next `list`).
      const placement = options.worktreeId ? placements.get(options.worktreeId) : undefined;
      if (placement) void fetchPlacement(options.dataDir, placement);
    },
  });
}
