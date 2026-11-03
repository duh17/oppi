import {
  buildExtensionUINotificationMessage,
  buildExtensionUIPatchMessage,
  buildExtensionUISettledMessage,
  buildExtensionUISurfaceMessage,
} from "./extension-ui-contract.js";
import {
  applyExtensionUISurfacePatch,
  extensionUISurfaceProjectionClearRequest,
  extensionUISurfaceProjectionRequest,
  readExtensionUISurface,
  EXTENSION_UI_SURFACE_ACTION_RATE_LIMIT,
  EXTENSION_UI_SURFACE_ACTION_RATE_WINDOW_MS,
} from "./extension-surface.js";
import type {
  ExtensionUIDataTableComposite,
  ExtensionUISurface,
  ExtensionUISurfaceActionAnswer,
  ExtensionUISurfaceActionMessage,
  ServerMessage,
} from "./types.js";

/**
 * The publish → act → patch → re-render → dismiss loop for one session's composable surfaces.
 *
 * A `persistent` surface replaces by key, coalesced at 250 ms with the newest state winning, and
 * survives turns until it is cleared or the session ends. A `oneShot` surface carries a server
 * deadline and settles before it. Actions answer with a patch, a replacement surface, or an error
 * drawn by their own card; a replay never runs the work twice, and every answer ends the tap's
 * round trip.
 *
 * The runtime owns no plugin code: `runAction` is the extension's handler, run outside the tool
 * call that published the surface (a persistent surface outlives it) and aborted at its deadline.
 */

/** Does a client draw v2 composites, or the v1 projection of them? */
export type ExtensionUISurfaceAudience = "composites" | "v1-projection";

export const EXTENSION_UI_SURFACE_COALESCE_MS = 250;

export interface ExtensionSurfaceActionRequest {
  surface: ExtensionUISurface;
  compositeId: string;
  actionId: string;
  rowId?: string;
  /** The revision the client acted on. */
  revision: number;
  values?: Record<string, string | number | boolean>;
  /** Which client sent it, for the per-surface action rate limit. */
  clientId: string;
  /** Aborted when the surface settles (dismissed, replaced by nothing, or past its deadline). */
  signal: AbortSignal;
}

export interface ExtensionSurfaceRuntimeOptions {
  /** The surface's session, stamped on every message the runtime emits. */
  sessionId: string;
  /**
   * Deliver one frame to the clients of one audience. The runtime emits every frame once per
   * audience, so the clients that draw v1 widgets and the clients that draw v2 each get the
   * shape they can draw, and one of them never downgrades the other.
   */
  emit: (message: ServerMessage, audience: ExtensionUISurfaceAudience) => void;
  /** The extension's action handler; required to accept actions. */
  runAction?: (request: ExtensionSurfaceActionRequest) => Promise<ExtensionUISurfaceActionAnswer>;
  /**
   * A surface settled here rather than by whoever published it: its deadline passed, or the
   * session stopped. Whoever handed it an action handler drops that handler and binds a new one
   * when the surface is published again.
   */
  onSettled?: (surfaceId: string) => void;
  now?: () => number;
  coalesceMs?: number;
  actionRateLimit?: number;
  actionRateWindowMs?: number;
}

interface CoalescedPublish {
  surface: ExtensionUISurface;
  timer: ReturnType<typeof setTimeout> | undefined;
  lastEmittedAt: number | undefined;
}

/** An action carries collected values, not a payload: a card's answer stays small. */
export const EXTENSION_UI_SURFACE_MAX_ACTION_VALUES = 32;
export const EXTENSION_UI_SURFACE_MAX_ACTION_VALUE_BYTES = 4 * 1024;

/** A failing action is drawn by the card that offered it, in the host's own words. */
const ACTION_FAILURE_TITLE = "Action failed";
const ACTION_RATE_LIMIT_TITLE = "Too many actions";
const ACTION_RATE_LIMIT_MESSAGE = "Try again in a minute.";
/** Answers kept for replay; far more than a client can miss and still act again. */
export const EXTENSION_UI_SURFACE_MAX_REMEMBERED_ANSWERS = 512;
/** Dismissed surface ids whose last revision a re-publish has to continue above. */
const MAX_REMEMBERED_REVISIONS = 64;

