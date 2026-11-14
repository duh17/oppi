/**
 * The server's games as durable sessions see them: whether a session's workspace has a game (it
 * selects the `oppi.godot` built-in only then), and the host `oppiHost().godot` hands the
 * `godot_*` tools, scoped to the calling Session's workspace.
 *
 * One process-wide slot, like the session naming binding: the running `GodotService` sets it when
 * it starts and clears it when it closes. It is not part of `oppi/v1`, so plugin code cannot
 * replace it.
 */
import type { Context } from "@earendil-works/chord/context";
import type { ConversationId, DocumentReader } from "@earendil-works/pi-durable";

import type { OppiGodotHost } from "../durable-extension-api.js";
import { DurableSessionDoc } from "../durable-session-doc.js";

export { GODOT_EXTENSION } from "../../plugins/godot/contract.js";

/** What durable sessions need from the running `GodotService`. */
export interface SessionGodot {
  /** Whether discovery found a game in the workspace. */
  hasGodotProjects(workspaceId: string): boolean;
  /** The games host for one Session; undefined for a Session without a workspace. */
  forSession(sessionId: string): OppiGodotHost | undefined;
}

let current: SessionGodot | undefined;

/** Server only: the running games, or undefined when they stop. */
export function serveGodotToSessions(games: SessionGodot | undefined): void {
  current = games;
}

/** Whether a session in this workspace selects the `godot_*` tools now. */
export function workspaceHasGodot(workspaceId: string | undefined): boolean {
  return workspaceId !== undefined && (current?.hasGodotProjects(workspaceId) ?? false);
}

/** `oppiHost().godot`: the Godot host of the Session the conversation `api` is for. */
export async function godotForConversation(
  api: DocumentReader & { readonly conversationId: ConversationId },
  context: Context,
): Promise<OppiGodotHost | undefined> {
  const games = current;
  if (!games) return undefined;
  const sessionId = (await api.snapshot(DurableSessionDoc, api.conversationId, context))?.sessionId;
  return sessionId ? games.forSession(sessionId) : undefined;
}
