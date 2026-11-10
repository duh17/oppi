import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sshArguments } from "@earendil-works/pi-env";
import { afterEach, describe, expect, it } from "vitest";
import { gitRemoteUrl, gitSshCommand } from "../src/machines/git-ssh.js";
import { decideHostKey } from "../src/machines/host-keys.js";
import { fetchDecision } from "../src/machines/provision.js";
import {
  assertMachineName,
  authorizedKeyLine,
  MachineRegistry,
  parseMachines,
  parseSshSpec,
} from "../src/machines/registry.js";
import { machineFailure } from "../src/machines/errors.js";

const KEY_A = "AAAAC3NzaC1lZDI1NTE5AAAAIAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const KEY_B = "AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const scanned = [`oppi-build-mac ssh-ed25519 ${KEY_A}`];

describe("host key trust", () => {
  it("trusts a key the owner's known-hosts already lists, without asking", () => {
    expect(
      decideHostKey(
        scanned,
        [],
        [`# Host build-mac found: line 3`, `build-mac ssh-ed25519 ${KEY_A}`],
      ),
    ).toBe("confirmed-by-owner-known-hosts");
    // Hashed entries carry the same key fields.
    expect(decideHostKey(scanned, [], [`|1|c2FsdA==|aGFzaA== ssh-ed25519 ${KEY_A}`])).toBe(
      "confirmed-by-owner-known-hosts",
    );
  });

  it("refuses a key that differs from the owner's, and from the one Oppi pinned", () => {
    expect(decideHostKey(scanned, [], [`build-mac ssh-ed25519 ${KEY_B}`])).toBe(
      "conflicts-with-owner-known-hosts",
    );
    expect(
      decideHostKey(
        scanned,
        [`oppi-build-mac ssh-ed25519 ${KEY_B}`],
        [`build-mac ssh-ed25519 ${KEY_A}`],
      ),
    ).toBe("changed");
  });

  it("never trusts a key a known-hosts file revokes, or a CA line's key", () => {
    expect(decideHostKey(scanned, [], [`@revoked build-mac ssh-ed25519 ${KEY_A}`])).toBe("revoked");
    expect(decideHostKey(scanned, [], [`@cert-authority * ssh-ed25519 ${KEY_A}`])).toBe("ask");
  });

  it("asks when nothing vouches for the key, and keeps a pinned key trusted", () => {
    expect(decideHostKey(scanned, [], [])).toBe("ask");
    // A key of another type proves nothing about this one.
    expect(decideHostKey(scanned, [], [`build-mac ssh-rsa ${KEY_B}`])).toBe("ask");
    expect(decideHostKey(scanned, [`oppi-build-mac ssh-ed25519 ${KEY_A}`], [])).toBe(
      "already-trusted",
    );
  });
});

describe("git over a machine's ssh options", () => {
  const target = {
    host: "build-mac.local",
    user: "alex",
    port: 2222,
    identityFile: "/data/it's/ssh/id_ed25519",
    knownHostsFile: "/data/ssh/known_hosts",
    hostKeyAlias: "oppi-build-mac",
    configFile: "/data/ssh/config",
  };

  /** What the shell makes of the command: the argv `ssh` would receive. */
  const argvOf = (command: string): string[] =>
    JSON.parse(
      execFileSync(
        "sh",
        [
          "-c",
          `set -- ${command}; node -e 'console.log(JSON.stringify(process.argv.slice(1)))' "$@"`,
        ],
        { encoding: "utf8" },
      ),
    ) as string[];

  it("is the connection's ssh arguments without the trailing `-- host`", () => {
    const argv = argvOf(gitSshCommand(target));
    expect(argv[0]).toBe("ssh");
    expect(argv.slice(1)).toEqual(sshArguments(target).slice(0, -2));
    expect(argv).not.toContain("--");
    expect(argv).not.toContain(target.host);
    // The same key, ssh config and host-key alias as pi-env's own connection.
    expect(argv.join(" ")).toContain("HostKeyAlias=oppi-build-mac");
    expect(argv).toContain("-F");
    expect(argv.join(" ")).toContain(`IdentityFile="${target.identityFile}"`);
  });

  it("builds the mirror's URL with the user and port", () => {
    expect(gitRemoteUrl(target, "/Users/alex/.oppi/pool/ws-1.git")).toBe(
      "ssh://alex@build-mac.local:2222/Users/alex/.oppi/pool/ws-1.git",
    );
  });
});

