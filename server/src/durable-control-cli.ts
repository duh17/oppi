import { createHash } from "node:crypto";
import { join } from "node:path";
import type { ConversationId } from "@earendil-works/pi-durable";
import type { JsonValue } from "@earendil-works/chord";
import {
  answerRecord,
  decodePathSegment,
  type ControlJson,
  type ControlWrite,
  type DurableControlHost,
} from "./durable-extension-api.js";
import { parseCliArgs } from "./cli/args.js";
import { createCliConnectionConfig } from "./cli/connection-config.js";
import {
  localApiRequest,
  withLocalApiInterceptor,
  type LocalApiInterceptedRequest,
} from "./cli/local-api-client.js";
import { runCli } from "./cli/runner.js";
import { safeErrorMessage } from "./log-utils.js";
import { getOppiDocsPath } from "./oppi-docs.js";

/**
 * The only argv this host refuses before `runCli`. Argv classification is NOT the safety
 * boundary (the confirm gate on every non-GET request is); these are the ways a command reaches
 * the host without an HTTP request or the envelope, or that would hurt the server it runs in:
 * - flags that read a file of this host (`--definition PATH`, `--instructions-file`, dictionary
 *   `--file`) or stdin (`@-`, `--phrases`): the server's own files and stdin are not the owner's
 * - `--config-file`, and `config set`, which edits the config file directly with no request to gate
 * - `control`: its `send` would prompt the standing control conversation, maybe this very one,
 *   from inside a turn
 * - `status`: it shells out synchronously (`execFileSync`), which would stall the server's event loop
 * - `--idempotency-key=…`, `--request-id=…`, `--turn-id=…`: the CLI does not split on `=`, so that
 *   form is an unknown flag, which the runner refuses. The host cannot tell it from
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
 * is the ONLY key it carries, and a key the caller passed is dropped. The call key (the tool
 * call's task id) is the same when a crashed call reruns; the hash ties the key to this exact
 * command, so no other write can ever carry it. Other commands are returned unchanged.
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

/** Collections whose `GET /<collection>/:id` answers one record the confirm card can read. */
const NAMED_COLLECTIONS: ReadonlySet<string> = new Set([
  "agents",
  "schedules",
  "sessions",
  "workspaces",
]);

/** Body keys that hold the id of a record in a collection above. */
const ID_KEY_COLLECTION: { readonly [key: string]: string } = {
  workspaceId: "workspaces",
  agentId: "agents",
  sessionId: "sessions",
};

/** The most records the host reads for one card. */
const MAX_NAME_LOOKUPS = 8;

function collectBodyIds(value: JsonValue | undefined, into: Map<string, string>, depth = 0): void {
  if (value === null || typeof value !== "object" || Array.isArray(value) || depth > 4) return;
  for (const [key, inner] of Object.entries(value)) {
    const collection = ID_KEY_COLLECTION[key];
    if (collection !== undefined && typeof inner === "string" && inner !== "")
      into.set(inner, `/${collection}/${encodeURIComponent(inner)}`);
    else collectBodyIds(inner, into, depth + 1);
  }
}

/** The name in a `GET` answer: `{ agent: { name } }`, `{ workspace: { name } }`, and so on. */
function recordName(answer: JsonValue): string | undefined {
  const record = answerRecord(answer);
  const definition = record?.definition;
  const name =
    record?.name ??
    (definition !== null && typeof definition === "object" && !Array.isArray(definition)
      ? definition.name
      : undefined);
  return typeof name === "string" && name !== "" ? name : undefined;
}

function failure(code: string, message: string): ControlJson {
  return { ok: false, error: { code, message } };
}

export interface DurableControlCliDeps {
  dataDir: string;
  /**
   * The Session bound to conversation `conversationId` of durable store `storeId` when it is a
   * durable Oppi Control session, undefined for any other conversation. Commands are attributed
   * to it.
   */
  sessionIdOf(storeId: string, conversationId: ConversationId): string | undefined;
}

/** Runs the `oppi` CLI inside this server process for Oppi Control sessions' tools. */
export class DurableControlCli {
  /** Where the installed docs are; they do not move while the server runs. */
  private readonly docsPath = getOppiDocsPath();

