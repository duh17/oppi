import {
  buildExtensionUINotificationMessage,
  buildExtensionUISurfaceMessage,
  EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
  EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
} from "./extension-ui-contract.js";
import {
  extensionUISurfaceProjectionClearRequest,
  extensionUISurfaceProjectionRequest,
  extensionUISurfaceUsesBlocks,
} from "./extension-surface.js";
import {
  ExtensionSurfaceRuntime,
  type ExtensionUISurfaceAudience,
  type ExtensionSurfaceActionRequest,
} from "./extension-surface-runtime.js";
import type { SurfaceDispatch, SurfacePublisher } from "./durable-surface.js";
import type {
  ExtensionUISurface,
  ExtensionUISurfaceActionAnswer,
  ExtensionUISurfaceActionMessage,
  ServerMessage,
} from "./types.js";

/** What a capability list says this client draws: the strongest shape it names. */
function declaredAudience(capabilities: readonly string[]): ExtensionUISurfaceAudience {
  if (capabilities.includes(EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY)) return "blocks";
  if (capabilities.includes(EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY)) return "composites";
  return "v1-projection";
}

/** A declaration upgrades or repeats; it never downgrades the shape a client already draws. */
const AUDIENCE_RANK: Record<ExtensionUISurfaceAudience, number> = {
  "v1-projection": 0,
  composites: 1,
  blocks: 2,
};

/**
 * One client's frame handler. `audience` names the shape a frame was built for, when it has one:
 * a composable surface goes to the clients that draw composites, its v1 projection to the rest.
 */
export type SessionMessageSubscriber = (
  message: ServerMessage,
  audience?: ExtensionUISurfaceAudience,
) => void;

/**
 * One session's composable surfaces: the publish → act → patch loop, the action each panel
 * answers with, and which shape each connected client draws.
 *
 * The loop owns no plugin code. A panel hands its `SurfaceDispatch` with every publish, so an
 * action runs the extension's own handler outside the tool call that published the surface (a
 * persistent surface outlives it), and the runtime aborts that work when the surface settles. The
 * client without the composites capability is sent the v1 widget projection of the same surfaces
 * instead, so neither shape ever downgrades the other.
 *
 * One of these exists per live Session, created when a plugin first publishes (or a client asks
 * for one), and stopped with the Session: every surface is left, every timer cleared.
 */
export class SessionSurfaces {
  private runtime: ExtensionSurfaceRuntime | undefined;
  /** What runs when a client taps a surface's action: the panel's handler for it. */
  private readonly dispatches = new Map<string, SurfaceDispatch>();
  /** Set at teardown: a publish that arrives afterwards must not start the loop again. */
  private stopped = false;
  /** Which shape each connected client draws; a client that has said nothing draws v1. */
  private readonly audiences = new Map<string, ExtensionUISurfaceAudience>();
  /** What `oppiHost().surfaces(env)` hands a plugin: publish into this session's loop. */
  readonly publisher: SurfacePublisher;

  constructor(
    private readonly options: {
      /** The Session these surfaces belong to, stamped on every frame. */
      sessionId: string;
      /** Deliver one frame to one audience; the host decides which clients those are. */
      emit: (message: ServerMessage, audience: ExtensionUISurfaceAudience) => void;
    },
  ) {
    this.publisher = {
      publish: (surface, dispatch) => {
        this.publishFrom(surface, dispatch);
        return undefined;
      },
      dismiss: (surfaceId) => {
        this.dismiss(surfaceId);
        return undefined;
      },
    };
  }

  /** The shape this client draws. Declared once, on subscribe; v1 until then. */
  audience(clientId: string): ExtensionUISurfaceAudience {
    return this.audiences.get(clientId) ?? "v1-projection";
  }

  /**
   * Remember what a client says it draws, and answer with the frames that reconcile it: a client
   * that upgrades to composites is sent the clear for each projection it was handed at subscribe,
   * then the live surfaces. A client that repeats its declaration gets nothing.
   *
   * A declaration never takes composites back: the client that drew them is still drawing them, and
   * a list without the capability says nothing about that screen. Losing it after naming it is a
   * documented no-op, not a downgrade, so nothing is sent and the shape is unchanged.
   */
  declare(clientId: string, capabilities: readonly string[]): ServerMessage[] {
    const before = this.audience(clientId);
    const after = declaredAudience(capabilities);
    // A declaration never takes a shape back: the client that drew it is still drawing it, and a
    // list without the capability says nothing about that screen.
    if (AUDIENCE_RANK[after] < AUDIENCE_RANK[before]) return [];
    this.audiences.set(clientId, after);
    if (after === before) return [];
    const frames = after === "v1-projection" ? [] : this.projectionClears();
    frames.push(...this.messages(clientId));
    return frames;
  }

