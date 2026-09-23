import {
  DictationDictionaryStore,
  DictionaryError,
} from "../storage/dictation-dictionary-store.js";
import { isDictationStreamEnabled, resolveAsrProvider } from "../dictation-types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/** Authenticated on both owner Unix socket and paired HTTPS; never log phrase bodies. */
export function createDictationDictionaryRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    const match = /^\/dictation\/dictionary\/(global|workspaces\/([^/]+))$/.exec(path);
    if (!match) return false;
    const store = new DictationDictionaryStore(ctx.storage.getDataDir());
    let workspaceId: string | null = null;
    try {
      if (match[2]) {
        try {
          workspaceId = decodeURIComponent(match[2]);
        } catch {
          throw new DictionaryError(400, "Invalid workspace id");
        }
        if (!workspaceId || !ctx.storage.getWorkspace(workspaceId)) {
          throw new DictionaryError(404, "Workspace not found");
        }
      }
      let list;
      if (method === "GET") list = store.get(workspaceId);
      else if (method === "POST") {
        const body = await helpers.parseBody<unknown>(req, { maxBytes: 160_000 });
        if (
          !body ||
          typeof body !== "object" ||
          Array.isArray(body) ||
          Object.keys(body).length !== 1 ||
          !("phrase" in body || "phrases" in body)
        )
          throw new DictionaryError(400, "Expected phrase or phrases");
        list = store.addMany(workspaceId, "phrase" in body ? [body.phrase] : body.phrases);
      } else if (method === "PUT") {
        const body = await helpers.parseBody<unknown>(req, { maxBytes: 160_000 });
        if (
          !body ||
          typeof body !== "object" ||
          Array.isArray(body) ||
          Object.keys(body).length !== 2 ||
          !("revision" in body) ||
          !("phrases" in body)
        ) {
          throw new DictionaryError(400, "Expected revision and phrases");
        }
        list = store.replace(workspaceId, body.revision, body.phrases);
      } else if (method === "DELETE") {
        const body = await helpers.parseBody<unknown>(req, { maxBytes: 2048 });
        if (
          body &&
          typeof body === "object" &&
          !Array.isArray(body) &&
          Object.keys(body).length === 1 &&
          "phrase" in body
        ) {
          list = store.remove(workspaceId, body.phrase);
        } else if (
          workspaceId !== null &&
          body &&
          typeof body === "object" &&
          !Array.isArray(body) &&
          Object.keys(body).length === 0
        ) {
          list = store.forget(workspaceId);
        } else
          throw new DictionaryError(400, "Expected phrase, or empty object to forget workspace");
      } else {
        helpers.error(res, 405, "Method not allowed");
        return true;
      }
      const asr = ctx.storage.getConfig().asr;
      helpers.json(res, {
        ...list,
        provider: isDictationStreamEnabled(asr) ? resolveAsrProvider(asr) : null,
      });
    } catch (error) {
      // Neither text nor raw decode errors may reach logs or responses.
      helpers.error(
        res,
        error instanceof DictionaryError ? error.status : 400,
        error instanceof DictionaryError ? error.message : "Invalid dictionary request",
      );
    }
    return true;
  };
}
