/**
 * Example plugin: two tools and a document that keeps their state.
 *
 * `example_bookmark_add` saves a link and `example_bookmark_list` lists the saved ones. The links
 * live in a pi-durable document in the chat's durable store, so they survive a server restart
 * with no saving code in the plugin.
 *
 * It ships off. Turn it on with `oppi extensions enable example-bookmarks`; see README.md.
 */
import { defineDoc, defineExtension, defineFacet, defineTool, Extensions } from "oppi/v1";
import { obj, opt, str } from "oppi/v1/schema";

// A `type`, not an `interface`: a document's value must be JSON, and TypeScript checks an
// interface against that only with an index signature.
type Bookmark = {
  url: string;
  title: string;
  /** Milliseconds since the epoch, from `api.now()`. */
  addedAt: number;
};

/**
 * The saved links. `scope: "session"` is one pi-durable Session, and in Oppi that is one chat:
 * the chat's conversations (forks, and the subagents it starts) share it, and another chat has
 * its own. `scope: "conversation"` would keep one list per conversation instead.
 */
const Bookmarks = defineDoc<{ items: Bookmark[] }>({
  kind: "oppi.example.bookmarks",
  version: 1,
  scope: "session",
  initial: () => ({ items: [] }),
  // Required. `false` stores each change as a delta; a small document never needs a full copy.
  checkpointWhen: () => false,
});

const add = defineTool({
  name: "example_bookmark_add",
  description: "Save a link as a bookmark, with an optional title.",
  parameters: obj({ url: str(), title: opt(str()) }),
  async execute(args, api, context) {
    // A commit is one transaction: the document change is stored with the tool call, or not at all.
    const count = await api.commit(async (tx) => {
      const doc = await tx.doc(Bookmarks);
      doc.items.push({ url: args.url, title: args.title ?? args.url, addedAt: api.now() });
      return doc.items.length;
    }, context);
    return {
      output: [{ type: "text", text: `Saved ${args.url}. ${count} bookmark(s) in total.` }],
    };
  },
});

const list = defineTool({
  name: "example_bookmark_list",
  description: "List the saved bookmarks.",
  parameters: obj({}),
  // A read: safe to run again if the server stops during the call.
  replay: "safe",
  async execute(_args, api, context) {
    // A snapshot reads without a transaction. It is undefined until the first write.
    const items = (await api.snapshot(Bookmarks, context))?.items ?? [];
    const text =
      items.length === 0
        ? "No bookmarks yet."
        : items.map((item, index) => `${index + 1}. ${item.title} <${item.url}>`).join("\n");
    return { output: [{ type: "text", text }] };
  },
});

const ExampleBookmarks = defineExtension({
  name: "example-bookmarks",
  // Nothing here touches files or runs commands, so sandbox sessions can use it too.
  runtimes: ["host", "sandbox"],
  tools: [add, list],
});

export default defineFacet((_host, self) => self.contribute(Extensions, ExampleBookmarks));
