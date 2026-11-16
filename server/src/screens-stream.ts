/**
 * `WS /screens/stream`: plugin screens for the app (`types/screens.ts`). One socket per app while
 * a plugin screen is visible, multiplexed by watch id. A `watch` holds the entry's screen object
 * for `{ scope, page }` and follows its page document: the first value whole, then each change as
 * Chord delta ops against the last value sent (`diffRevisions`, as the conversation stream does).
 * Every value is checked and budgeted first (`checkScreenPage`); a value that fails is reported
 * (`failed`) and the app keeps the last one. No sequence numbers and no replay: a reconnecting
 * app watches again and gets the current value.
 *
 * A watch ends `gone` when its entry, its workspace or its page goes (a plugin unloaded, a page
 * that says `gone`), `off` when the entry's feature switch is off (at `watch`, or when
 * `featuresChanged` turns it off), and `unsupported` for a vocabulary version or scope the entry
 * does not serve. `act` runs on the watched object and answers its own `result`; it is never
 * retried. An `act` sent right after its `watch` waits for the page to open, and one already
 * running finishes even if the page is unwatched meanwhile: it is the person's own change.
 */
import { BACKGROUND_CONTEXT, withAbortSignal } from "@earendil-works/chord/context";
import { diffRevisions } from "@earendil-works/chord/delta";
import type { JsonValue } from "@earendil-works/chord/json";
import type { WatchHandle } from "@earendil-works/chord/watch";
import type { WebSocket } from "ws";
import { isRecord } from "./json-shape.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import {
  checkScreenPage,
  screenPageIdProblem,
  screenScopeServed,
  sidebarEntryOn,
  SCREENS_VERSION,
  type ScreenHost,
  type ScreenReference,
  type SidebarContribution,
} from "./plugin-screens.js";
import type { ServerFeatureSwitches } from "./server-features.js";
import {
  answerAuthRenew,
  authRenewToken,
  MAX_AUTH_RENEW_FRAME_BYTES,
  type RenewStreamAccess,
} from "./stream-auth-renewal.js";
import type {
  ConversationDocOp,
  ScreenEndReason,
  ScreenNav,
  ScreensClientMessage,
  ScreensServerMessage,
  ScreenValue,
} from "./types.js";

const log = createLogger({ base: { component: "screens_stream" } });

/** Larger than any frame the app sends: a form's draft is a few kilobytes. */
const MAX_CLIENT_FRAME_BYTES = 128 * 1024;
const MAX_WATCHES_PER_SOCKET = 16;

interface ScreensStreamOptions {
  /** The plugins' entries and screens; loads the plugins on first use. */
  readonly screens: () => Promise<ScreenHost | undefined>;
  /** The server's feature switches now. */
  readonly features: () => Readonly<ServerFeatureSwitches>;
  /** Whether a workspace scope's workspace exists. */
  readonly workspaceExists: (id: string) => boolean;
  readonly renew?: RenewStreamAccess;
}

/** One watch, counted from its `watch` message on, before anything it waits for. */
interface Watching {
  readonly entry: string;
  /** The entry, once the plugins have loaded and it was found. */
  contribution?: SidebarContribution;
  readonly abort: AbortController;
  ref?: ScreenReference;
  handle?: WatchHandle<JsonValue>;
  /** The last value sent; ops are computed against it. */
  last?: JsonValue;
  /** The screen object once open, or undefined once it never will be. */
  readonly ready: Promise<ScreenReference | undefined>;
  readonly settle: (ref: ScreenReference | undefined) => void;
  /** Acts still running: the screen object is released after the last one. */
  acts: number;
  ended: boolean;
}

export class ScreensStreamMux {
  private readonly sockets = new Set<ScreensSocket>();

  constructor(private readonly options: ScreensStreamOptions) {}

  handleWebSocket(ws: WebSocket): void {
    const socket = new ScreensSocket(ws, this.options);
    this.sockets.add(socket);
    ws.on("close", () => {
      this.sockets.delete(socket);
      socket.close();
    });
  }

  /** A feature switch changed: every watch of an entry whose feature is now off ends `off`. */
  featuresChanged(): void {
    const features = this.options.features();
    for (const socket of this.sockets) socket.endOff(features);
  }
}

class ScreensSocket {
  private readonly watches = new Map<string, Watching>();

