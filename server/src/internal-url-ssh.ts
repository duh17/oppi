import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { SchemeReader } from "./internal-urls.js";

// `ssh://host/path` for the durable `read` tool: one file (UTF-8, up to 1 MiB) or one directory
// level on a host the server's own OpenSSH can reach. It uses the server account's `ssh` binary
// and `~/.ssh` setup only, never a client device's Terminal hosts or keys, and never prompts:
// BatchMode makes an unknown host key or a missing key fail with an error that says so.

const MAX_FILE_BYTES = 1024 * 1024;
const CONNECT_TIMEOUT_SECONDS = 10;
/** The whole call, connection included. */
const CALL_TIMEOUT_MS = 30_000;

/** `[user@]host[:port]`; a host never starts with `-`, so it cannot become an ssh option. */
const AUTHORITY =
  /^(?:([A-Za-z0-9._][A-Za-z0-9._-]*)@)?([A-Za-z0-9._][A-Za-z0-9._-]*|\[[0-9A-Fa-f:.]+\])(?::(\d{1,5}))?$/;

/** The remote end, run by the account's shell as `sh -c <SCRIPT> sh <mode> <path>`. */
const SCRIPT = [
  'if [ "$1" = home ]; then p="$HOME$2"; else p="$2"; fi',
  'if [ -d "$p" ]; then echo D; ls -1Ap -- "$p"',
  'elif [ -f "$p" ]; then n=$(wc -c < "$p" | tr -d " "); if [ "$n" -gt ' +
    MAX_FILE_BYTES +
    ' ]; then echo "L $n"; else echo F; cat -- "$p"; fi',
  "else echo M; fi",
].join("\n");

/** `value` as one word of a POSIX, bash, zsh, or fish command line. */
export function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

/** The `Host` aliases of the server account's ssh config, wildcard and negated patterns left out. */
export function sshConfigHosts(path = join(homedir(), ".ssh", "config")): string[] {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return [];
  }
  const hosts = new Set<string>();
  for (const line of text.split("\n")) {
    const match = /^\s*Host\s+(.+)$/i.exec(line);
    if (!match) continue;
    for (const alias of (match[1] ?? "").split(/\s+/))
      if (alias && !/[*?!]/.test(alias)) hosts.add(alias);
  }
  return [...hosts];
}

function decode(text: string, what: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    throw new Error(`ssh:// has an invalid percent-escape in the ${what}.`);
  }
}

/** The ssh arguments of a URL's `host`, and why a malformed one fails. */
function destination(authority: string): { args: string[]; host: string } {
  const match = AUTHORITY.exec(decode(authority, "host"));
  if (!match) throw new Error(`ssh:// needs a host: ssh://[user@]host[:port]/<absolute-path>.`);
  const [, user, bracketed = "", port] = match;
  const host = bracketed.startsWith("[") ? bracketed.slice(1, -1) : bracketed;
  if (port !== undefined && (Number(port) < 1 || Number(port) > 65535))
    throw new Error(`ssh:// port ${port} is not a valid port.`);
  return {
    host: `${user ? `${user}@` : ""}${host}`,
    args: [...(port ? ["-p", port] : []), "--", `${user ? `${user}@` : ""}${host}`],
  };
}

