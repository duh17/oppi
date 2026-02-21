import { Readable } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import { defaultPolicy } from "../src/policy-presets.js";
import { RouteHandler, type RouteContext } from "../src/routes.js";

interface MockResponse {
  statusCode: number;
  body: string;
  writeHead: (status: number, headers: Record<string, string>) => MockResponse;
  end: (payload?: string) => void;
}

function makeResponse(): MockResponse {
  return {
    statusCode: 0,
    body: "",
    writeHead(status: number): MockResponse {
      this.statusCode = status;
      return this;
    },
    end(payload?: string): void {
      this.body = payload ?? "";
    },
  };
}

function makeRequest(body?: unknown): Readable {
  const text = body === undefined ? "" : JSON.stringify(body);
  return Readable.from(text ? [text] : []);
}

describe("policy fallback routes", () => {
  it("GET /policy/fallback returns the active default fallback", async () => {
    const gate = {
      getDefaultFallback: vi.fn(() => "ask" as const),
    };

    const routes = new RouteHandler({ gate } as unknown as RouteContext);
    const res = makeResponse();

    await routes.dispatch(
      "GET",
      "/policy/fallback",
      new URL("http://localhost/policy/fallback"),
      makeRequest() as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toMatchObject({ fallback: "ask" });
    expect(gate.getDefaultFallback).toHaveBeenCalledTimes(1);
  });

  it("PATCH /policy/fallback updates runtime gate fallback and persisted config", async () => {
    const setDefaultFallback = vi.fn();
    const updateConfig = vi.fn();
    const getConfig = vi.fn(() => ({
      policy: defaultPolicy(),
    }));

    const routes = new RouteHandler({
      gate: {
        setDefaultFallback,
      },
      storage: {
        getConfig,
        updateConfig,
      },
    } as unknown as RouteContext);
    const res = makeResponse();

    await routes.dispatch(
      "PATCH",
      "/policy/fallback",
      new URL("http://localhost/policy/fallback"),
      makeRequest({ fallback: "deny" }) as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toMatchObject({ fallback: "deny" });
    expect(setDefaultFallback).toHaveBeenCalledWith("deny");
    expect(updateConfig).toHaveBeenCalledWith(
      expect.objectContaining({
        policy: expect.objectContaining({ fallback: "block" }),
      }),
    );
  });

  it("PATCH /policy/fallback rejects invalid values", async () => {
    const setDefaultFallback = vi.fn();
    const updateConfig = vi.fn();

    const routes = new RouteHandler({
      gate: {
        setDefaultFallback,
      },
      storage: {
        getConfig: vi.fn(() => ({ policy: defaultPolicy() })),
        updateConfig,
      },
    } as unknown as RouteContext);
    const res = makeResponse();

    await routes.dispatch(
      "PATCH",
      "/policy/fallback",
      new URL("http://localhost/policy/fallback"),
      makeRequest({ fallback: "ship-it" }) as never,
      res as never,
    );

    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toMatchObject({
      error: 'fallback must be one of "allow", "ask", "deny"',
    });
    expect(setDefaultFallback).not.toHaveBeenCalled();
    expect(updateConfig).not.toHaveBeenCalled();
  });
});
