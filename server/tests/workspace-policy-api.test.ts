import { Readable } from "node:stream";
import { describe, expect, it } from "vitest";
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

describe("workspace policy routes", () => {
  it("GET /workspaces/:id/policy is not exposed", async () => {
    const routes = new RouteHandler({} as RouteContext);
    const res = makeResponse();

    await routes.dispatch(
      "GET",
      "/workspaces/w1/policy",
      new URL("http://localhost/workspaces/w1/policy"),
      makeRequest() as never,
      res as never,
    );

    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toMatchObject({ error: "Not found" });
  });

  it("PATCH /workspaces/:id/policy is not exposed", async () => {
    const routes = new RouteHandler({} as RouteContext);
    const res = makeResponse();

    await routes.dispatch(
      "PATCH",
      "/workspaces/w1/policy",
      new URL("http://localhost/workspaces/w1/policy"),
      makeRequest({ fallback: "allow" }) as never,
      res as never,
    );

    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toMatchObject({ error: "Not found" });
  });

  it("DELETE /workspaces/:id/policy/permissions/:id is not exposed", async () => {
    const routes = new RouteHandler({} as RouteContext);
    const res = makeResponse();

    await routes.dispatch(
      "DELETE",
      "/workspaces/w1/policy/permissions/p1",
      new URL("http://localhost/workspaces/w1/policy/permissions/p1"),
      makeRequest() as never,
      res as never,
    );

    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toMatchObject({ error: "Not found" });
  });
});
