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
 * the host without an HTTP request or the envelope:
 * - flags that read a file of this host (`--definition PATH`, `--instructions-file`, dictionary
 *   `--file`) or stdin (`@-`, `--phrases`): the server's own files and stdin are not the owner's
 * - `--config-file`, and `config set`, which edits the config file directly with no request to gate
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

export function refuseControlArgv(argv: readonly string[]): string | undefined {
  if (argv.includes("@-")) return "Reading stdin (@-) is not available to the control agent.";
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
 * Add `--flag key` unless the script passed the flag: the retry-safe form of the commands whose
 * write would otherwise be repeated by a retry. `agent create` and `session create` keep one
 * entity per key; `schedule run` triggers one run per request id.
 */
export function withIdempotencyKey(argv: readonly string[], key: string): string[] {
  let parsed;
  try {
    parsed = parseCliArgs([...argv]);
  } catch {
    return [...argv];
  }
  const verb = `${parsed.command} ${parsed.positional[0] ?? ""}`;
  const flag =
    verb === "schedule run"
      ? "request-id"
      : verb === "agent create" || verb === "session create"
        ? "idempotency-key"
        : undefined;
  if (flag === undefined || Object.hasOwn(parsed.flags, flag)) return [...argv];
  // Before a `--`, so the pair stays flags.
  const separator = argv.indexOf("--");
  const at = separator === -1 ? argv.length : separator;
  return [...argv.slice(0, at), `--${flag}`, key, ...argv.slice(at)];
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
      } catch (error) {
        if (options.signal.aborted) throw error;
        const message = safeErrorMessage(error);
        outcome.blocked = failure("declined", message);
        throw new Error(message, { cause: error });
      }
      outcome.wrote = true;
    };

    const result = await withLocalApiInterceptor(interceptor, () =>
      runCli(withIdempotencyKey(argv, options.key), {
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