describe("bringing a worker's branch home", () => {
  const base = "a".repeat(40);

  it("has nothing to fetch for a worker that made no commits, and fetches one that did", () => {
    expect(fetchDecision(`${base}\trefs/heads/subagent/x\n`, base)).toBe("nothing-to-fetch");
    expect(fetchDecision(`${"b".repeat(40)}\trefs/heads/subagent/x\n`, base)).toBe("fetch");
  });

  it("does not take a branch the mirror lacks for one with nothing to fetch", () => {
    expect(() => fetchDecision("", base)).toThrow(/no such branch/);
  });
});

describe("machine configuration", () => {
  const dirs: string[] = [];
  afterEach(() => {
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  it("reads [user@]host[:port] and refuses anything else", () => {
    expect(parseSshSpec("alex@build-mac.local:2222")).toEqual({
      user: "alex",
      host: "build-mac.local",
      port: 2222,
    });
    expect(parseSshSpec("build-mac")).toEqual({ host: "build-mac" });
    expect(() => parseSshSpec("-oProxyCommand=x")).toThrow();
    expect(() => parseSshSpec("host:99999")).toThrow(/port/);
    expect(() => parseSshSpec("a@b@c")).toThrow();
  });

  it("keeps machine names plain enough for file names and key aliases", () => {
    expect(() => assertMachineName("build-mac")).not.toThrow();
    for (const bad of ["", "Build", "-x", "a b", "../x", "a".repeat(40)])
      expect(() => assertMachineName(bad), bad).toThrow();
  });

  it("refuses a malformed machines.json instead of hiding a machine", () => {
    const machine = {
      name: "build-mac",
      host: "h",
      user: "u",
      path: "/bin",
      platform: "darwin",
      arch: "arm64",
      home: "/Users/u",
      addedAt: 1,
    };
    expect(parseMachines(JSON.stringify({ machines: [machine] }))).toHaveLength(1);
    expect(() => parseMachines(JSON.stringify({ machines: [machine, machine] }))).toThrow(/twice/);
    expect(() =>
      parseMachines(JSON.stringify({ machines: [{ ...machine, port: "22" }] })),
    ).toThrow();
    expect(() =>
      parseMachines(JSON.stringify({ machines: [{ ...machine, home: undefined }] })),
    ).toThrow(/missing/);
    expect(() => parseMachines("{}")).toThrow();
  });

  it("round-trips machines and restricts the installed key", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-machines-"));
    dirs.push(dir);
    const registry = new MachineRegistry(dir);
    expect(registry.list()).toEqual([]);
    const machine = {
      name: "build-mac",
      host: "h",
      user: "u",
      path: "/bin",
      platform: "darwin",
      arch: "arm64",
      home: "/Users/u",
      addedAt: 1,
    };
    registry.save(machine);
    expect(registry.get("build-mac")).toEqual(machine);
    expect(registry.target(machine)).toMatchObject({
      hostKeyAlias: "oppi-build-mac",
      loginShell: false,
      configFile: registry.configPath,
    });
    registry.remove("build-mac");
    expect(registry.list()).toEqual([]);
    expect(authorizedKeyLine("ssh-ed25519 AAAA oppi@host")).toBe(
      "restrict ssh-ed25519 AAAA oppi@host",
    );
    expect(authorizedKeyLine("ssh-ed25519 AAAA oppi@host", "100.64.0.1")).toBe(
      'restrict,from="100.64.0.1" ssh-ed25519 AAAA oppi@host',
    );
    expect(() => authorizedKeyLine("ssh-ed25519 AAAA", 'x" command="y')).toThrow();
  });
});

describe("what a machine failure says", () => {
  it("names the cause and the fix without a path, command or key", () => {
    expect(machineFailure("build-mac", "pi-env connection timed out")).toBe(
      "build-mac is offline or unreachable; its files are kept. `oppi machines test build-mac`.",
    );
    expect(
      machineFailure("build-mac", "The host key of x changed; remove the old key to continue"),
    ).toContain("host key changed or is not trusted");
    expect(
      machineFailure("build-mac", "ssh x failed with exit code 255: Permission denied (publickey)"),
    ).toContain("refused Oppi's key");
    expect(
      machineFailure("build-mac", "ssh x has no sha256sum, shasum or openssl to verify pi-env"),
    ).toMatch(/^Could not install Oppi's helper on build-mac: /);
    expect(machineFailure("build-mac", "something else")).toBeUndefined();
  });
});