/** The remote path: the URL's, percent-decoded, and whether it is under the remote HOME. */
function remotePath(raw: string): { mode: "home" | "abs"; path: string } {
  // `?` and `#` end a URL's path; a name that holds one has to say so.
  if (/[?#]/.test(raw)) throw new Error("ssh:// paths need '?' written as %3F and '#' as %23.");
  if (raw === "" || raw === "/") return { mode: "abs", path: "/" };
  // Only a literal /~ opts into HOME; /%7E/ is a directory named ~.
  const home = raw === "/~" || raw.startsWith("/~/");
  if (!home && raw.startsWith("/~"))
    throw new Error("ssh:// supports /~ (the account's HOME), not /~user.");
  const decoded = decode(raw, "path");
  return home ? { mode: "home", path: decoded.slice(2) } : { mode: "abs", path: decoded };
}

/** Why an ssh run failed, in words that say what to do. */
function explain(host: string, stderr: string, timedOut: boolean): string {
  const text = stderr.trim();
  if (timedOut) return `ssh to ${host} timed out after ${CALL_TIMEOUT_MS / 1000} seconds.`;
  if (/host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED/i.test(text))
    return `ssh to ${host} refused its host key (unknown or changed). Trust it once by running \`ssh ${host}\` as the server's account; ssh:// never asks.`;
  if (/permission denied/i.test(text))
    return `ssh to ${host} needs authentication that a key or agent of the server's account cannot give (ssh:// never prompts for a password): ${text}`;
  if (/could not resolve hostname|name or service not known/i.test(text))
    return `ssh cannot resolve ${host}. Read ssh:// for the aliases in the server's ssh config.`;
  return `ssh to ${host} failed: ${text.slice(0, 500) || "no error output"}`;
}

function run(args: string[], signal: AbortSignal | undefined): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    execFile(
      "ssh",
      [
        "-n",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        `ConnectTimeout=${CONNECT_TIMEOUT_SECONDS}`,
        "-o",
        "ClearAllForwardings=yes",
        ...args,
      ],
      {
        encoding: "buffer",
        timeout: CALL_TIMEOUT_MS,
        maxBuffer: MAX_FILE_BYTES + 64 * 1024,
        ...(signal ? { signal } : {}),
      },
      (error, stdout, stderr) => {
        if (!error) return resolve(stdout);
        const failure = error as NodeJS.ErrnoException & { killed?: boolean };
        if (failure.code === "ENOENT")
          return reject(new Error("ssh:// needs the `ssh` program on the server's PATH."));
        reject(
          Object.assign(new Error(stderr.toString("utf8")), {
            timedOut: failure.killed === true,
            tooLarge: failure.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER",
          }),
        );
      },
    );
  });
}

/** Reads `ssh://`; the bare scheme lists the server account's ssh config aliases. */
export function createSshReader(): SchemeReader {
  return async (target, _api, context) => {
    if (target.id === "") {
      const hosts = sshConfigHosts();
      return hosts.length === 0
        ? "No Host aliases in the server account's ~/.ssh/config. Read ssh://[user@]host[:port]/<absolute-path> for any host its ssh can reach."
        : `SSH hosts from the server account's ~/.ssh/config (read ssh://<host>/<path>):\n${hosts.join("\n")}`;
    }
    const { args, host } = destination(target.id);
    const { mode, path } = remotePath(target.path);
    const remote = `sh -c ${shellQuote(SCRIPT)} sh ${mode} ${shellQuote(path)}`;
    let out: Buffer;
    try {
      out = await run([...args, remote], context.abortSignal);
    } catch (error) {
      const failure = error as Error & { timedOut?: boolean; tooLarge?: boolean };
      if (failure.tooLarge)
        throw new Error(
          `ssh://${target.id}${target.path} is larger than 1 MiB; read a part with bash.`,
          { cause: error },
        );
      if (context.abortSignal?.aborted) throw error;
      throw new Error(
        failure.message.startsWith("ssh:// ")
          ? failure.message
          : explain(host, failure.message, failure.timedOut === true),
        { cause: error },
      );
    }
    const newline = out.indexOf(10);
    const marker = out.subarray(0, newline < 0 ? out.length : newline).toString("utf8");
    const body = newline < 0 ? Buffer.alloc(0) : out.subarray(newline + 1);
    const where = `ssh://${target.id}${target.path}`;
    if (marker === "M") throw new Error(`${where} is not a file or directory on ${host}.`);
    if (marker.startsWith("L"))
      throw new Error(
        `${where} is ${marker.slice(2)} bytes, over the 1 MiB limit; read a part with bash.`,
      );
    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(body);
    } catch {
      throw new Error(`${where} is not UTF-8 text.`);
    }
    return marker === "D" ? `${where} (directory):\n${text.replace(/\n$/, "")}` : text;
  };
}
