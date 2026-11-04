import { readExtensionUISurface } from "./extension-surface.js";
import type {
  ExtensionUIChecklistComposite,
  ExtensionUIDataTableComposite,
  ExtensionUISurface,
  ExtensionUISurfaceActionAnswer,
  ExtensionUISurfaceActionDefinition,
  ExtensionUISurfaceAtom,
  ExtensionUISurfaceHeader,
  ExtensionUISurfaceItemState,
  ExtensionUISurfaceSection,
  ExtensionUISurfaceState,
  ExtensionUISurfaceStateKind,
  ExtensionUISurfaceTone,
  ExtensionUIActionBarComposite,
  ExtensionUIStatusCardComposite,
} from "./types.js";

/**
 * `oppi/v1`: authoring a composable surface. The extension says *what* a surface is — a deploy
 * status card, an approval, a result table — and supplies data, actions, and the words for
 * loading, empty, and failure. The host owns layout, type, colour, Dynamic Type, and
 * accessibility, so there is no style field to get wrong.
 *
 * ```ts
 * const panel = surface<State>({
 *   id: "deploy",
 *   title: "Deploys",
 *   actions: { retry: { title: "Retry", role: "primary" }, logs: { title: "Logs" } },
 *   view: (state) => ({
 *     header: { title: `web → ${state.env}`, subtitle: state.sha },
 *     sections: [
 *       statusCard({ id: "status", header: { title: state.summary }, phase: state.phase,
 *         actions: state.phase === "error" ? ["retry", "logs"] : ["logs"],
 *         fallback: `Deploy ${state.phase}`, steps: state.gates }),
 *     ],
 *   }),
 * });
 *
 * panel.action("retry", async (state, ctx) => {
 *   await redeploy(state.sha);
 *   return panel.refresh(ctx);
 * });
 * ```
 *
 * A definition is typed and checked at author time: `render` throws a message naming the broken
 * rule rather than publishing something the phone would drop.
 */

/** One composite's shared presentation, as an author writes it. */
export interface SurfaceCompositeFields {
  id: string;
  header: ExtensionUISurfaceHeader;
  /** Default: content. `empty` and `failure` need their words. */
  state?: ExtensionUISurfaceState | ExtensionUISurfaceStateKind;
  /** Action ids from the surface's action table, in drawing order. */
  actions?: string[];
  /** The text an older client shows instead; a bare string is its own fallback. */
  fallback: string | { text: string };
  tone?: ExtensionUISurfaceTone;
}

export interface StatusCardFields extends SurfaceCompositeFields {
  phase: ExtensionUISurfaceItemState;
  steps?: Array<{
    id: string;
    title: string;
    state: ExtensionUISurfaceItemState;
    detail?: string;
    /** Atoms fill this slot only; a composite never nests another composite. */
    extra?: ExtensionUISurfaceAtom[];
  }>;
}

export interface ChecklistFields extends SurfaceCompositeFields {
  items: Array<{
    id: string;
    title: string;
    state: ExtensionUISurfaceItemState;
    detail?: string;
  }>;
}

export interface DataTableFields extends SurfaceCompositeFields {
  columns: Array<{ id: string; title: string; kind?: "text" | "number" }>;
  rows: Array<{
    id: string;
    cells: Record<string, string | number | null>;
    /** Row-level actions, from the surface's action table. */
    actions?: string[];
  }>;
  sort?: { columnId: string; descending?: boolean };
  selectedRowId?: string;
}

export type ActionBarFields = SurfaceCompositeFields;

function wireState(state: SurfaceCompositeFields["state"]): ExtensionUISurfaceState {
  if (state === undefined) return { kind: "content" };
  if (typeof state === "string") return { kind: state };
  return state;
}

function wireFallback(fallback: SurfaceCompositeFields["fallback"]): { text: string } {
  return typeof fallback === "string" ? { text: fallback } : fallback;
}

function shared<T extends SurfaceCompositeFields>(
  fields: T,
): {
  id: string;
  header: ExtensionUISurfaceHeader;
  state: ExtensionUISurfaceState;
  actions?: string[];
  fallback: { text: string };
  tone?: ExtensionUISurfaceTone;
} {
  return {
    id: fields.id,
    header: fields.header,
    state: wireState(fields.state),
    ...(fields.actions ? { actions: fields.actions } : {}),
    fallback: wireFallback(fields.fallback),
    ...(fields.tone ? { tone: fields.tone } : {}),
  };
}

