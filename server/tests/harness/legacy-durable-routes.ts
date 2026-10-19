import { tmpdir } from "node:os";

import { vi } from "vitest";

import { MobileRendererRegistry } from "../../src/mobile-renderer.js";
import { createRouteHelpers } from "../../src/routes/http.js";
import { createSessionRoutes } from "../../src/routes/sessions.js";
import type { RouteContext } from "../../src/routes/types.js";
import { requireDurableStoreId } from "../../src/session-runtime-capabilities.js";
import type { Session } from "../../src/types.js";
import { makeRequest, makeResponse } from "./route-test-helpers.js";

/**
 * Session routes over a durable row created before per-tree stores: bound to a conversation,
 * no storeId. The runtime transcript reads fail the way `DurableRuntime.withSession` does for
 * it (`requireDurableStoreId`), unless `readFailure` says otherwise.
 */
export function legacyDurableRoutes(
  options: { readFailure?: (session: Session) => never; session?: Partial<Session> } = {},
) {
  const session: Session = {
    id: "legacy",
    workspaceId: "ws-1",
    status: "stopped",
    createdAt: 0,
    lastActivity: 10,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    serverDurable: { conversationId: 7 },
    ...options.session,
  };
  const fail = vi.fn(async () => {
    if (options.readFailure) options.readFailure(session);
    requireDurableStoreId(session);
    throw new Error("unreachable");
  });
  const ctx = {
    sessions: { mobileRenderer: new MobileRendererRegistry() },
    storage: {
      getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
      getSession: vi.fn(() => session),
      getDataDir: vi.fn(() => tmpdir()),
      listWorkspaces: vi.fn(() => []),
    },
    sessionRuntimes: {
      refreshSessionState: vi.fn(async () => null),
      getToolFullOutputPath: vi.fn(() => undefined),
      getServerDurableTrace: fail,
      getServerDurableTracePage: fail,
      getServerDurableTraceOutline: fail,
    },
    ensureSessionContextWindow: vi.fn((s: Session) => s),
  } as unknown as RouteContext;
  return createSessionRoutes(ctx, createRouteHelpers());
}

export async function getRoute(dispatch: ReturnType<typeof legacyDurableRoutes>, path: string) {
  const res = makeResponse();
  await dispatch({
    method: "GET",
    path,
    url: new URL(`http://localhost${path}`),
    req: makeRequest() as never,
    res: res as never,
  });
  return res;
}

/** Silences stderr; the returned function restores it and yields everything logged. */
export function captureStderr() {
  const spy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
  return () => {
    const logged = spy.mock.calls.flat().join("\n");
    spy.mockRestore();
    return logged;
  };
}
