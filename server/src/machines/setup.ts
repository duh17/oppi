import { spawn } from "node:child_process";
import {
  acceptHostKey,
  deployDaemon,
  detectPlatform,
  forgetHostKey,
  HostKeyChangedError,
  scanHostKey,
} from "@earendil-works/pi-env";
import { capturePath, openProbe, runMachineChecks } from "./checks.js";
import { machineFailure } from "./errors.js";
import {
  decideHostKey,
  ownerKnownHostLines,
  ownKnownHostLines,
  type HostKeyDecision,
} from "./host-keys.js";
import {
  assertMachineName,
  authorizedKeyLine,
  defaultSshUser,
  parseSshSpec,
  type Machine,
  type MachineRegistry,
} from "./registry.js";

/** What `add` asks of its caller: the questions, and where its progress goes. */
export interface SetupIo {
  say(line: string): void;
  /** Print `line` verbatim: a key is not prose. */
  sayRaw(line: string): void;
  /** False when nobody can answer (no terminal) and the caller did not pre-approve. */
  confirm(question: string): Promise<boolean>;
}

export interface AddOptions {
  name: string;
  /** `[user@]host[:port]`, as typed. */
  ssh: string;
  /** Restrict the installed key to this source (`from="…"`). */
  from?: string;
  /** Install the key with the owner's own ssh without asking. */
  install: boolean;
  /** A host-key fingerprint (`SHA256:…`) to accept without asking. */
  hostKey?: string;
}

/** Run the owner's own ssh (their config, agent and prompts) with `script` for `sh -c`, `input` on stdin. */
function ownerSsh(spec: string, script: string, input: string): Promise<void> {
  const { user, host, port } = parseSshSpec(spec);
  const args = [
    ...(port === undefined ? [] : ["-p", String(port)]),
    "--",
    `${user ? `${user}@` : ""}${host}`,
    `sh -c '${script}'`,
  ];
  return new Promise((resolve, reject) => {
    const child = spawn("ssh", args, { stdio: ["pipe", "inherit", "inherit"] });
    child.once("error", reject);
    child.once("close", (code) =>
      code === 0 ? resolve() : reject(new Error(`ssh ${host} exited with code ${code}`)),
    );
    child.stdin.end(input);
  });
}

/** Append `line` to the target's authorized_keys unless it is there; creates `~/.ssh` owner-only. */
export function installAuthorizedKey(spec: string, line: string): Promise<void> {
  return ownerSsh(
    spec,
    'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; read -r line; grep -qxF -- "$line" ~/.ssh/authorized_keys || printf "%s\\n" "$line" >> ~/.ssh/authorized_keys',
    `${line}\n`,
  );
}

/** Remove every authorized_keys line that holds `keyBlob` (the key's base64), in place. */
export function removeAuthorizedKey(spec: string, keyBlob: string): Promise<void> {
  return ownerSsh(
    spec,
    'read -r blob; f="$HOME/.ssh/authorized_keys"; [ -f "$f" ] || exit 0; t="$f.oppi-tmp.$$"; grep -vF -- "$blob" "$f" > "$t"; [ $? -le 1 ] || { rm -f "$t"; exit 1; }; cat "$t" > "$f"; rm -f "$t"',
    `${keyBlob}\n`,
  );
}

/** The base64 field of a public key line. */
export function keyBlob(publicKey: string): string {
  const blob = publicKey.split(/\s+/)[1];
  if (!blob) throw new Error("The public key line has no key");
  return blob;
}

function fingerprintsOf(fingerprints: readonly string[]): string[] {
  return fingerprints.map((line) => line.split(/\s+/)[1] ?? line);
}