/** A job's steps, phase, and next action. */
export function statusCard(fields: StatusCardFields): ExtensionUIStatusCardComposite {
  return {
    composite: "statusCard",
    ...shared(fields),
    phase: fields.phase,
    ...(fields.steps ? { steps: fields.steps } : {}),
  };
}

/** Plans and gates: per-item state with disclosure. */
export function checklist(fields: ChecklistFields): ExtensionUIChecklistComposite {
  return { composite: "checklist", ...shared(fields), items: fields.items };
}

/** Sortable columns, row actions, selection. */
export function dataTable(fields: DataTableFields): ExtensionUIDataTableComposite {
  return {
    composite: "dataTable",
    ...shared(fields),
    columns: fields.columns,
    rows: fields.rows,
    ...(fields.sort ? { sort: fields.sort } : {}),
    ...(fields.selectedRowId ? { selectedRowId: fields.selectedRowId } : {}),
  };
}

/** The surface's actions: primary, overflow, and per-row variants. */
export function actionBar(fields: ActionBarFields): ExtensionUIActionBarComposite {
  return { composite: "actionBar", ...shared(fields) };
}

export interface SurfaceView {
  header: ExtensionUISurfaceHeader;
  sections: ExtensionUISurfaceSection[];
}

/**
 * Where a published surface goes: the conversation's surface loop, bound by the host. A handler
 * receives the same object, so `panel.refresh(ctx)` re-renders after its work.
 */
export interface SurfaceContext {
  readonly surfaces: SurfacePublisher;
}

/** One tap on a published surface, as the host hands it back to the panel that offered it. */
export interface SurfaceTap {
  readonly compositeId: string;
  readonly actionId: string;
  /** The row a row action belongs to; absent for a surface-level action. */
  readonly rowId?: string;
  /** The revision the client acted on. */
  readonly revision: number;
  readonly values?: Record<string, string | number | boolean>;
  /** Aborted when the surface settles: dismissed, replaced by nothing, or past its deadline. */
  readonly signal: AbortSignal;
}

/**
 * One action handler, bound to the panel and to the state it last published. Every publish hands
 * the host one of these, so a tap runs the extension's own code long after the tool call that
 * published the surface returned, and its answer reaches the card the tap came from.
 */
export type SurfaceDispatch = (
  tap: SurfaceTap,
) => ExtensionUISurfaceActionAnswer | Promise<ExtensionUISurfaceActionAnswer>;

export interface SurfacePublisher {
  /**
   * Publish or replace by key; the host coalesces repeats of a persistent surface. `dispatch` is
   * how the host runs this panel's actions while the surface lives.
   */
  publish(surface: ExtensionUISurface, dispatch?: SurfaceDispatch): unknown;
  /** The surface is done: its actions are cancelled and the client clears it. */
  dismiss(surfaceId: string): unknown;
}

export interface SurfaceDefinition<State> {
  id: string;
  title: string;
  placement?: ExtensionUISurface["placement"];
  /** `persistent` (default) survives turns; `oneShot` needs a deadline at publish time. */
  lifecycle?: ExtensionUISurface["lifecycle"];
  /** The words the host uses for an empty surface, when a view has nothing to show. */
  empty?: { title: string; message: string };
  /** Every action id any section offers. */
  actions?: Record<string, ExtensionUISurfaceActionDefinition>;
  /**
   * What an older client shows for the whole surface: the words for this state, or a fixed line.
   * Default: the view's header title. A per-state line is the author's own, since only the author
   * knows how to sum up its rows.
   */
  fallback?: string | ((state: State) => string);
  view: (state: State) => SurfaceView;
}

/** What an action handler may answer: a new surface, a patch, or nothing visible. */
export type SurfaceActionReturn =
  ExtensionUISurfaceActionAnswer | ExtensionUISurface | undefined | void;

export interface SurfaceActionInvocation<State> {
  readonly state: State;
  readonly compositeId: string;
  readonly actionId: string;
  readonly rowId?: string;
  readonly values?: Record<string, string | number | boolean>;
  readonly signal: AbortSignal;
  readonly ctx: SurfaceContext;
}

export type SurfaceActionHandler<State> = (
  state: State,
  invocation: SurfaceActionInvocation<State>,
) => SurfaceActionReturn | Promise<SurfaceActionReturn>;

