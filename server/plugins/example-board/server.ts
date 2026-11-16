/**
 * Example plugin: a panel with a pill, a drawer, and a button that saves state.
 *
 * `example_board_add` puts an item on the chat's board. The board shows as a pill above the
 * composer ("Board · 2 open"); tapping it opens a drawer that lists the items, each open one with
 * a Done button. Done marks the item in the plugin's document, so the change survives a server
 * restart, and the panel comes back by itself when the chat opens again.
 *
 * It ships off. Turn it on with `oppi extensions enable example-board`; see README.md.
 */
import {
  badge,
  blocks,
  button,
  defineDoc,
  defineExtension,
  defineFacet,
  defineTool,
  Extensions,
  oppiHost,
  pill,
  row,
  stack,
  surface,
  text,
} from "oppi/v1";
import { obj, str } from "oppi/v1/schema";

type Item = { id: string; title: string; done: boolean };
type Board = { items: Item[] };

/**
 * The board. `scope: "conversation"` keeps one board per conversation, the same unit a panel
 * belongs to: each chat, and each subagent it starts, has its own. A conversation document also
 * says what a rewind keeps (`history`) and what a fork starts with (`fork`).
 */
const BoardDoc = defineDoc<Board>({
  kind: "oppi.example.board",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "current",
  initial: () => ({ items: [] }),
  checkpointWhen: () => false,
});

/** A drawer's list holds at most 12 rows; the board shows the newest. */
const SHOWN = 12;

/**
 * One panel object for every chat: Oppi keeps what each chat's panel shows apart. `load` reads
 * the chat's board, and is how the panel is drawn after any change and when the chat attaches.
 */
const panel = surface<Board>({
  id: "example-board",
  title: "Board",
  actions: { done: { title: "Done", role: "primary", pending: { title: "Saving…" } } },
  load: async (conversation, context) => {
    const board = await conversation.snapshot(BoardDoc, conversation.conversationId, context);
    // No items, no panel: `undefined` ends it.
    return board && board.items.length > 0 ? { items: [...board.items] } : undefined;
  },
  view: ({ items }) => {
    const open = items.filter((item) => !item.done).length;
    return {
      header: { title: "Board", subtitle: `${open} open · ${items.length - open} done` },
      pill: pill({
        content: [
          text({ text: "Board", style: "headline" }),
          badge({ text: `${open} open`, tone: open > 0 ? "accent" : "success" }),
        ],
      }),
      sections: [
        blocks({
          id: "items",
          fallback: `Board: ${open} open`,
          body: stack({
            id: "list",
            children: items.slice(-SHOWN).map((item) =>
              row({
                id: `row:${item.id}`,
                align: "spread",
                children: [
                  text({ id: `title:${item.id}`, text: item.title }),
                  item.done
                    ? badge({ id: `done:${item.id}`, text: "Done", tone: "success" })
                    : button({
                        id: `mark:${item.id}`,
                        title: "Done",
                        action: { id: "done", values: { item: item.id } },
                      }),
                ],
              }),
            ),
          }),
        }),
      ],
    };
  },
});

// A tap runs outside any tool call. `conversation` is the tapped chat's: commit there, as a tool
// commits through `api`, then draw the panel from the saved board.
panel.action("done", async (_state, { values, conversation, context, ctx }) => {
  await conversation.commit(async (tx) => {
    const board = await tx.doc(BoardDoc, conversation.conversationId);
    const item = board.items.find((candidate) => candidate.id === values?.item);
    if (item) item.done = true;
  }, context);
  await panel.sync(ctx, context);
});

const add = defineTool({
  name: "example_board_add",
  description: "Add an item to the board panel of this chat.",
  parameters: obj({ title: str() }),
  async execute(args, api, context) {
    const count = await api.commit(async (tx) => {
      const board = await tx.doc(BoardDoc, api.conversationId);
      board.items.push({ id: `item-${board.items.length + 1}`, title: args.title, done: false });
      return board.items.length;
    }, context);
    // Undefined while the chat has no live Session to draw into (a bare Harness, a test).
    const surfaces = oppiHost().surfaces(api.env);
    if (surfaces) await panel.sync({ surfaces }, context);
    return {
      output: [{ type: "text", text: `Added "${args.title}". ${count} item(s) on the board.` }],
    };
  },
});

const ExampleBoard = defineExtension({
  name: "example-board",
  runtimes: ["host", "sandbox"],
  tools: [add],
  // The panels Oppi draws again when a chat attaches, after a server restart too.
  surfaces: [panel],
});

export default defineFacet((_host, self) => self.contribute(Extensions, ExampleBoard));
