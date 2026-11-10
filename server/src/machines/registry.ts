import { execFile } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { hostname, userInfo } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import type { SshConnectOptions } from "@earendil-works/pi-env";
import { isRecord } from "../json-shape.js";
import { writeFileAtomic } from "../storage/atomic-file.js";

const execFileAsync = promisify(execFile);

/** Machine names key files, host-key aliases and remote paths, so they stay plain. */
const MACHINE_NAME = /^[a-z0-9][a-z0-9-]{0,30}$/;

export interface MachineCheck {
  name: string;
  ok: boolean;
  detail: string;
}

/** The outcome of the last `oppi machines test`: what `list` and `doctor` show without a network. */
export interface MachineTest {
  at: number;
  /** Every check passed. */
  ok: boolean;
  checks: MachineCheck[];
}

/** A target Oppi can run tool execution on. Saved in `machines.json` in the server data directory. */
export interface Machine {
  name: string;
  host: string;
  user: string;
  port?: number;
  /** The target login shell's PATH, captured when the machine was added. */
  path: string;
  platform: string;
  arch: string;
  /** The target's home directory. The Oppi-owned mirror lives under `<home>/.oppi/pool`. */
  home: string;
  addedAt: number;
  test?: MachineTest;
}

export function assertMachineName(name: string): void {
  if (!MACHINE_NAME.test(name))
    throw new Error(
      `Machine name "${name}" must be lowercase letters, digits and dashes, starting with a letter or digit (at most 31 characters).`,
    );
}

/** `[user@]host[:port]`. IPv6 literals are not supported; use a name. */
export function parseSshSpec(spec: string): { user?: string; host: string; port?: number } {
  const match = /^(?:([^@\s]+)@)?([^@\s:]+)(?::(\d+))?$/.exec(spec.trim());
  if (!match) throw new Error(`Expected [user@]host[:port], got "${spec}".`);
  const [, user, host, port] = match;
  const portNumber = port === undefined ? undefined : Number(port);
  if (portNumber !== undefined && (portNumber < 1 || portNumber > 65535))
    throw new Error(`Invalid port in "${spec}".`);
  if (host?.startsWith("-")) throw new Error(`Invalid host in "${spec}".`);
  return {
    ...(user ? { user } : {}),
    host: host as string,
    ...(portNumber === undefined ? {} : { port: portNumber }),
  };
}

function parseCheck(raw: unknown): MachineCheck {
  if (
    !isRecord(raw) ||
    typeof raw.name !== "string" ||
    typeof raw.ok !== "boolean" ||
    typeof raw.detail !== "string"
  )
    throw new Error("a test check is malformed");
  return { name: raw.name, ok: raw.ok, detail: raw.detail };
}

function parseMachine(raw: unknown): Machine {
  if (!isRecord(raw)) throw new Error("a machine entry is not an object");
  const { name, host, user, port, path, platform, arch, home, addedAt, test } = raw;
  if (typeof name !== "string") throw new Error("a machine has no name");
  assertMachineName(name);
  if (
    typeof host !== "string" ||
    typeof user !== "string" ||
    typeof path !== "string" ||
    typeof platform !== "string" ||
    typeof arch !== "string" ||
    typeof home !== "string" ||
    typeof addedAt !== "number"
  )
    throw new Error(`machine ${name} is missing host, user, path, platform, arch, home or addedAt`);
  if (port !== undefined && (!Number.isInteger(port) || (port as number) < 1))
    throw new Error(`machine ${name} has an invalid port`);
  let parsedTest: MachineTest | undefined;
  if (test !== undefined) {
    if (!isRecord(test) || typeof test.at !== "number" || typeof test.ok !== "boolean")
      throw new Error(`machine ${name} has a malformed test result`);
    if (!Array.isArray(test.checks)) throw new Error(`machine ${name} has a malformed test result`);
    parsedTest = { at: test.at, ok: test.ok, checks: test.checks.map(parseCheck) };
  }
  return {
    name,
    host,
    user,
    ...(port === undefined ? {} : { port: port as number }),
    path,
    platform,
    arch,
    home,
    addedAt,
    ...(parsedTest ? { test: parsedTest } : {}),
  };
}