export interface Surface<State> {
  readonly id: string;
  readonly title: string;
  /** The wire surface for `state`; throws a message naming the rule it breaks. */
  render(state: State): ExtensionUISurface;
  publish(ctx: SurfaceContext, state: State): ExtensionUISurface;
  /** Re-render the last published state, for an action that changed the world. */
  refresh(ctx: SurfaceContext): ExtensionUISurface;
  /** The last published state, before anything is published. */
  current(): State | undefined;
  end(ctx: SurfaceContext): void;
  /** `{ kind: "empty" }` with the definition's words, for a view with nothing to show. */
  emptyState(): ExtensionUISurfaceState;
  action(id: string, handler: SurfaceActionHandler<State>): Surface<State>;
  handlers(): ReadonlyMap<string, SurfaceActionHandler<State>>;
  /** This panel's handler for one tap, over the state it last published. */
  dispatch(ctx: SurfaceContext): SurfaceDispatch;
}

export interface SurfaceOptions<State> {
  /** A one-shot surface's deadline, resolved when the view is rendered. */
  deadline?: (state: State) => number | undefined;
}

export function surface<State>(
  definition: SurfaceDefinition<State>,
  options: SurfaceOptions<State> = {},
): Surface<State> {
  const handlers = new Map<string, SurfaceActionHandler<State>>();
  let published: State | undefined;
  let rendered = false;

  function render(state: State): ExtensionUISurface {
    const view = definition.view(state);
    const timeoutAt = definition.lifecycle === "oneShot" ? options.deadline?.(state) : undefined;
    const declared = definition.fallback;
    const fallback =
      typeof declared === "function" ? declared(state) : (declared ?? view.header.title);
    const candidate = {
      version: 2,
      id: definition.id,
      title: definition.title,
      placement: definition.placement ?? { kind: "strip" },
      lifecycle: definition.lifecycle ?? "persistent",
      ...(timeoutAt === undefined ? {} : { timeoutAt }),
      header: view.header,
      sections: view.sections,
      actions: definition.actions ?? {},
      fallback: { text: fallback },
      // The wire requires a revision, and the host stamps the real one when it publishes.
      revision: 1,
    };
    const read = readExtensionUISurface(candidate);
    if ("problem" in read) throw new Error(`surface "${definition.id}": ${read.problem}`);
    return read.surface;
  }

  const panel: Surface<State> = {
    id: definition.id,
    title: definition.title,
    render,
    publish(ctx, state) {
      const wire = render(state);
      published = state;
      rendered = true;
      ctx.surfaces.publish(wire, panel.dispatch(ctx));
      return wire;
    },
    refresh(ctx) {
      if (!rendered) throw new Error(`surface "${definition.id}": nothing has been published`);
      const wire = render(published as State);
      ctx.surfaces.publish(wire, panel.dispatch(ctx));
      return wire;
    },
    current: () => published,
    end(ctx) {
      rendered = false;
      published = undefined;
      ctx.surfaces.dismiss(definition.id);
    },
    emptyState: () => ({
      kind: "empty",
      title: definition.empty?.title ?? `No ${definition.title.toLowerCase()} yet`,
      message: definition.empty?.message ?? "There is nothing to show.",
    }),
    action(id, handler) {
      handlers.set(id, handler);
      return panel;
    },
    handlers: () => handlers,
    dispatch(ctx) {
      return async (tap) => {
        const handler = handlers.get(tap.actionId);
        // The surface is gone from this panel, or the id was never offered: nothing ran, and the
        // card that asked says so in the host's words rather than pretending it worked.
        if (!handler || !rendered)
          return {
            error: { compositeId: tap.compositeId, message: "This action is not available." },
          };
        const state = published as State;
        const answer = await handler(state, {
          state,
          compositeId: tap.compositeId,
          actionId: tap.actionId,
          ...(tap.rowId === undefined ? {} : { rowId: tap.rowId }),
          ...(tap.values === undefined ? {} : { values: tap.values }),
          signal: tap.signal,
          ctx,
        });
        return surfaceActionAnswer(answer, tap.compositeId);
      };
    },
  };
  return panel;
}

/**
 * Map what a handler returned onto the wire answer. A surface is a whole replacement; a patch,
 * a replacement, or an error passes through; nothing visible is an empty patch the host drops.
 */
export function surfaceActionAnswer(
  result: SurfaceActionReturn,
  compositeId: string,
): ExtensionUISurfaceActionAnswer {
  if (!result) return { patch: {} };
  if ("error" in result && result.error)
    return { error: { ...result.error, compositeId: result.error.compositeId || compositeId } };
  if ("patch" in result && result.patch) return { patch: result.patch };
  if ("surface" in result && result.surface) return { surface: result.surface };
  if ("version" in result) return { surface: result };
  return { patch: {} };
}

export type { ExtensionUISurfaceStateKind };
