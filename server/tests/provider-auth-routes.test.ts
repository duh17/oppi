import { Readable } from "node:stream";

import { describe, expect, it, vi } from "vitest";

import { RouteHandler, type RouteContext } from "../src/routes/index.js";

interface MockResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  writeHead: (status: number, headers: Record<string, string>) => MockResponse;
  end: (payload?: string) => void;
}

function makeResponse(): MockResponse {
  return {
    statusCode: 0,
    headers: {},
    body: "",
    writeHead(status: number, headers: Record<string, string>): MockResponse {
      this.statusCode = status;
      this.headers = headers;
      return this;
    },
    end(payload?: string): void {
      this.body = payload ?? "";
    },
  };
}

function makeRequest(body?: unknown): Readable {
  const payload = body === undefined ? "" : JSON.stringify(body);
  return Readable.from(payload ? [payload] : []);
}

describe("provider auth routes", () => {
  it("handles GET /provider-auth/status", async () => {
    const providerAuth = {
      getStatus: vi.fn(async () => [
        { id: "openai-codex", name: "ChatGPT (Codex)", supportsApiKey: false },
      ]),
    } as unknown as RouteContext["providerAuth"];

    const refreshModelCatalog = vi.fn(async () => undefined);
    const routes = new RouteHandler({
      providerAuth,
      refreshModelCatalog,
    } as unknown as RouteContext);
    const res = makeResponse();

    await routes.dispatch(
      "GET",
      "/provider-auth/status",
      new URL("http://localhost/provider-auth/status"),
      makeRequest() as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    expect(refreshModelCatalog).toHaveBeenCalledOnce();
    expect(providerAuth.getStatus).toHaveBeenCalledOnce();

    const body = JSON.parse(res.body) as { providers: Array<{ id: string }> };
    expect(body.providers).toHaveLength(1);
    expect(body.providers[0].id).toBe("openai-codex");
  });

  it("validates launchMode on POST /provider-auth/flows", async () => {
    const providerAuth = {
      listProviders: vi.fn(() => []),
      getStatus: vi.fn(() => []),
      startFlow: vi.fn(),
    } as unknown as RouteContext["providerAuth"];

    const routes = new RouteHandler({ providerAuth } as unknown as RouteContext);
    const res = makeResponse();

    await routes.dispatch(
      "POST",
      "/provider-auth/flows",
      new URL("http://localhost/provider-auth/flows"),
      makeRequest({ providerId: "openai-codex", launchMode: "bogus" }) as never,
      res as never,
    );

    expect(res.statusCode).toBe(400);
    expect(providerAuth.startFlow).not.toHaveBeenCalled();
  });

  it("forwards manual-code submission to manager", async () => {
    const providerAuth = {
      listProviders: vi.fn(() => []),
      getStatus: vi.fn(() => []),
      submitManualCode: vi.fn(() => ({
        flowId: "flow-1",
        providerId: "openai-codex",
        flowType: "oauth_callback",
        launchMode: "phone_browser",
        status: "awaiting_external",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        expiresAt: Date.now() + 10_000,
      })),
    } as unknown as RouteContext["providerAuth"];

    const routes = new RouteHandler({ providerAuth } as unknown as RouteContext);
    const res = makeResponse();

    await routes.dispatch(
      "POST",
      "/provider-auth/flows/flow-1/manual-code",
      new URL("http://localhost/provider-auth/flows/flow-1/manual-code"),
      makeRequest({ input: "code=abc" }) as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    expect(providerAuth.submitManualCode).toHaveBeenCalledWith("flow-1", "code=abc");
  });
});