  constructor(
    private readonly ws: WebSocket,
    private readonly options: ScreensStreamOptions,
  ) {
    ws.on("message", (data, isBinary) => {
      if (isBinary) return;
      const text = data.toString();
      if (text.length > MAX_CLIENT_FRAME_BYTES) return;
      let parsed: unknown;
      try {
        parsed = JSON.parse(text);
      } catch {
        return;
      }
      if (!isRecord(parsed)) return;
      const token = text.length <= MAX_AUTH_RENEW_FRAME_BYTES ? authRenewToken(parsed) : undefined;
      if (token !== undefined) {
        answerAuthRenew(options.renew, ws, token, "screens", (message) => this.sendRaw(message));
        return;
      }
      const message = parseClientMessage(parsed);
      if (!message) return;
      if (message.type === "watch") void this.watch(message);
      else if (message.type === "unwatch") this.end(message.watch);
      else void this.act(message);
    });
  }

  close(): void {
    for (const id of [...this.watches.keys()]) this.end(id);
  }

  endOff(features: Readonly<ServerFeatureSwitches>): void {
    for (const [id, watching] of [...this.watches]) {
      if (!watching.contribution || sidebarEntryOn(watching.contribution, features)) continue;
      this.end(id);
      this.send({ type: "ended", watch: id, reason: "off" });
    }
  }

  private async watch(message: Extract<ScreensClientMessage, { type: "watch" }>): Promise<void> {
    const { watch: id, entry: entryId, scope, page } = message;
    this.end(id);
    const ended = (reason: ScreenEndReason): void =>
      this.send({ type: "ended", watch: id, reason });
    if (message.v !== SCREENS_VERSION || screenPageIdProblem(page)) return ended("unsupported");
    if (this.watches.size >= MAX_WATCHES_PER_SOCKET)
      return this.send({ type: "failed", watch: id, message: "Too many open screens" });
    // Counted now, so the limit holds while the plugins load; an unwatch meanwhile replaces it.
    let settle: (ref: ScreenReference | undefined) => void = () => undefined;
    const ready = new Promise<ScreenReference | undefined>((resolve) => (settle = resolve));
    const watching: Watching = {
      entry: entryId,
      abort: new AbortController(),
      ready,
      settle,
      acts: 0,
      ended: false,
    };
    this.watches.set(id, watching);
    const current = (): boolean => this.watches.get(id) === watching;
    let host: ScreenHost | undefined;
    try {
      host = await this.options.screens();
    } catch (error) {
      log.warn("screens.unavailable", { error: safeErrorMessage(error) });
    }
    if (!current()) return;
    const entry = host?.entries().find((candidate) => candidate.id === entryId);
    if (!host || !entry) {
      this.end(id);
      return ended("gone");
    }
    if (!screenScopeServed(entry, scope)) {
      this.end(id);
      return ended("unsupported");
    }
    if (scope !== "server" && !this.options.workspaceExists(scope.slice("workspace:".length))) {
      this.end(id);
      return ended("gone");
    }
    if (!sidebarEntryOn(entry, this.options.features())) {
      this.end(id);
      return ended("off");
    }
    watching.contribution = entry;
    const context = withAbortSignal(watching.abort.signal, BACKGROUND_CONTEXT);
    try {
      const ref = await host.open(entry, { scope, page }, context);
      if (!current()) return ref.release();
      watching.ref = ref;
      watching.settle(ref);
      const handle = await ref.page.watch(context);
      if (!current()) {
        void handle.stop();
        return;
      }
      watching.handle = handle;
      this.deliver(id, watching, handle.value);
      handle.start(async (call) => {
        if (call.kind === "value") this.deliver(id, watching, call.value);
      });
      void handle.closed.then((end) => {
        if (this.watches.get(id) !== watching) return;
        this.end(id);
        if (end.kind === "ended" || end.kind === "failed") ended("gone");
      });
    } catch (error) {
      if (this.watches.get(id) !== watching) return;
      this.end(id);
      this.send({ type: "failed", watch: id, message: safeErrorMessage(error) });
    }
  }