export class ExtensionSurfaceRuntime {
  private readonly surfaces = new Map<string, ExtensionUISurface>();
  private readonly publishes = new Map<string, CoalescedPublish>();
  private readonly deadlines = new Map<string, ReturnType<typeof setTimeout>>();
  private readonly inFlight = new Map<string, Set<AbortController>>();
  private readonly answered = new Map<string, ExtensionUISurfaceActionAnswer>();
  private readonly running = new Map<string, Promise<ExtensionUISurfaceActionAnswer>>();
  private readonly actionStamps = new Map<string, number[]>();
  private readonly revisionFloors = new Map<string, number>();
  private readonly now: () => number;
  private readonly coalesceMs: number;
  private readonly actionRateLimit: number;
  private readonly actionRateWindowMs: number;
  private stopped = false;

  constructor(private readonly options: ExtensionSurfaceRuntimeOptions) {
    this.now = options.now ?? Date.now;
    this.coalesceMs = options.coalesceMs ?? EXTENSION_UI_SURFACE_COALESCE_MS;
    this.actionRateLimit = options.actionRateLimit ?? EXTENSION_UI_SURFACE_ACTION_RATE_LIMIT;
    this.actionRateWindowMs =
      options.actionRateWindowMs ?? EXTENSION_UI_SURFACE_ACTION_RATE_WINDOW_MS;
  }

  /** Every live surface, newest state first, for a client that has just subscribed. */
  snapshot(): ExtensionUISurface[] {
    const seen = new Map<string, ExtensionUISurface>();
    for (const surface of this.surfaces.values()) seen.set(surface.id, surface);
    for (const queued of this.publishes.values()) seen.set(queued.surface.id, queued.surface);
    return [...seen.values()];
  }

  /**
   * Publish or replace a surface by id. Persists are coalesced: the first state goes out at once
   * and the newest state within the window replaces what was queued.
   */
  publish(value: unknown): ExtensionUISurface | undefined {
    if (this.stopped) return undefined;
    const read = readExtensionUISurface(value);
    if ("problem" in read) return undefined;
    const surface = read.surface;
    const queued = this.publishes.get(surface.id);
    if (queued) {
      queued.surface = surface;
      return surface;
    }
    const entry: CoalescedPublish = {
      surface,
      timer: undefined,
      lastEmittedAt: this.surfaces.get(surface.id)?.publishedAt,
    };
    this.publishes.set(surface.id, entry);
    const now = this.now();
    const wait =
      entry.lastEmittedAt === undefined ? 0 : entry.lastEmittedAt + this.coalesceMs - now;
    if (wait <= 0) this.flush(surface.id);
    else entry.timer = setTimeout(() => this.flush(surface.id), wait);
    return surface;
  }

  /** The extension is done with this surface: its action work is cancelled and the client clears it. */
  dismiss(surfaceId: string): boolean {
    const queued = this.publishes.get(surfaceId);
    if (queued) {
      clearTimeout(queued.timer);
      this.publishes.delete(surfaceId);
    }
    this.clearDeadline(surfaceId);
    const live = this.surfaces.get(surfaceId);
    if (!live) return false;
    this.cancelActions(surfaceId);
    this.surfaces.delete(surfaceId);
    this.forget(surfaceId);
    this.options.onSettled?.(surfaceId);
    const revision = this.nextRevision(surfaceId, live);
    this.rememberRevision(surfaceId, revision);
    this.sendRemoved(surfaceId, revision);
    return true;
  }

  /** Session teardown: every surface is gone and every pending answer is dropped. */
  stop(): void {
    if (this.stopped) return;
    for (const queued of this.publishes.values()) clearTimeout(queued.timer);
    this.publishes.clear();
    for (const surfaceId of this.deadlines.keys()) this.clearDeadline(surfaceId);
    for (const surface of [...this.surfaces.values()]) {
      this.cancelActions(surface.id);
      this.options.onSettled?.(surface.id);
      this.sendRemoved(surface.id, this.nextRevision(surface.id, surface));
    }
    this.surfaces.clear();
    this.answered.clear();
    this.running.clear();
    this.actionStamps.clear();
    this.revisionFloors.clear();
    this.stopped = true;
  }

  /**
   * One action from one client, which says which audience it draws: a client that sees only the
   * v1 projection is refused, since it never drew the card it is acting on.
   *
   * Whatever the answer — a patch, a replacement, a failure on its own card, or nothing to draw —
   * the round trip ends with a settled for the tap's request id, so the client's pending state
   * always has a frame that clears it. A replay of the same tap returns the first answer without
   * running the work again.
   */
  async act(
    message: ExtensionUISurfaceActionMessage,
    clientId: string,
    audience: ExtensionUISurfaceAudience,
  ): Promise<ExtensionUISurfaceActionAnswer> {
    const answer = await this.answer(message, clientId, audience);
    this.endRoundTrip(message.requestId, audience);
    return answer;
  }

