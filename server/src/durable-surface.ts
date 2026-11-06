import { readExtensionUISurface } from "./extension-surface.js";
import type {
  ExtensionUIBlocksComposite,
  ExtensionUIChecklistComposite,
  ExtensionUIDataTableComposite,
  ExtensionUISurface,
  ExtensionUISurfaceActionAnswer,
  ExtensionUISurfaceActionDefinition,
  ExtensionUISurfaceAtom,
  ExtensionUISurfaceElapsedFormat,
  ExtensionUISurfaceHeader,
  ExtensionUISurfaceItemState,
  ExtensionUISurfaceNode,
  ExtensionUISurfaceNodeAction,
  ExtensionUISurfaceNodeAlign,
  ExtensionUISurfaceNodeSpacing,
  ExtensionUISurfacePill,
  ExtensionUISurfacePillNode,
  ExtensionUISurfaceTextStyle,
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

/**
 * A tree of primitives: the open composite. The host still owns layout, type, colour, and
 * accessibility; a node names a `tone`, a `style`, and a spacing step, and nothing else. Unlike
 * the closed composites the header is optional, so a tree can be the whole region.
 */
export interface BlocksFields extends Omit<SurfaceCompositeFields, "header"> {
  header?: ExtensionUISurfaceHeader;
  body: ExtensionUISurfaceNode;
}

/** A node's own tap: an action id from the surface's table, plus the values it sends. */
export interface NodeActionFields {
  id: string;
  values?: Record<string, string | number | boolean>;
  pending?: { title?: string; disabled?: string[] };
}

export interface TextNodeFields {
  id?: string;
  text: string;
  style?: ExtensionUISurfaceTextStyle;
  tone?: ExtensionUISurfaceTone;
  /** The active item of a segmented set of tappable text. */
  selected?: boolean;
  disabled?: boolean;
  action?: NodeActionFields;
}

export interface BadgeNodeFields {
  id?: string;
  text: string;
  tone?: ExtensionUISurfaceTone;
  /** An SF Symbol from the host's allow-list, drawn before the text. */
  icon?: string;
  selected?: boolean;
  disabled?: boolean;
  action?: NodeActionFields;
}

export interface RowNodeFields {
  id?: string;
  children: ExtensionUISurfaceNode[];
  spacing?: ExtensionUISurfaceNodeSpacing;
  align?: ExtensionUISurfaceNodeAlign;
  selected?: boolean;
  disabled?: boolean;
  action?: NodeActionFields;
}

export interface StackNodeFields {
  id?: string;
  children: ExtensionUISurfaceNode[];
  spacing?: ExtensionUISurfaceNodeSpacing;
  disabled?: boolean;
  action?: NodeActionFields;
}

/** A titled region that folds away; the host owns the disclosure control. */
export interface GroupNodeFields {
  id?: string;
  title: string;
  collapsed?: boolean;
  children: ExtensionUISurfaceNode[];
}

export interface TableNodeFields {
  id?: string;
  columns: string[];
  rows: Array<{ id?: string; cells: Array<string | number | null>; actions?: NodeActionFields[] }>;
  truncated?: boolean;
}

export interface ButtonNodeFields {
  id: string;
  title: string;
  role?: "primary" | "secondary" | "destructive";
  icon?: string;
  selected?: boolean;
  disabled?: boolean;
  action: NodeActionFields;
}

export interface ToggleNodeFields {
  id: string;
  title: string;
  value: boolean;
  disabled?: boolean;
  action: NodeActionFields;
}

export interface MenuNodeFields {
  id: string;
  title?: string;
  icon?: string;
  disabled?: boolean;
  items: Array<{
    id?: string;
    title: string;
    role?: "primary" | "secondary" | "destructive";
    action: NodeActionFields;
  }>;
}

/** What a pill shows: one line of inline facts, in the order it lists them. */
export interface PillFields {
  /** Text, badges, icons, elapsed counts, and progress: the builders above return one node type, and the host's validator rejects the rest. */
  content: ExtensionUISurfaceNode[];
  /** `drawer` (the default) opens the panel; an action sends that action instead. */
  tap?: "drawer" | NodeActionFields;
}

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

/**
 * A tree of primitives, for a design the closed composites do not cover. Node ids are unique
 * across the whole surface — every tree and the pill share one namespace, because a tap names one
 * id and the section it sits in is not part of that name.
 */
export function blocks(fields: BlocksFields): ExtensionUIBlocksComposite {
  const { header, body, ...rest } = fields;
  const base = shared({ ...rest, ...(header ? { header } : {}) } as SurfaceCompositeFields);
  return {
    composite: "blocks",
    ...(header ? { header: base.header } : {}),
    id: base.id,
    state: base.state,
    ...(base.actions ? { actions: base.actions } : {}),
    fallback: base.fallback,
    ...(base.tone ? { tone: base.tone } : {}),
    body,
  };
}

function wireNodeAction(action: NodeActionFields): ExtensionUISurfaceNodeAction {
  return {
    id: action.id,
    ...(action.values ? { values: action.values } : {}),
    ...(action.pending ? { pending: action.pending } : {}),
  };
}

/**
 * A node's own state flags, written only when the author named one: `false` is a state the host
 * has to be told about, exactly as `true` is.
 */
function nodeFlags(fields: { selected?: boolean; disabled?: boolean }): {
  selected?: boolean;
  disabled?: boolean;
} {
  return {
    ...(fields.selected === undefined ? {} : { selected: fields.selected }),
    ...(fields.disabled === undefined ? {} : { disabled: fields.disabled }),
  };
}

/** Children side by side: facts in one line, or a row of controls. */
export function row(fields: RowNodeFields): ExtensionUISurfaceNode {
  return {
    type: "row",
    ...(fields.id ? { id: fields.id } : {}),
    children: fields.children,
    ...(fields.spacing ? { spacing: fields.spacing } : {}),
    ...(fields.align ? { align: fields.align } : {}),
    ...nodeFlags(fields),
    ...(fields.action ? { action: wireNodeAction(fields.action) } : {}),
  };
}

/** Children one above another, at a spacing step the host owns. */
export function stack(fields: StackNodeFields): ExtensionUISurfaceNode {
  return {
    type: "stack",
    ...(fields.id ? { id: fields.id } : {}),
    children: fields.children,
    ...(fields.spacing ? { spacing: fields.spacing } : {}),
    ...nodeFlags(fields),
    ...(fields.action ? { action: wireNodeAction(fields.action) } : {}),
  };
}

/** A titled region the reader can fold away, for the part of a panel that is not the point. */
export function group(fields: GroupNodeFields): ExtensionUISurfaceNode {
  return {
    type: "group",
    ...(fields.id ? { id: fields.id } : {}),
    title: fields.title,
    ...(fields.collapsed === undefined ? {} : { collapsed: fields.collapsed }),
    children: fields.children,
  };
}

/** Body copy, a headline, a caption, or monospace. */
export function text(fields: TextNodeFields): ExtensionUISurfaceNode {
  return {
    type: "text",
    ...(fields.id ? { id: fields.id } : {}),
    text: fields.text,
    ...(fields.style ? { style: fields.style } : {}),
    ...(fields.tone ? { tone: fields.tone } : {}),
    ...nodeFlags(fields),
    ...(fields.action ? { action: wireNodeAction(fields.action) } : {}),
  };
}

/** A short status word: "running", "2 of 4". */
export function badge(fields: BadgeNodeFields): ExtensionUISurfaceNode {
  return {
    type: "badge",
    ...(fields.id ? { id: fields.id } : {}),
    text: fields.text,
    ...(fields.tone ? { tone: fields.tone } : {}),
    ...(fields.icon ? { icon: fields.icon } : {}),
    ...nodeFlags(fields),
    ...(fields.action ? { action: wireNodeAction(fields.action) } : {}),
  };
}

/** Prose the host renders as Markdown, for the words a line of text is too small for. */
export function markdown(fields: { id?: string; markdown: string }): ExtensionUISurfaceNode {
  return {
    type: "markdown",
    ...(fields.id ? { id: fields.id } : {}),
    markdown: fields.markdown,
  };
}

/** A bar, line, or pie the host draws and clamps. */
export function chart(fields: {
  id?: string;
  kind: "bar" | "line" | "pie";
  title?: string;
  labels: string[];
  series: Array<{ name?: string; values: number[] }>;
  truncated?: boolean;
}): ExtensionUISurfaceNode {
  return {
    type: "chart",
    ...(fields.id ? { id: fields.id } : {}),
    kind: fields.kind,
    ...(fields.title ? { title: fields.title } : {}),
    labels: fields.labels,
    series: fields.series,
    ...(fields.truncated === undefined ? {} : { truncated: fields.truncated }),
  };
}

/** A fixed-width excerpt: a command, a log tail, a snippet. */
export function code(fields: {
  id?: string;
  language?: string;
  text: string;
}): ExtensionUISurfaceNode {
  return {
    type: "code",
    ...(fields.id ? { id: fields.id } : {}),
    ...(fields.language ? { language: fields.language } : {}),
    text: fields.text,
  };
}

/** A rule between two parts of a panel. */
export function divider(fields: { id?: string } = {}): ExtensionUISurfaceNode {
  return { type: "divider", ...(fields.id ? { id: fields.id } : {}) };
}

/** Intentional white space, at the host's one of three steps. */
export function spacer(
  fields: {
    id?: string;
    size?: "small" | "medium" | "large";
  } = {},
): ExtensionUISurfaceNode {
  return {
    type: "spacer",
    ...(fields.id ? { id: fields.id } : {}),
    ...(fields.size ? { size: fields.size } : {}),
  };
}

/** An SF Symbol from the host's allow-list. */
export function icon(fields: {
  id?: string;
  name: string;
  tone?: ExtensionUISurfaceTone;
}): ExtensionUISurfaceNode {
  return {
    type: "icon",
    ...(fields.id ? { id: fields.id } : {}),
    name: fields.name,
    ...(fields.tone ? { tone: fields.tone } : {}),
  };
}

/**
 * A live count from `since` (epoch milliseconds) that the client ticks once a second, so a
 * running timer needs no republish. `clock` (the default) reads 4:05 or 1:02:05; `short` reads
 * 42s, 5m, or 1h 5m.
 */
export function elapsed(fields: {
  id?: string;
  since: number;
  format?: ExtensionUISurfaceElapsedFormat;
  style?: ExtensionUISurfaceTextStyle;
  tone?: ExtensionUISurfaceTone;
}): ExtensionUISurfaceNode {
  return {
    type: "elapsed",
    ...(fields.id ? { id: fields.id } : {}),
    since: fields.since,
    ...(fields.style ? { style: fields.style } : {}),
    ...(fields.tone ? { tone: fields.tone } : {}),
    ...(fields.format ? { format: fields.format } : {}),
  };
}

/** A bar or a ring; no value is an indeterminate spinner's worth of meaning. */
export function progress(fields: {
  id?: string;
  value?: number;
  kind?: "bar" | "ring";
  label?: string;
  tone?: ExtensionUISurfaceTone;
}): ExtensionUISurfaceNode {
  return {
    type: "progress",
    ...(fields.id ? { id: fields.id } : {}),
    ...(fields.value === undefined ? {} : { value: fields.value }),
    ...(fields.kind ? { kind: fields.kind } : {}),
    ...(fields.label ? { label: fields.label } : {}),
    ...(fields.tone ? { tone: fields.tone } : {}),
  };
}

/** Fixed pairs: a summary block, not a control. */
export function keyValue(fields: {
  id?: string;
  pairs: Array<{ key: string; value: string; tone?: ExtensionUISurfaceTone }>;
}): ExtensionUISurfaceNode {
  return {
    type: "keyValue",
    ...(fields.id ? { id: fields.id } : {}),
    pairs: fields.pairs,
  };
}

/** A grid the host draws and clamps, with an optional action per row. */
export function table(fields: TableNodeFields): ExtensionUISurfaceNode {
  return {
    type: "table",
    ...(fields.id ? { id: fields.id } : {}),
    columns: fields.columns,
    rows: fields.rows.map((entry) => ({
      ...(entry.id ? { id: entry.id } : {}),
      cells: entry.cells,
      ...(entry.actions ? { actions: entry.actions.map(wireNodeAction) } : {}),
    })),
    ...(fields.truncated === undefined ? {} : { truncated: fields.truncated }),
  };
}

/** The one verb a region offers, drawn the way the host draws buttons. */
export function button(fields: ButtonNodeFields): ExtensionUISurfaceNode {
  return {
    type: "button",
    id: fields.id,
    title: fields.title,
    ...(fields.role ? { role: fields.role } : {}),
    ...(fields.icon ? { icon: fields.icon } : {}),
    ...nodeFlags(fields),
    action: wireNodeAction(fields.action),
  };
}

/** A switch: its tap sends `values: { value: boolean }` with its action. */
export function toggle(fields: ToggleNodeFields): ExtensionUISurfaceNode {
  return {
    type: "toggle",
    id: fields.id,
    title: fields.title,
    value: fields.value,
    ...nodeFlags(fields),
    action: wireNodeAction(fields.action),
  };
}

/** Overflow verbs behind one control. */
export function menu(fields: MenuNodeFields): ExtensionUISurfaceNode {
  return {
    type: "menu",
    id: fields.id,
    ...(fields.title ? { title: fields.title } : {}),
    ...(fields.icon ? { icon: fields.icon } : {}),
    ...nodeFlags(fields),
    items: fields.items.map((item) => ({
      ...(item.id ? { id: item.id } : {}),
      title: item.title,
      ...(item.role ? { role: item.role } : {}),
      action: wireNodeAction(item.action),
    })),
  };
}

/** The strip's own one-line summary; without one the host derives it from the header. */
export function pill(fields: PillFields): ExtensionUISurfacePill {
  return {
    content: { type: "row", children: fields.content as ExtensionUISurfacePillNode[] },
    tap: fields.tap === undefined || fields.tap === "drawer" ? "drawer" : { action: fields.tap },
  };
}

export interface SurfaceView {
  header: ExtensionUISurfaceHeader;
  /** The strip's one-line summary; without one the host derives it from the header. */
  pill?: ExtensionUISurfacePill;
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
  /** The blocks node that offered the action; absent for a section-level action. */
  readonly nodeId?: string;
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
  readonly nodeId?: string;
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
      ...(view.pill ? { pill: view.pill } : {}),
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
          ...(tap.nodeId === undefined ? {} : { nodeId: tap.nodeId }),
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
