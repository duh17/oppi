import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import type { SshTarget } from "@earendil-works/pi-env";

const execFileAsync = promisify(execFile);

/**
 * `<type> <base64>` of the plain host-key lines of a known-hosts file (`hosts type key [comment]`),
 * or, with `marker`, of the lines carrying that marker. A `@cert-authority` line holds a CA's key,
 * never a host's, so it vouches for nothing.
 */
function keysOf(lines: readonly string[], marker?: "@revoked"): Set<string> {
  const keys = new Set<string>();
  for (const line of lines) {
    const fields = line.trim().split(/\s+/);
    if (fields.length < 3 || fields[0]?.startsWith("#")) continue;
    const marked = fields[0]?.startsWith("@") ? fields[0] : undefined;
    if (marked !== marker) continue;
    const offset = marked ? 1 : 0;
    const [type, key] = [fields[offset + 1], fields[offset + 2]];
    if (type && key) keys.add(`${type} ${key}`);
  }
  return keys;
}

export type HostKeyDecision =
  /** Oppi already trusts exactly these keys. */
  | "already-trusted"
  /** The owner's own known-hosts lists the same keys: accept without asking. */
  | "confirmed-by-owner-known-hosts"
  /** Oppi's own known-hosts holds another key of the same type for this machine. */
  | "changed"
  /** The owner's known-hosts holds another key of the same type for this host. */
  | "conflicts-with-owner-known-hosts"
  /** A known-hosts file marks the presented key `@revoked`: never trust it. */
  | "revoked"
  /** Nothing to compare with: show the fingerprints and ask. */
  | "ask";

/**
 * What to do with the host key a machine presented. `ours` are lines of Oppi's known-hosts for
 * the machine's alias, `owners` the lines the owner's `ssh-keygen -F <host>` found. A key never
 * replaces a different key of the same type automatically.
 */
export function decideHostKey(
  scanned: readonly string[],
  ours: readonly string[],
  owners: readonly string[],
): HostKeyDecision {
  const presented = keysOf(scanned);
  const revoked = keysOf([...ours, ...owners], "@revoked");
  if ([...presented].some((key) => revoked.has(key))) return "revoked";
  const types = new Set([...presented].map((key) => key.split(" ")[0]));
  const conflicts = (known: Set<string>): boolean =>
    [...known].some((key) => types.has(key.split(" ")[0]) && !presented.has(key));
  const trusted = keysOf(ours);
  if (trusted.size > 0) {
    if ([...presented].every((key) => trusted.has(key))) return "already-trusted";
    if (conflicts(trusted)) return "changed";
  }
  const owned = keysOf(owners);
  if (presented.size > 0 && [...presented].every((key) => owned.has(key)))
    return "confirmed-by-owner-known-hosts";
  if (conflicts(owned)) return "conflicts-with-owner-known-hosts";
  return "ask";
}

/** The lines of the owner's `~/.ssh/known_hosts` that cover `target`'s host (and port). */
export async function ownerKnownHostLines(
  target: Pick<SshTarget, "host" | "port">,
): Promise<string[]> {
  const file = join(homedir(), ".ssh", "known_hosts");
  if (!existsSync(file)) return [];
  const name =
    target.port === undefined || target.port === 22
      ? target.host
      : `[${target.host}]:${target.port}`;
  try {
    const { stdout } = await execFileAsync("ssh-keygen", ["-F", name, "-f", file]);
    return stdout.split("\n");
  } catch {
    // `ssh-keygen -F` exits 1 when the host is not listed.
    return [];
  }
}

/** The lines of Oppi's known-hosts for `alias`. */
export function ownKnownHostLines(knownHostsFile: string, alias: string): string[] {
  if (!existsSync(knownHostsFile)) return [];
  return readFileSync(knownHostsFile, "utf8")
    .split("\n")
    .filter((line) => line.split(/\s+/)[0] === alias);
}