  /** The answer to one tap, before its round trip is settled. */
  private async answer(
    message: ExtensionUISurfaceActionMessage,
    clientId: string,
    audience: ExtensionUISurfaceAudience,
  ): Promise<ExtensionUISurfaceActionAnswer> {
    if (audience === "v1-projection") {
      return {
        error: {
          compositeId: message.compositeId,
          message: "This client cannot act on a surface.",
        },
      };
    }

    this.flush(message.surfaceId);
    const surface = this.surfaces.get(message.surfaceId);
    if (this.stopped || !surface)
      return this.refuse(undefined, message, { message: "This surface is gone." });

    const composite = surface.sections.find((section) => section.id === message.compositeId);
    if (!composite) return this.refuse(undefined, message, { message: "This card is gone." });

    const offered = message.rowId
      ? composite.composite === "dataTable"
        ? this.rowActionIds(composite, message.rowId)
        : undefined
      : composite.actions;
    if (!offered?.includes(message.actionId))
      return this.refuse(surface, message, {
        message: "This action is not available.",
      });

    if (!this.valuesWithinCaps(message.values))
      return this.refuse(surface, message, {
        message: "The action carried more than it may.",
      });

    const replayKey = this.actionKey(message);
    const previous = this.answered.get(replayKey);
    if (previous) {
      // The first answer is the answer. A replay resyncs the client with the surface's current
      // state instead of re-applying an old patch on top of a newer one.
      this.emitSurface(surface);
      return previous;
    }
    // A second tap on the same action while the first is still running joins it: one card
    // cannot run its work twice, and both taps get the one answer.
    const running = this.running.get(replayKey);
    if (running) return running;

    if (!this.takeActionSlot(message.surfaceId, clientId)) {
      return this.refuse(surface, message, {
        title: ACTION_RATE_LIMIT_TITLE,
        message: ACTION_RATE_LIMIT_MESSAGE,
      });
    }

    const work = this.runOnce(surface, message, clientId, replayKey);
    this.running.set(replayKey, work);
    try {
      return await work;
    } finally {
      if (this.running.get(replayKey) === work) this.running.delete(replayKey);
    }
  }

  // ── answers ──

  /** The extension's work for one tap, remembered and applied before the promise settles. */
  private async runOnce(
    surface: ExtensionUISurface,
    message: ExtensionUISurfaceActionMessage,
    clientId: string,
    replayKey: string,
  ): Promise<ExtensionUISurfaceActionAnswer> {
    const controller = new AbortController();
    this.trackAction(message.surfaceId, controller);
    let answer: ExtensionUISurfaceActionAnswer;
    try {
      answer = this.options.runAction
        ? await this.options.runAction({
            surface,
            compositeId: message.compositeId,
            actionId: message.actionId,
            ...(message.rowId ? { rowId: message.rowId } : {}),
            revision: message.revision,
            ...(message.values ? { values: message.values } : {}),
            clientId,
            signal: controller.signal,
          })
        : { error: { compositeId: message.compositeId, message: "This action is not available." } };
    } catch (error) {
      answer = {
        error: {
          compositeId: message.compositeId,
          message: error instanceof Error ? error.message : String(error),
        },
      };
    } finally {
      this.untrackAction(message.surfaceId, controller);
    }
    // A settled session has nothing left to draw on, and nobody left to draw for.
    if (this.stopped) return answer;
    this.remember(replayKey, answer);
    this.apply(surface, message.compositeId, answer);
    return answer;
  }

  /**
   * Apply an answer to its own card. An answer with nothing to draw — a deliberate "nothing
   * visible" patch, or a malformed one the host drops whole — changes nothing the client holds;
   * its round trip still ends, because `act` settles it either way.
   */
  private apply(
    surface: ExtensionUISurface,
    compositeId: string,
    answer: ExtensionUISurfaceActionAnswer,
  ): void {
    const current = this.surfaces.get(surface.id);
    if (!current) return;
    if ("error" in answer) {
      this.drawError(current, answer.error);
      return;
    }
    if ("surface" in answer) {
      const read = readExtensionUISurface(answer.surface);
      // A replacement keeps its identity: another id is a different surface, not an answer.
      if ("problem" in read || read.surface.id !== current.id) {
        this.drawError(current, {
          compositeId,
          title: ACTION_FAILURE_TITLE,
          message: "The answer was not a valid surface.",
        });
        return;
      }
      this.commit(read.surface);
      return;
    }
    if (Object.keys(answer.patch).length === 0) return;
    const merged = applyExtensionUISurfacePatch(current, answer.patch);
    if (!merged) {
      // A malformed patch is dropped whole, so the card that offered the action says so.
      this.drawError(current, {
        compositeId,
        title: ACTION_FAILURE_TITLE,
        message: "The answer was not a valid change.",
      });
      return;
    }
    this.commit(merged, answer.patch);
  }

