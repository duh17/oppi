import { newControlSessionRow } from "../../src/control-session.js";
import type { Storage } from "../../src/storage.js";
import type { Session } from "../../src/types.js";

/** Save a stopped, unbound durable Oppi Control row, as `POST /control-sessions` does before it starts one. */
export function saveControlRow(storage: Storage, options: { model?: string } = {}): Session {
  const now = Date.now();
  const session = newControlSessionRow({
    now,
    name: "Oppi Control",
    status: "stopped",
    model: options.model,
    launch: { status: "accepted", requestedAt: now, promptDispatch: "not_sent" },
  });
  storage.saveSession(session);
  return session;
}
