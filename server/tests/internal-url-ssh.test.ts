import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { ToolExecutionApi } from "@earendil-works/pi-durable";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { internalUrls } from "../src/durable-internal-urls.js";
import { shellQuote } from "../src/internal-url-ssh.js";
import { makeTempDir } from "./harness/temp-dir.js";

// A fake `ssh` on PATH that behaves like the real one where it matters: it takes the options and
// the destination, then runs the joined remainder through a shell, as sshd does for the account.
// Hosts named `badkey`, `noauth`, and `slowdns` fail the way ssh does. It logs its argv.
const FAKE_SSH = `#!/bin/sh
echo "$*" >> "$FAKE_SSH_LOG"
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-p) shift 2 ;;
    -n|-T) shift ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
host=$1; shift
case "$host" in
  badkey) echo "Host key verification failed." >&2; exit 255 ;;
  noauth) echo "user@noauth: Permission denied (publickey,password)." >&2; exit 255 ;;
  banner) echo "Welcome to the box" ;;
  nohost) echo "ssh: Could not resolve hostname nohost: Name or service not known" >&2; exit 255 ;;
esac
exec sh -c "$*"
`;

let home: string;
let log: string;
let previous: { PATH?: string; HOME?: string; FAKE_SSH_LOG?: string };

beforeEach(() => {
  home = makeTempDir("oppi-ssh-home-");
  const bin = join(home, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "ssh"), FAKE_SSH);
  chmodSync(join(bin, "ssh"), 0o755);
  log = join(home, "ssh.log");
  previous = {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    FAKE_SSH_LOG: process.env.FAKE_SSH_LOG,
  };
  process.env.PATH = `${bin}:${process.env.PATH}`;
  process.env.HOME = home;
  process.env.FAKE_SSH_LOG = log;
});
afterEach(() => {
  for (const [key, value] of Object.entries(previous)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

const read = async (path: string) => {
  const result = await internalUrls.read({ path }, {} as ToolExecutionApi, context);
  return result?.output?.map((part) => (part.type === "text" ? part.text : "")).join("");
};
const enc = (path: string) => path.split("/").map(encodeURIComponent).join("/");

describe("ssh:// through the server's ssh", () => {
  it("lists the account's ssh config aliases, without wildcards", async () => {
    mkdirSync(join(home, ".ssh"));
    writeFileSync(
      join(home, ".ssh", "config"),
      "Host *\n  User x\nHost box staging\n  HostName 10.0.0.2\nHost !blocked dev-?\nhost Lower\nHost=eq # trailing comment\n# Host commented\nHostname 10.9.9.9\nInclude conf.d/*\n",
    );
    const listing = await read("ssh://");
    expect(listing).toContain("box\nstaging\nLower\neq");
    expect(listing).not.toMatch(/commented|trailing|10\.9|Include/);
    expect(listing).not.toMatch(/\*|blocked|dev-\?/);
  });

  it("never prompts, and reads files whose names hold spaces, quotes, and shell syntax", async () => {
    const dir = join(home, "it's a $(touch pwned) dir");
    mkdirSync(dir);
    writeFileSync(join(dir, 'we"ird; `x` name.txt'), "héllo\nworld\n");
    expect(await read(`ssh://box${enc(join(dir, 'we"ird; `x` name.txt'))}`)).toBe("héllo\nworld\n");
    // The call stayed one command: the substitution in the directory name never ran.
    await expect(read(`ssh://box${enc(join(dir, "pwned"))}`)).rejects.toThrow(
      "not a file or directory",
    );
    const argv = readFileSync(log, "utf8");
    expect(argv).toContain("-o BatchMode=yes");
    expect(argv).toContain("-o ConnectTimeout=");
    expect(argv).toContain("-- box ");
  });

  it("lists a directory one level, marking subdirectories", async () => {
    mkdirSync(join(home, "d", "sub"), { recursive: true });
    writeFileSync(join(home, "d", "a.txt"), "x");
    expect(await read(`ssh://box${enc(join(home, "d"))}`)).toMatch(
      /\(directory\):\na\.txt\nsub\/$/,
    );
  });

  it("resolves /~ to the remote HOME and decodes %3F, %23 and %3A", async () => {
    writeFileSync(join(home, "q?#:.txt"), "odd name");
    mkdirSync(join(home, "h"));
    writeFileSync(join(home, "h", "n.txt"), "in home");
    expect(await read("ssh://box/~/h/n.txt")).toBe("in home");
    expect(await read("ssh://box/~/q%3F%23%3A.txt")).toBe("odd name");
    expect(await read("ssh://box/~")).toContain("(directory)");
    // /%7E/ is an absolute directory named ~, not HOME.
    await expect(read("ssh://box/%7E/h/n.txt")).rejects.toThrow("not a file or directory");
    await expect(read("ssh://box/~other/x")).rejects.toThrow("/~user");
    await expect(read("ssh://box/tmp/a?b")).rejects.toThrow("%3F");
    await expect(read("ssh://box/tmp/%ZZ")).rejects.toThrow("percent-escape");
  });

  it("refuses files over 1 MiB and files that are not UTF-8", async () => {
    writeFileSync(join(home, "big.txt"), Buffer.alloc(1024 * 1024 + 1, 97));
    writeFileSync(join(home, "ok.txt"), Buffer.alloc(1024 * 1024, 97));
    writeFileSync(join(home, "bin.dat"), Buffer.from([0xff, 0xfe, 0x00, 0x80]));
    await expect(read("ssh://box/~/big.txt")).rejects.toThrow("over the 1 MiB limit");
    expect(await read("ssh://box/~/ok.txt")).toHaveLength(1024 * 1024);
    await expect(read("ssh://box/~/bin.dat")).rejects.toThrow("not UTF-8");
  });

  it("explains host key, authentication, and name failures, and rejects option-shaped hosts", async () => {
    await expect(read("ssh://badkey/etc/hosts")).rejects.toThrow(/host key.*Trust it once/);
    await expect(read("ssh://noauth/etc/hosts")).rejects.toThrow(/never prompts for a password/);
    await expect(read("ssh://nohost/etc/hosts")).rejects.toThrow(/cannot resolve nohost/);
    await expect(read("ssh://-oProxyCommand=id/etc/hosts")).rejects.toThrow("needs a host");
    await expect(read("ssh://box:99999/etc/hosts")).rejects.toThrow("not a valid port");
  });

  it("fails when the login shell prints before the read, instead of returning it as content", async () => {
    writeFileSync(join(home, "f.txt"), "real");
    await expect(read("ssh://banner/~/f.txt")).rejects.toThrow(
      /printed output before the read.*startup files/,
    );
  });

  it("passes user and port as ssh arguments", async () => {
    await read("ssh://alice@box:2222/~").catch(() => undefined);
    expect(readFileSync(log, "utf8")).toContain("-p 2222 -- alice@box ");
  });

  it("quotes any string as one shell word", () => {
    expect(shellQuote("a'b")).toBe(`'a'\\''b'`);
  });
});
