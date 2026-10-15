/**
 * `oppi/durable`: the host API a durable extension imports for what only Oppi provides. The
 * extension itself is plain pi-durable (`export default defineExtension(...)`), and its package
 * declares the entry in `package.json` `oppi.durable`. The loader aliases this module, and
 * pi-durable, chord, pi-ai, and typebox, to the server's own copies, as upstream's plugin loader
 * resolved its plugin API.
 *
 * Every package entry gets its own evaluation of this module (the loader keeps no module cache,
 * so a reload re-reads everything), so nothing here may keep state: documents are matched by
 * kind, not by object.
 * @public
 */

/**
 * Oppi's extension UI: dialogs (`requestUI`), persistent notifications, and transcript cards,
 * kept in the conversation's `oppi.extension-ui` and `oppi.input-cards` documents and shown by
 * the server's generic projection.
 */
export {
  DurableInputCards,
  DurableUI,
  requestUI,
  type UINotification,
  type UIRequest,
  type UIResponse,
  type UIState,
} from "../extensions/durable/durable-ui.js";