  /** A client that has gone: nothing else reads its declaration. */
  forget(clientId: string): void {
    this.audiences.delete(clientId);
  }

  /** Every live surface, in the shape this client draws, for a client that has just subscribed. */
  messages(clientId: string): ServerMessage[] {
    if (!this.runtime) return [];
    const audience = this.audience(clientId);
    return this.runtime
      .snapshot()
      .map((surface) =>
        audience !== "v1-projection" &&
        (audience === "blocks" || !extensionUISurfaceUsesBlocks(surface))
          ? buildExtensionUISurfaceMessage(this.options.sessionId, surface)
          : buildExtensionUINotificationMessage(extensionUISurfaceProjectionRequest(surface)),
      );
  }

  /**
   * Whether a tap could reach a surface now: this session has a surface loop. Answered before any
   * handler runs, so a socket decides reachability synchronously and does not hold its inbound
   * queue on the panel's own work.
   */
  canAct(): boolean {
    return this.runtime !== undefined;
  }

  /**
   * One tap from one client. False when this session has no surface loop (nothing to act on).
   * The runtime emits the answer and ends the round trip itself; the caller only reports whether
   * the tap reached a surface, and the work outlives that answer.
   */
  async act(message: ExtensionUISurfaceActionMessage, clientId: string): Promise<boolean> {
    if (!this.runtime) return false;
    await this.runtime.act(message, clientId, this.audience(clientId));
    return true;
  }

  /** A panel published or re-rendered: replace by key, coalesced, and bind its action handler. */
  private publishFrom(surface: ExtensionUISurface, dispatch: SurfaceDispatch | undefined): void {
    if (this.stopped) return;
    if (dispatch) this.dispatches.set(surface.id, dispatch);
    else this.dispatches.delete(surface.id);
    this.runtimeFor().publish(surface);
  }

  private dismiss(surfaceId: string): void {
    this.dispatches.delete(surfaceId);
    this.runtime?.dismiss(surfaceId);
  }

  /** The v1 widgets a client was handed at subscribe, cleared when it starts drawing composites. */
  private projectionClears(): ServerMessage[] {
    if (!this.runtime) return [];
    return this.runtime
      .snapshot()
      .map((surface) =>
        buildExtensionUINotificationMessage(extensionUISurfaceProjectionClearRequest(surface.id)),
      );
  }

  private runtimeFor(): ExtensionSurfaceRuntime {
    this.runtime ??= new ExtensionSurfaceRuntime({
      sessionId: this.options.sessionId,
      emit: this.options.emit,
      runAction: (request) => this.runAction(request),
      // A surface the runtime settles without the panel asking (its deadline, or teardown) takes
      // its handler with it; a re-publish binds one again.
      onSettled: (surfaceId) => this.dispatches.delete(surfaceId),
    });
    return this.runtime;
  }

  private runAction(
    request: ExtensionSurfaceActionRequest,
  ): Promise<ExtensionUISurfaceActionAnswer> {
    const dispatch = this.dispatches.get(request.surface.id);
    if (!dispatch)
      return Promise.resolve({
        error: {
          compositeId: request.compositeId,
          message: "This surface's action is no longer running.",
        },
      });
    return Promise.resolve(
      dispatch({
        compositeId: request.compositeId,
        actionId: request.actionId,
        ...(request.rowId === undefined ? {} : { rowId: request.rowId }),
        ...(request.nodeId === undefined ? {} : { nodeId: request.nodeId }),
        revision: request.revision,
        ...(request.values === undefined ? {} : { values: request.values }),
        signal: request.signal,
      }),
    );
  }

  /** Session teardown: every surface is left and cleared, every deadline and action abandoned. */
  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.dispatches.clear();
    this.audiences.clear();
    const runtime = this.runtime;
    this.runtime = undefined;
    runtime?.stop();
  }
}