  /** Check `value` and send it whole the first time, else what changed since the last one. */
  private deliver(id: string, watching: Watching, value: JsonValue): void {
    if (this.watches.get(id) !== watching) return;
    if (isRecord(value) && value.gone === true) {
      this.end(id);
      this.send({ type: "ended", watch: id, reason: "gone" });
      return;
    }
    const problem = checkScreenPage(value);
    if (problem) {
      log.warn("screens.page_refused", { entry: watching.entry, problem });
      this.send({ type: "failed", watch: id, message: `The page was refused: ${problem}` });
      return;
    }
    const last = watching.last;
    watching.last = value;
    if (last === undefined) {
      this.send({ type: "value", watch: id, value: value as never });
      return;
    }
    const ops = diffRevisions(last, value) as ConversationDocOp[];
    if (ops.length > 0) this.send({ type: "ops", watch: id, ops });
  }

  private async act(message: Extract<ScreensClientMessage, { type: "act" }>): Promise<void> {
    const { call, watch: id } = message;
    const watching = this.watches.get(id);
    // A page still opening answers once it is open.
    const ref = watching && (watching.ref ?? (await watching.ready));
    if (!watching || !ref) {
      this.send({ type: "result", call, ok: false, message: "This page is not open." });
      return;
    }
    watching.acts += 1;
    try {
      // Not the watch's context: leaving the page does not cancel a change the person made.
      const answer = await ref.act(
        {
          action: message.action,
          ...(message.row !== undefined ? { row: message.row } : {}),
          ...(message.values ? { values: message.values } : {}),
        },
        BACKGROUND_CONTEXT,
      );
      this.send({ type: "result", call, ...actResult(answer) });
    } catch (error) {
      this.send({ type: "result", call, ok: false, message: safeErrorMessage(error) });
    } finally {
      watching.acts -= 1;
      if (watching.ended && watching.acts === 0) ref.release();
    }
  }

  private end(id: string): void {
    const watching = this.watches.get(id);
    if (!watching) return;
    this.watches.delete(id);
    watching.ended = true;
    watching.abort.abort();
    watching.settle(undefined);
    void watching.handle?.stop();
    if (watching.acts === 0) watching.ref?.release();
  }

  private send(message: ScreensServerMessage): void {
    this.sendRaw(message);
  }

  private sendRaw(message: object): void {
    if (this.ws.readyState === this.ws.OPEN) this.ws.send(JSON.stringify(message));
  }
}

/** A plugin's `act` answer as the wire carries it; anything else is a failure without words. */
function actResult(answer: unknown): { ok: boolean; message?: string; nav?: ScreenNav } {
  if (!isRecord(answer) || typeof answer.ok !== "boolean") return { ok: false };
  const nav = answer.nav;
  const validNav =
    isRecord(nav) &&
    (nav.kind === "pop" ||
      ((nav.kind === "push" || nav.kind === "present") && typeof nav.page === "string"));
  return {
    ok: answer.ok,
    ...(typeof answer.message === "string" ? { message: answer.message } : {}),
    ...(validNav ? { nav: nav as ScreenNav } : {}),
  };
}

const MAX_VALUES = 64;

function parseClientMessage(value: Record<string, unknown>): ScreensClientMessage | undefined {
  const text = (key: string): string | undefined =>
    typeof value[key] === "string" && (value[key] as string).length > 0
      ? (value[key] as string)
      : undefined;
  const watch = text("watch");
  if (!watch) return undefined;
  switch (value.type) {
    case "watch": {
      const entry = text("entry");
      const scope = text("scope");
      const page = text("page");
      if (!entry || !scope || !page || typeof value.v !== "number") return undefined;
      return { type: "watch", watch, entry, scope, page, v: value.v };
    }
    case "unwatch":
      return { type: "unwatch", watch };
    case "act": {
      const call = text("call");
      const action = text("action");
      if (!call || !action) return undefined;
      const row = text("row");
      let values: ScreenValue[] | undefined;
      if (value.values !== undefined) {
        if (!Array.isArray(value.values) || value.values.length > MAX_VALUES) return undefined;
        values = [];
        for (const item of value.values) {
          if (
            !isRecord(item) ||
            typeof item.field !== "string" ||
            (typeof item.value !== "string" && typeof item.value !== "boolean")
          )
            return undefined;
          values.push({ field: item.field, value: item.value });
        }
      }
      return {
        type: "act",
        watch,
        call,
        action,
        ...(row ? { row } : {}),
        ...(values ? { values } : {}),
      };
    }
    default:
      return undefined;
  }
}