/** What the decision means for the host key `scan` found: trust it now, or why not. */
async function trustHostKey(
  registry: MachineRegistry,
  target: ReturnType<MachineRegistry["target"]>,
  scan: { lines: string[]; fingerprints: string[] },
  options: AddOptions,
  io: SetupIo,
): Promise<void> {
  const decision: HostKeyDecision = decideHostKey(
    scan.lines,
    ownKnownHostLines(registry.knownHostsPath, target.hostKeyAlias),
    await ownerKnownHostLines(target),
  );
  switch (decision) {
    case "already-trusted":
      return;
    case "changed":
      throw new HostKeyChangedError(
        `The host key of ${target.host} differs from the one Oppi trusts. Check the machine; if it was reinstalled, run \`oppi machines remove ${options.name} --force\` and add it again.`,
      );
    case "revoked":
      throw new Error(
        `The host key ${target.host} presents is marked @revoked in a known-hosts file. Do not trust this machine until you know why.`,
      );
    case "conflicts-with-owner-known-hosts":
      throw new Error(
        `The host key ${target.host} presents differs from the one in your ~/.ssh/known_hosts. Check the machine before trusting it.`,
      );
    case "confirmed-by-owner-known-hosts":
      io.say("Host key matches your ~/.ssh/known_hosts: trusted.");
      break;
    case "ask": {
      const shown = fingerprintsOf(scan.fingerprints);
      io.say(`${target.host} presents ${shown.join(", ")}.`);
      const pinned = options.hostKey !== undefined && shown.includes(options.hostKey);
      if (!pinned && !(await io.confirm("Trust this host key?")))
        throw new Error(
          `Host key not trusted. Compare ${shown.join(", ")} with the machine's, then re-run with --host-key <fingerprint>.`,
        );
    }
  }
  await acceptHostKey(target, scan.lines);
}

/**
 * `oppi machines add`: key, host key, login, helper, PATH and a connection test, saving only
 * when it passes. Returns the saved machine.
 */
export async function addMachine(
  registry: MachineRegistry,
  options: AddOptions,
  io: SetupIo,
): Promise<Machine> {
  assertMachineName(options.name);
  const spec = parseSshSpec(options.ssh);
  const publicKey = await registry.publicKey();
  const line = authorizedKeyLine(publicKey, options.from);
  io.say("This server's key for the machine (a full shell as that user, no forwarding):");
  io.sayRaw(line);
  if (options.install || (await io.confirm("Install it with your own ssh now?"))) {
    await installAuthorizedKey(options.ssh, line);
    io.say("Installed in ~/.ssh/authorized_keys.");
  } else if (!(await io.confirm("Add the line to the machine's ~/.ssh/authorized_keys. Done?"))) {
    throw new Error("The key is not installed; nothing was saved.");
  }

  const draft = {
    name: options.name,
    host: spec.host,
    user: spec.user ?? defaultSshUser(),
    ...(spec.port === undefined ? {} : { port: spec.port }),
  };
  const target = registry.target(draft);
  const scan = await scanHostKey(target);
  await trustHostKey(registry, target, scan, options, io);

  let remote;
  try {
    remote = await detectPlatform(target);
    io.say(`Logged in as ${draft.user}: ${remote.platform} ${remote.arch}.`);
    await deployDaemon(target, remote);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(machineFailure(options.name, message) ?? message, { cause: error });
  }
  io.say("Installed Oppi's helper on the machine.");

  const probe = openProbe(registry, { ...draft, path: "", home: remote.home });
  let path: string;
  try {
    path = await capturePath(probe.env);
  } finally {
    probe.close();
  }
  const machine: Machine = {
    ...draft,
    path,
    platform: remote.platform,
    arch: remote.arch,
    home: remote.home,
    addedAt: Date.now(),
  };
  const test = await runMachineChecks(registry, machine);
  for (const check of test.checks)
    io.say(`${check.ok ? "ok  " : "FAIL"} ${check.name}: ${check.detail}`);
  if (!test.ok) throw new Error("The connection test failed; the machine was not saved.");
  registry.save({ ...machine, test });
  return { ...machine, test };
}

/** Forget a machine's host key and its saved entry. */
export async function forgetMachine(registry: MachineRegistry, machine: Machine): Promise<void> {
  await forgetHostKey(registry.target(machine));
  registry.remove(machine.name);
}
