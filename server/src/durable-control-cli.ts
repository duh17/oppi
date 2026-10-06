import { createHash } from "node:crypto";
import type { ConversationId } from "@earendil-works/pi-durable";
import type { JsonValue } from "@earendil-works/chord";
import type {
  ControlJson,
  ControlWrite,
  DurableControlHost,
} from "../extensions/durable/control/durable.js";
import { parseCliArgs } from "./cli/args.js";
import { createCliConnectionConfig } from "./cli/connection-config.js";
import {
  localApiRequest,
  withLocalApiInterceptor,
  type LocalApiInterceptedRequest,
} from "./cli/local-api-client.js";
import { runCli } from "./cli/runner.js";
import { safeErrorMessage } from "./log-utils.js";

/**
 * The only argv this host refuses before `runCli`. Argv classification is NOT the safety
 * boundary (the confirm gate on every non-GET request is); these are the ways a command reaches
 * the host without an HTTP request or the envelope, or that would hurt the server it runs in:
 * - flags that read a file of this host (`--definition PATH`, `--instructions-file`, dictionary
 *   `--file`) or stdin (`@-`, `--phrases`): the server's own files and stdin are not the owner's
 * - `--config-file`, and `config set`, which edits the config file directly with no request to gate
 * - `control`: its `send` would prompt the control conversation from inside its own turn
 * - `status`: it shells out synchronously (`execFileSync`), which would stall the server's event loop
 * - `--idempotency-key=…`, `--request-id=…`, `--turn-id=…`: the CLI does not split on `=`, so that
 *   form is an unknown flag it ignores (`session` commands refuse it). The host cannot tell it from
 *   a script's own replay key without guessing where the verb is, so it is refused outright; the
 *   space-separated form is the one the host replaces with its own key.
 * (`version` never reaches `runCli`: the CLI entry point handles it, so a script gets the runner's
 * "Unknown command" envelope.)
 */
const HOST_INPUT_FLAGS = new Set([
  "definition",
  "instructions-file",
  "file",
  "phrases",
  "config-file",
]);

const REPLAY_KEY_EQUALS_FORMS = ["--idempotency-key=", "--request-id=", "--turn-id="];

const DENIED_COMMANDS: ReadonlyMap<string, string> = new Map([
  [
    "control",
    "control is not available to the control agent: it would send the control conversation a message from inside its own turn.",
  ],
  [
    "status",
    "status runs blocking system commands on the server's event loop and is not available to the control agent.",
  ],
]);

export function refuseControlArgv(argv: readonly string[]): string | undefined {
  const denied = DENIED_COMMANDS.get(argv[0] ?? "");
  if (denied !== undefined) return denied;
  if (argv.includes("@-")) return "Reading stdin (@-) is not available to the control agent.";
  const separator = argv.indexOf("--");
  const equalsForm = argv
    .slice(0, separator === -1 ? argv.length : separator)
    .find((arg) => REPLAY_KEY_EQUALS_FORMS.some((prefix) => arg.startsWith(prefix)));
  if (equalsForm !== undefined)
    return `${equalsForm.slice(0, equalsForm.indexOf("="))}=value is not available to the control agent. Pass the value as a separate word (--flag value), or leave the key out: the host sets it.`;
  let parsed;
  try {
    parsed = parseCliArgs([...argv]);
  } catch {
    // The runner parses the same way and answers with the same error.
    return undefined;
  }
  const hostFlag = Object.keys(parsed.flags).find((flag) => HOST_INPUT_FLAGS.has(flag));
  if (hostFlag !== undefined)
    return `--${hostFlag} reads this host's files or stdin and is not available to the control agent. Pass the content inline (for example --definition-json).`;
  if (parsed.command === "config" && parsed.positional[0] === "set")
    return "config set edits the server's config file directly and is not available to the control agent.";
  return undefined;
}

/**
 * The flag that makes a write replay-safe, per command: the server keeps one entity (or one run,
 * or one turn) per value. Every other write has no such key.
 */
const REPLAY_KEY_FLAG: ReadonlyMap<string, string> = new Map([
  ["agent create", "idempotency-key"],
  ["session create", "idempotency-key"],
  ["schedule create", "idempotency-key"],
  ["schedule run", "request-id"],
  ["session send", "turn-id"],
]);

/**
 * `argv` without `--flag [value]`, read the way `parseCliArgs` reads it. The `--flag=value`
 * form never gets here: `refuseControlArgv` refuses it.
 */
function withoutFlag(argv: readonly string[], flag: string): string[] {
  const separator = argv.indexOf("--");
  const end = separator === -1 ? argv.length : separator;
  const kept: string[] = argv.slice(0, 1);
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i] as string;
    if (i < end && arg === `--${flag}`) {
      const next = argv[i + 1];
      if (i + 1 < end && next !== undefined && !next.startsWith("--")) i += 1;
      continue;
    }
    kept.push(arg);
  }
  return kept;
}