  constructor(private readonly deps: DurableControlCliDeps) {}

  /**
   * What `oppiHost().control(env)` gives the conversation `conversationId` of store `storeId`:
   * the CLI when an Oppi Control session is bound to it, undefined for every other conversation.
   */
  forConversation(storeId: string, conversationId: ConversationId): DurableControlHost | undefined {
    if (this.deps.sessionIdOf(storeId, conversationId) === undefined) return undefined;
    return {
      run: (argv, options) => this.run(storeId, argv, options),
      themesDir: join(this.deps.dataDir, "themes"),
      ...(this.docsPath ? { docsPath: this.docsPath } : {}),
    };
  }

  /** Refuses a conversation of `storeId` that no Oppi Control session is bound to. */
  async run(
    storeId: string,
    argv: readonly string[],
    options: Parameters<DurableControlHost["run"]>[1],
  ): ReturnType<DurableControlHost["run"]> {
    const callerSessionId = this.deps.sessionIdOf(storeId, options.conversationId);
    if (callerSessionId === undefined)
      return {
        envelope: failure(
          "refused",
          "The oppi CLI runs only for Oppi Control sessions, and this is not one.",
        ),
        wrote: false,
      };
    const refusal = refuseControlArgv(argv);
    if (refusal !== undefined) return { envelope: failure("refused", refusal), wrote: false };

    // The refusal is recorded here, not read back from the CLI's error: some commands keep only
    // the message and status.
    const outcome: { wrote: boolean; blocked?: ControlJson } = { wrote: false };
    const interceptor = async (request: LocalApiInterceptedRequest): Promise<void> => {
      if (request.method === "GET") return;
      if (!options.onWrite) {
        const message = `${request.method} ${request.path} is a write; this tool only reads.`;
        outcome.blocked = failure("read_only", message);
        throw new Error(message);
      }
      try {
        await options.onWrite(await this.describe(request, options.signal));
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
        callerSessionId,
        signal: options.signal,
      }),
    );
    const envelope =
      outcome.blocked ?? ((result.json ?? { ok: false, error: result.error }) as ControlJson);
    return { envelope, wrote: outcome.wrote };
  }

  /**
   * The request as the confirm card shows it, with the records it names read by GET (safe): the
   * record the path targets as `current`, and the name of every record the path or body points at.
   */
  private async describe(
    request: LocalApiInterceptedRequest,
    signal: AbortSignal,
  ): Promise<ControlWrite> {
    const write: ControlWrite = {
      method: request.method,
      path: request.path,
      ...(request.body ? { body: request.body as JsonValue } : {}),
    };
    const get = (path: string): Promise<JsonValue> =>
      localApiRequest<JsonValue>(createCliConnectionConfig(this.deps.dataDir), path, {
        signal,
      });
    const segments = (request.path.split("?")[0] ?? "").split("/").filter(Boolean);
    const targetPath =
      segments[0] !== undefined && segments[1] !== undefined && NAMED_COLLECTIONS.has(segments[0])
        ? `/${segments[0]}/${segments[1]}`
        : undefined;
    if (targetPath !== undefined) {
      try {
        write.current = await get(targetPath);
      } catch (error) {
        write.currentError = safeErrorMessage(error);
      }
    }

    // Every id the card may show by name: path pairs, then ids in the body.
    const lookups = new Map<string, string>();
    for (let i = 0; i + 1 < segments.length; i += 1)
      if (NAMED_COLLECTIONS.has(segments[i] as string))
        lookups.set(
          decodePathSegment(segments[i + 1] as string),
          `/${segments[i]}/${segments[i + 1]}`,
        );
    collectBodyIds(request.body as JsonValue | undefined, lookups);
    const names: { [id: string]: string } = {};
    await Promise.all(
      [...lookups].slice(0, MAX_NAME_LOOKUPS).map(async ([id, path]) => {
        try {
          const found =
            path === targetPath && write.current !== undefined ? write.current : await get(path);
          const name = recordName(found);
          if (name !== undefined) names[id] = name;
        } catch {
          // Shown by its id.
        }
      }),
    );
    if (Object.keys(names).length > 0) write.names = names;
    return write;
  }
}