  /** Draw a failure on the card that offered the action, unless that card is already gone. */
  private drawError(
    surface: ExtensionUISurface,
    error: { compositeId: string; title?: string; message: string },
  ): void {
    const index = surface.sections.findIndex((section) => section.id === error.compositeId);
    if (index < 0) return;
    const patch = {
      [`sections.${index}.state`]: {
        kind: "failure",
        title: error.title ?? ACTION_FAILURE_TITLE,
        message: error.message,
      },
    };
    const merged = applyExtensionUISurfacePatch(surface, patch);
    if (merged) this.commit(merged, patch);
  }

  /** A refused action is drawn by the card that offered it, when that card is still there. */
  private refuse(
    surface: ExtensionUISurface | undefined,
    action: ExtensionUISurfaceActionMessage,
    error: { title?: string; message: string },
  ): ExtensionUISurfaceActionAnswer {
    const compositeId = action.compositeId;
    if (surface) this.drawError(surface, { compositeId, ...error });
    return { error: { compositeId, message: error.message } };
  }

  /** Every action ends here; a tap that carried no request id has nothing to answer. */
  private endRoundTrip(requestId: string | undefined, audience: ExtensionUISurfaceAudience): void {
    if (!requestId) return;
    this.options.emit(buildExtensionUISettledMessage(this.options.sessionId, requestId), audience);
  }

  /** Store the new state, advance the revision, and send the change. */
  private commit(next: ExtensionUISurface, patch?: Record<string, unknown>): void {
    const previous = this.surfaces.get(next.id);
    const revision = this.nextRevision(next.id, previous);
    const surface: ExtensionUISurface = {
      ...next,
      revision,
      publishedAt: this.now(),
    };
    this.surfaces.set(surface.id, surface);
    this.scheduleDeadline(surface);
    if (patch === undefined) {
      this.emitSurface(surface);
      return;
    }
    this.sendPatch(surface.id, revision, { patch });
  }

  // ── frames ──

  private flush(surfaceId: string): void {
    const queued = this.publishes.get(surfaceId);
    if (!queued) return;
    clearTimeout(queued.timer);
    this.publishes.delete(surfaceId);
    const previous = this.surfaces.get(surfaceId);
    const surface: ExtensionUISurface = {
      ...queued.surface,
      revision: this.nextRevision(surfaceId, previous),
      publishedAt: this.now(),
    };
    this.surfaces.set(surfaceId, surface);
    this.scheduleDeadline(surface);
    this.emitSurface(surface);
  }

  private emitSurface(surface: ExtensionUISurface): void {
    this.send(buildExtensionUISurfaceMessage(this.options.sessionId, surface));
  }

  private sendPatch(
    surfaceId: string,
    revision: number,
    change: { patch?: Record<string, unknown>; removed?: boolean },
  ): void {
    this.send(buildExtensionUIPatchMessage(this.options.sessionId, surfaceId, revision, change));
  }

  private sendRemoved(surfaceId: string, revision: number): void {
    this.sendPatch(surfaceId, revision, { removed: true });
  }

  /**
   * Every frame goes out once per audience in the shape that audience draws: the v2 frame to the
   * clients that draw composites, and the v1 widget projection of the same change to the rest.
   */
  private send(message: ServerMessage): void {
    this.options.emit(message, "composites");
    if (message.type === "extension_ui_surface") {
      this.options.emit(
        buildExtensionUINotificationMessage(extensionUISurfaceProjectionRequest(message.surface)),
        "v1-projection",
      );
      return;
    }
    if (message.type !== "extension_ui_patch") return;
    const surface = this.surfaces.get(message.surfaceId);
    this.options.emit(
      buildExtensionUINotificationMessage(
        surface && !message.removed
          ? extensionUISurfaceProjectionRequest(surface)
          : extensionUISurfaceProjectionClearRequest(message.surfaceId),
      ),
      "v1-projection",
    );
  }

  // ── revisions ──

  /**
   * Revisions are monotonic per surface id for the session: a client drops a late frame by
   * comparing revisions, so a surface published again after its removal continues above the
   * revision the removal carried.
   */
  private nextRevision(surfaceId: string, previous: ExtensionUISurface | undefined): number {
    return Math.max(previous?.revision ?? 0, this.revisionFloors.get(surfaceId) ?? 0) + 1;
  }

