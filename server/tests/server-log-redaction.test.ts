import { describe, expect, it } from "vitest";
import { formatUnauthorizedAuthLog } from "../src/server.js";

describe("auth log redaction", () => {
  it("logs auth presence for HTTP 401 without bearer material", () => {
    const line = formatUnauthorizedAuthLog({
      transport: "http",
      method: "POST",
      path: "/workspaces/ws1/sessions",
      authorization: "Bearer sk_live_super_secret_token",
    });

    expect(line).toContain("[auth] 401 POST /workspaces/ws1/sessions");
    expect(line).toContain("auth: present");
    expect(line).not.toContain("Bearer ");
    expect(line).not.toContain("sk_live_super_secret_token");
    expect(line).not.toContain("tok=");
  });

  it("handles websocket unauthorized logs without leaking auth header", () => {
    const line = formatUnauthorizedAuthLog({
      transport: "ws",
      path: "/workspaces/ws1/sessions/s1/stream",
      authorization: ["Bearer sk_live_super_secret_token"],
    });

    expect(line).toContain("[auth] 401 WS upgrade /workspaces/ws1/sessions/s1/stream");
    expect(line).toContain("auth: present");
    expect(line).not.toContain("Bearer ");
    expect(line).not.toContain("sk_live_super_secret_token");
    expect(line).not.toContain("tok=");
  });
});
