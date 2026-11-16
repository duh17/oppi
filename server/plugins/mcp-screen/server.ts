import { sleep } from "@earendil-works/chord";
import type { Context } from "@earendil-works/chord/context";
import {
  defineFacet,
  defineScreen,
  oppiHost,
  Sidebar,
  SCREEN_REFRESH_ACTION,
  type OppiMcpHost,
  type ScreenActArgs,
  type ScreenActResult,
} from "oppi/v1";
import type { McpAuthFlowSnapshot, McpExposure } from "../../src/types/mcp.js";
import {
  addPage,
  addRequest,
  listPage,
  MCP_SCREEN_ID,
  MCP_SIDEBAR_ENTRY,
  mcpScopeOf,
  serverPage,
  signInPage,
  type McpProbe,
} from "./pages.js";

/**
 * MCP Servers as a plugin sidebar entry: a scope's list (the global servers in the sidebar, a
 * host workspace's own from its Workspace Settings), each server's detail, the Add form, and the
 * host's OAuth sign-in, drawn by the app's generic list screen. Each page is a Chord object whose
 * document is a projection of `oppiHost().mcp()`: probed when the page is opened and after each
 * change, and followed once a second while a sign-in is live. It contributes no extension:
 * sessions get their MCP tools from the server's MCP management, not from this plugin.
 */
const Screen = defineScreen(MCP_SCREEN_ID);

/** How often a page checks for a change made elsewhere and re-reads a live sign-in. */
const POLL_MS = 1000;

/**
 * Counts the changes made through any page of this screen, so the other open pages (the list
 * under a server's detail) probe again. Module state: a reload starts it over, which only probes.
 */
let changes = 0;

const failure = (error: unknown): ScreenActResult => ({
  ok: false,
  message: error instanceof Error ? error.message : String(error),
});

function mcp(): OppiMcpHost {
  const host = oppiHost().mcp();
  if (!host) throw new Error("MCP management is not available on this server.");
  return host;
}

export default defineFacet((host, self) => {
  self.contribute(Sidebar, { ...MCP_SIDEBAR_ENTRY, screen: Screen });

  host.serve(Screen.contract, ({ scope: screenScope, page }, self) => {
    const doc = self.state(Screen.document);
    const scope = mcpScopeOf(screenScope);
    let probe: McpProbe = {};
    let flowId: string | undefined;

    const render = (context: Context): Promise<void> => {
      const value =
        page === "list"
          ? listPage(probe)
          : page === "add"
            ? addPage(probe)
            : page === "signin"
              ? signInPage(flowId ? readFlow(flowId) : mcp().auth.active())
              : page.startsWith("server/")
                ? serverPage(probe, page.slice("server/".length))
                : ({ gone: true } as const);
      return doc.change((draft) => {
        for (const key of Object.keys(draft)) delete (draft as Record<string, unknown>)[key];
        Object.assign(draft, value);
      }, context);
    };

    const readFlow = (id: string): McpAuthFlowSnapshot | undefined => {
      try {
        return mcp().auth.get(id);
      } catch {
        return undefined;
      }
    };

    let seenChanges = changes;
    /** `cached`: the last known status at once (a page opening), not Pi's live probe. */
    const reprobe = async (context: Context, cached = false): Promise<void> => {
      seenChanges = changes;
      if (page === "signin") {
        flowId ??= mcp().auth.active()?.flowId;
        return render(context);
      }
      try {
        probe = { response: await mcp().list(scope, { cached }), checking: cached };
      } catch (error) {
        probe = { ...probe, error: failure(error).message, checking: false };
      }
      await render(context);
    };

    self.onLive(async (context) => {
      // The rows show at once; the live probe the cached read started fills in their status.
      // The Add form needs only the scope's name and trust, which the cached read has.
      await reprobe(context, true);
      if (page === "add") return;
      await reprobe(context);
      // A sign-in changes on the host without a tap here: follow it while it is live, and probe
      // again once it ends, since it changed the server's state. A change another page made
      // probes again too.
      let flowSeen = false;
      while (!context.abortSignal?.aborted) {
        await sleep(POLL_MS, context);
        const active = oppiHost().mcp()?.auth.active();
        if (active || flowSeen || seenChanges !== changes) {
          flowSeen = active !== undefined;
          await reprobe(context);
        }
      }
    });

    const act = async (args: ScreenActArgs, context: Context): Promise<ScreenActResult> => {
      // The server a detail page is for; the list and the forms act on none.
      const server = page.startsWith("server/") ? page.slice("server/".length) : "";
      const value = args.values?.find((item) => item.field === args.row)?.value;
      try {
        switch (args.action) {
          case SCREEN_REFRESH_ACTION:
            await reprobe(context);
            return { ok: true };
          case "enabled":
            await mcp().patch(scope, server, { enabled: value === true });
            break;
          case "exposure":
            await mcp().patch(scope, server, { exposure: value as McpExposure });
            break;
          case "remove":
            await mcp().remove(scope, server);
            return { ok: true, nav: { kind: "pop" } };
          case "logout":
            await mcp().logout(scope, server);
            break;
          case "login":
            await mcp().login(scope, server, "phone_browser");
            await reprobe(context);
            return { ok: true, nav: { kind: "present", page: "signin" } };
          case "signin.continue":
            return { ok: true, nav: { kind: "present", page: "signin" } };
          case "signin.cancel": {
            const active = mcp().auth.active();
            if (active) mcp().auth.cancel(active.flowId);
            break;
          }
          case "callback": {
            const flow = flowId ?? mcp().auth.active()?.flowId;
            const input = args.values?.find((item) => item.field === "callback")?.value;
            if (!flow || typeof input !== "string" || !input.trim())
              return { ok: false, message: "Paste the full callback URL." };
            await mcp().auth.submit(flow, input);
            break;
          }
          case "add":
            await mcp().add(scope, addRequest(args.values));
            return { ok: true, nav: { kind: "pop" } };
          default:
            return { ok: false, message: `Unknown action ${args.action}` };
        }
      } catch (error) {
        return failure(error);
      } finally {
        if (args.action !== SCREEN_REFRESH_ACTION && args.action !== "signin.continue")
          changes += 1;
      }
      await reprobe(context);
      return { ok: true };
    };

    return { page: doc, act };
  });
});