  /** Bounded: a session that publishes thousands of short-lived surfaces remembers the newest. */
  private rememberRevision(surfaceId: string, revision: number): void {
    this.revisionFloors.delete(surfaceId);
    this.revisionFloors.set(surfaceId, revision);
    if (this.revisionFloors.size <= MAX_REMEMBERED_REVISIONS) return;
    const oldest = this.revisionFloors.keys().next();
    if (!oldest.done) this.revisionFloors.delete(oldest.value);
  }

  // ── deadlines and cancellation ──

  private scheduleDeadline(surface: ExtensionUISurface): void {
    this.clearDeadline(surface.id);
    if (surface.lifecycle !== "oneShot" || surface.timeoutAt === undefined) return;
    const wait = Math.max(0, surface.timeoutAt - this.now());
    this.deadlines.set(
      surface.id,
      setTimeout(() => this.dismiss(surface.id), wait),
    );
  }

  private clearDeadline(surfaceId: string): void {
    const timer = this.deadlines.get(surfaceId);
    if (timer === undefined) return;
    clearTimeout(timer);
    this.deadlines.delete(surfaceId);
  }

  private trackAction(surfaceId: string, controller: AbortController): void {
    const set = this.inFlight.get(surfaceId) ?? new Set<AbortController>();
    set.add(controller);
    this.inFlight.set(surfaceId, set);
  }

  private untrackAction(surfaceId: string, controller: AbortController): void {
    const set = this.inFlight.get(surfaceId);
    set?.delete(controller);
    if (set?.size === 0) this.inFlight.delete(surfaceId);
  }

  /** A surface that settles cancels its own action work; nothing outlives the card it answered. */
  private cancelActions(surfaceId: string): void {
    for (const controller of this.inFlight.get(surfaceId) ?? []) controller.abort();
    this.inFlight.delete(surfaceId);
  }

  /** Everything remembered about one surface, dropped with it. */
  private forget(surfaceId: string): void {
    const prefix = `${surfaceId}\u0000`;
    for (const key of this.answered.keys()) if (key.startsWith(prefix)) this.answered.delete(key);
    for (const key of this.running.keys()) if (key.startsWith(prefix)) this.running.delete(key);
    for (const key of this.actionStamps.keys())
      if (key.startsWith(prefix)) this.actionStamps.delete(key);
  }

  // ── policy ──

  private actionKey(message: ExtensionUISurfaceActionMessage): string {
    // A row action is per row: two rows' taps are not replays of one another.
    return [
      message.surfaceId,
      message.compositeId,
      message.actionId,
      message.rowId ?? "",
      String(message.revision),
    ].join("\u0000");
  }

  private rowActionIds(
    composite: ExtensionUIDataTableComposite,
    rowId: string,
  ): string[] | undefined {
    return composite.rows.find((row) => row.id === rowId)?.actions;
  }

  /** A card's answer is small and flat: collected values are strings, numbers, or booleans. */
  private valuesWithinCaps(values: Record<string, string | number | boolean> | undefined): boolean {
    if (!values) return true;
    const entries = Object.entries(values);
    if (entries.length > EXTENSION_UI_SURFACE_MAX_ACTION_VALUES) return false;
    for (const [, value] of entries) {
      if (typeof value === "string" || typeof value === "boolean") continue;
      if (typeof value === "number" && Number.isFinite(value)) continue;
      return false;
    }
    try {
      return (
        Buffer.byteLength(JSON.stringify(values), "utf8") <=
        EXTENSION_UI_SURFACE_MAX_ACTION_VALUE_BYTES
      );
    } catch {
      return false;
    }
  }

  /** Idempotency memo, bounded: the newest answers win for a surface that lives a long time. */
  private remember(key: string, answer: ExtensionUISurfaceActionAnswer): void {
    this.answered.set(key, answer);
    if (this.answered.size <= EXTENSION_UI_SURFACE_MAX_REMEMBERED_ANSWERS) return;
    const oldest = this.answered.keys().next();
    if (!oldest.done) this.answered.delete(oldest.value);
  }

  private takeActionSlot(surfaceId: string, clientId: string): boolean {
    const key = `${surfaceId}\u0000${clientId}`;
    const now = this.now();
    const stamps = (this.actionStamps.get(key) ?? []).filter(
      (stamp) => now - stamp < this.actionRateWindowMs,
    );
    if (stamps.length >= this.actionRateLimit) {
      this.actionStamps.set(key, stamps);
      return false;
    }
    stamps.push(now);
    this.actionStamps.set(key, stamps);
    return true;
  }
}