/**
 * Make the write of a keyed command replay-safe: `--flag <call key>:<hash of the rest of argv>`
 * is the ONLY key it carries, and a key the script passed is dropped. The call key (task id and
 * call index) is the same when a crashed script reruns; the hash makes it a different key when
 * the call at that index is not the same call, so a rerun whose calls came out in another order
 * never hands one write another write's key. Other commands are returned unchanged.
 */
export function withReplayKey(argv: readonly string[], key: string): string[] {
  let parsed;
  try {
    parsed = parseCliArgs([...argv]);
  } catch {
    return [...argv];
  }
  // `session start` is `session create`.
  const sub =
    parsed.command === "session" && parsed.positional[0] === "start"
      ? "create"
      : parsed.positional[0];
  const flag = REPLAY_KEY_FLAG.get(`${parsed.command} ${sub ?? ""}`);
  if (flag === undefined) return [...argv];
  const rest = withoutFlag(argv, flag);
  const hash = createHash("sha256").update(JSON.stringify(rest)).digest("hex").slice(0, 12);
  // Before a `--`, so the pair stays flags.
  const separator = rest.indexOf("--");
  const at = separator === -1 ? rest.length : separator;
  return [...rest.slice(0, at), `--${flag}`, `${key}:${hash}`, ...rest.slice(at)];
}

function failure(code: string, message: string): ControlJson {
  return { ok: false, error: { code, message } };
}

export interface DurableControlCliDeps {
  dataDir: string;
  /** The Oppi Session a conversation is bound to, so child sessions are attributed to it. */
  sessionIdOf(conversationId: ConversationId): string | undefined;
}

/** Runs the `oppi` CLI inside this server process for the control conversation's tools. */
export class DurableControlCli implements DurableControlHost {
  constructor(private readonly deps: DurableControlCliDeps) {}

  async run(
    argv: readonly string[],
    options: Parameters<DurableControlHost["run"]>[1],
  ): ReturnType<DurableControlHost["run"]> {
    const refusal = refuseControlArgv(argv);
    if (refusal !== undefined) return { envelope: failure("refused", refusal), wrote: false };

    const callerSessionId = this.deps.sessionIdOf(options.conversationId);
    // The refusal is recorded here, not read back from the CLI's error: some commands keep only
    // the message and status.
    const outcome: { wrote: boolean; blocked?: ControlJson } = { wrote: false };
    const interceptor = async (request: LocalApiInterceptedRequest): Promise<void> => {
      if (request.method === "GET") return;
      if (!options.onWrite) {
        const message = `${request.method} ${request.path} is a write; oppi_query is read-only. Use oppi_script.`;
        outcome.blocked = failure("read_only", message);
        throw new Error(message);
      }
      try {
        await options.onWrite(await this.describe(request, callerSessionId, options.signal));
        // The answer can land as the script is stopped; a stopped script sends nothing.
        options.signal.throwIfAborted();
      } catch (error) {
        if (options.signal.aborted) throw error;
        const message = safeErrorMessage(error);
        const code = (error as { code?: unknown } | null)?.code;
        outcome.blocked = failure(typeof code === "string" ? code : "declined", message);
        throw new Error(message, { cause: error });
      }
      outcome.wrote = true;
    };

    const result = await withLocalApiInterceptor(interceptor, () =>
      runCli(withReplayKey(argv, options.key), {
        dataDir: this.deps.dataDir,
        forceJson: true,
        captureHuman: true,
        ...(callerSessionId ? { callerSessionId } : {}),
        signal: options.signal,
      }),
    );
    const envelope =
      outcome.blocked ?? ((result.json ?? { ok: false, error: result.error }) as ControlJson);
    return { envelope, wrote: outcome.wrote };
  }

  /** The request as the confirm card shows it; a PATCH also carries the record it changes. */
  private async describe(
    request: LocalApiInterceptedRequest,
    callerSessionId: string | undefined,
    signal: AbortSignal,
  ): Promise<ControlWrite> {
    const write: ControlWrite = {
      method: request.method,
      path: request.path,
      ...(request.body ? { body: request.body as JsonValue } : {}),
    };
    if (request.method !== "PATCH") return write;
    try {
      write.current = await localApiRequest<JsonValue>(
        createCliConnectionConfig(this.deps.dataDir),
        request.path.split("?")[0] ?? request.path,
        { signal, ...(callerSessionId ? { callerSessionId } : {}) },
      );
    } catch (error) {
      write.currentError = safeErrorMessage(error);
    }
    return write;
  }
}