/** The saved machines, validated; a malformed file throws rather than hiding a machine. */
export function parseMachines(text: string): Machine[] {
  const raw: unknown = JSON.parse(text);
  if (!isRecord(raw) || !Array.isArray(raw.machines))
    throw new Error('machines.json must be an object with a "machines" array');
  const machines = raw.machines.map(parseMachine);
  const names = new Set<string>();
  for (const machine of machines) {
    if (names.has(machine.name)) throw new Error(`machine ${machine.name} is listed twice`);
    names.add(machine.name);
  }
  return machines;
}

/**
 * The machines of one server data directory and the SSH state that reaches them: machines.json,
 * and `ssh/` with this server's own key, its own known-hosts, and an empty ssh config (passed as
 * `-F`, so the owner's `~/.ssh/config` cannot add keys, proxies or commands).
 */
export class MachineRegistry {
  readonly sshDir: string;
  readonly keyPath: string;
  readonly knownHostsPath: string;
  readonly configPath: string;
  private readonly file: string;

  constructor(readonly dataDir: string) {
    this.file = join(dataDir, "machines.json");
    this.sshDir = join(dataDir, "ssh");
    this.keyPath = join(this.sshDir, "id_ed25519");
    this.knownHostsPath = join(this.sshDir, "known_hosts");
    this.configPath = join(this.sshDir, "config");
  }

  list(): Machine[] {
    if (!existsSync(this.file)) return [];
    return parseMachines(readFileSync(this.file, "utf8"));
  }

  get(name: string): Machine | undefined {
    return this.list().find((machine) => machine.name === name);
  }

  /** Add or replace a machine by name. */
  save(machine: Machine): void {
    const others = this.list().filter((other) => other.name !== machine.name);
    this.write([...others, machine]);
  }

  remove(name: string): void {
    this.write(this.list().filter((machine) => machine.name !== name));
  }

  private write(machines: Machine[]): void {
    mkdirSync(this.dataDir, { recursive: true, mode: 0o700 });
    writeFileAtomic(this.file, `${JSON.stringify({ machines }, null, 2)}\n`, { durable: true });
  }

  /** How pi-env reaches `machine`: this server's key, known-hosts and ssh config only. */
  target(machine: Pick<Machine, "name" | "host" | "user" | "port">): SshConnectOptions {
    return {
      host: machine.host,
      user: machine.user,
      ...(machine.port === undefined ? {} : { port: machine.port }),
      identityFile: this.keyPath,
      knownHostsFile: this.knownHostsPath,
      hostKeyAlias: `oppi-${machine.name}`,
      configFile: this.configPath,
      loginShell: false,
    };
  }

  /** The `ssh/` directory with its empty config, owner-only. */
  ensureSshDir(): void {
    mkdirSync(this.sshDir, { recursive: true, mode: 0o700 });
    chmodSync(this.sshDir, 0o700);
    if (!existsSync(this.configPath)) writeFileSync(this.configPath, "", { mode: 0o600 });
    if (!existsSync(this.knownHostsPath)) writeFileSync(this.knownHostsPath, "", { mode: 0o600 });
  }

  /** This server's public key line (`ssh-ed25519 AAAA… oppi@<host>`), generating the key once. */
  async publicKey(): Promise<string> {
    this.ensureSshDir();
    if (!existsSync(this.keyPath))
      await execFileAsync("ssh-keygen", [
        "-q",
        "-t",
        "ed25519",
        "-N",
        "",
        "-C",
        `oppi@${hostname().split(".")[0] ?? "server"}`,
        "-f",
        this.keyPath,
      ]);
    return readFileSync(`${this.keyPath}.pub`, "utf8").trim();
  }
}

/** The line to install in the target's `authorized_keys`: no forwarding, optionally one source. */
export function authorizedKeyLine(publicKey: string, from?: string): string {
  if (from !== undefined && !/^[A-Za-z0-9.:*?,!/-]+$/.test(from))
    throw new Error(`Invalid --from pattern "${from}".`);
  return `${from === undefined ? "restrict" : `restrict,from="${from}"`} ${publicKey}`;
}

/** The user `add` logs in as when `--ssh` names none (the owner's ssh config is not read). */
export function defaultSshUser(): string {
  return userInfo().username;
}
