import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import type { SshTarget } from "@earendil-works/pi-env";

const execFileAsync = promisify(execFile);

/** `<type> <base64>` of a known-hosts line (`[markers] hosts type key [comment]`). */
function keysOf(lines: readonly string[]): Set<string> {
  const keys = new Set<string>();
  for (const line of lines) {
    const fields = line.trim().split(/\s+/);
    if (fields.length < 3 || fields[0]?.startsWith("#")) continue;
    // `@cert-authority` and `@revoked` lines carry a marker before the host field.
    const offset = fields[0]?.startsWith("@") ? 1 : 0;
    const [type, key] = [fields[offset + 1], fields[offset + 2]];
    if (type && key && fields[0] !== "@revoked") keys.add(`${type} ${key}`);
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
