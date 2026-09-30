import { request } from "node:http";
import { ProviderAuthFlowStore } from "./provider-auth/flow-store.js";
import {
  isTerminalProviderAuthStatus,
  type ProviderAuthLaunchMode,
} from "./provider-auth/types.js";
import type { McpAuthFlowSnapshot } from "./types/mcp.js";
import { McpCli, type McpCliProcess } from "./mcp-cli.js";
import { McpError } from "./mcp-config.js";

function loopback(value: string): URL {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new McpError(400, "Paste the complete callback URL");
  }
  if (
    url.protocol !== "http:" ||
    !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) ||
    url.username ||
    url.password ||
    url.hash
  ) {
    throw new McpError(400, "Callback must use this flow's loopback address");
  }
  return url;
}
/** Authorize only the exact redirect advertised by this flow, including OAuth state.
 * Pi independently verifies state/code at its waiting callback listener. */
export function validateMcpCallback(authorizationUrl: string, input: string): URL {
  const auth = new URL(authorizationUrl);
  const expected = loopback(auth.searchParams.get("redirect_uri") ?? "");
  const pasted = loopback(input.trim());
  if (
    expected.search ||
    expected.hostname !== pasted.hostname ||
    expected.port !== pasted.port ||
    expected.pathname !== pasted.pathname ||
    !auth.searchParams.get("state") ||
    auth.searchParams.get("state") !== pasted.searchParams.get("state")
  ) {
    throw new McpError(400, "Callback does not match this sign-in's host, port, path, or state");
  }
  if (!pasted.searchParams.has("code") && !pasted.searchParams.has("error"))
    throw new McpError(400, "Callback has no code or error");
  return pasted;
}
function relay(url: URL, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const req = request(
      url,
      {
        signal,
        // Never resolve localhost through mutable DNS. Preserve the URL's Host header.
        lookup: (_host, _options, callback) =>
          callback(
            null,
            url.hostname === "[::1]" ? "::1" : "127.0.0.1",
            url.hostname === "[::1]" ? 6 : 4,
          ),
      },
      (response) => {
        response.resume();
        response.once("end", () => {
          if (response.statusCode === 200) resolve();
          else reject(new McpError(400, "Pi rejected the callback. Check the pasted URL."));
        });
      },
    );
    req.setTimeout(5000, () => req.destroy(new Error("Callback timeout")));
    req.once("error", () =>
      reject(new McpError(502, "Could not reach the waiting Pi callback listener")),
    );
    req.end();
  });
}
interface Attempt {
  scopeId: string;
  name: string;
  process?: McpCliProcess;
  relaying: boolean;
  childSettled: boolean;
}
export class McpAuthManager {
  private readonly store: ProviderAuthFlowStore;
  private readonly attempts = new Map<string, Attempt>();
  constructor(
    private readonly cli: McpCli,
    private readonly ttlMs = 300_000,
  ) {
    this.store = new ProviderAuthFlowStore({ ttlMs });
  }
  hasActive(): boolean {
    for (const id of this.attempts.keys()) {
      const flow = this.store.get(id);
      if (!flow) {
        this.attempts.delete(id);
        continue;
      }
      if (
        !isTerminalProviderAuthStatus(flow.snapshot.status) ||
        !this.attempts.get(id)?.childSettled
      )
        return true;
    }
    return false;
  }
  start(
    scopeId: string,
    name: string,
    cwd: string,
    launchMode: ProviderAuthLaunchMode,
  ): McpAuthFlowSnapshot {
    // Pi's credential file is shared across scopes. One writer avoids concurrent login/logout loss.
    if (this.hasActive()) throw new McpError(409, "Finish or cancel the current MCP sign-in first");
    const record = this.store.create(`${scopeId}:${name}`, "oauth_callback", launchMode);
    const id = record.flowId;
    const attempt: Attempt = { scopeId, name, relaying: false, childSettled: false };
    this.attempts.set(id, attempt);
    const process = this.cli.start(
      ["login", "--timeout", String(this.ttlMs / 1000), "--", name],
      cwd,
      {
        phone: launchMode !== "server_browser",
        timeoutMs: this.ttlMs + 5000,
        onLine: (line) => {
          if (!/^https?:\/\/\S+$/.test(line)) return;
          try {
            const auth = new URL(line);
            const redirect = loopback(auth.searchParams.get("redirect_uri") ?? "");
            if (redirect.search || !auth.searchParams.get("state")) return;
            this.store.setAuthInfo(id, {
              url: auth.href,
              instructions:
                "Open the sign-in page. After approval, paste Safari's full loopback callback URL here.",
            });
          } catch {
            /* ignore non-authorization output */
          }
        },
      },
    );
    attempt.process = process;
    record.abortController.signal.addEventListener("abort", () => process.stop(), { once: true });
    void process.done
      .then(({ code }) => {
        attempt.childSettled = true;
        if (code === 0) this.store.markCompleted(id);
        else
          this.store.markFailed(
            id,
            "Pi MCP sign-in failed. Refresh the server to inspect its connection error.",
          );
      })
      .catch(() => {
        attempt.childSettled = true;
        this.store.markFailed(id, "Pi MCP sign-in could not finish. Try again.");
      });
    return this.get(id);
  }
  get(id: string): McpAuthFlowSnapshot {
    const flow = this.store.getSnapshot(id);
    const attempt = this.attempts.get(id);
    if (!flow || !attempt) throw new McpError(404, "MCP sign-in flow not found");
    return {
      flowId: id,
      scopeId: attempt.scopeId,
      serverName: attempt.name,
      launchMode: flow.launchMode,
      status: flow.status,
      auth: flow.auth,
      error: flow.error,
      createdAt: flow.createdAt,
      updatedAt: flow.updatedAt,
      expiresAt: flow.expiresAt,
    };
  }
  async submit(id: string, input: string): Promise<McpAuthFlowSnapshot> {
    const flow = this.get(id);
    const record = this.store.get(id)!;
    const attempt = this.attempts.get(id)!;
    if (isTerminalProviderAuthStatus(flow.status) || !flow.auth)
      throw new McpError(409, "This flow is not waiting for a callback");
    if (attempt.relaying) throw new McpError(409, "A callback is already being submitted");
    const callback = validateMcpCallback(flow.auth.url, input);
    attempt.relaying = true;
    try {
      await relay(callback, record.abortController.signal);
    } finally {
      attempt.relaying = false;
    }
    // A 200 is only relay acceptance; child exit owns completion after token exchange/reconnect.
    return this.get(id);
  }
  cancel(id: string): McpAuthFlowSnapshot {
    this.get(id);
    this.store.markCancelled(id);
    return this.get(id);
  }
  dispose(): void {
    for (const id of this.attempts.keys()) this.store.markCancelled(id, "Server stopped");
  }
}
