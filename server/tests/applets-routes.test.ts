/**
 * Applet REST route integration tests — real HTTP server on a random port.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

let dataDir: string;
let storage: Storage;
let server: Server;
let baseUrl: string;
let token: string;
let workspaceId: string;

function get(path: string): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
}

function post(path: string, body: unknown): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
}

function put(path: string, body: unknown): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
}

function del(path: string): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
}

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-applets-routes-"));
  storage = new Storage(dataDir);
  storage.updateConfig({ port: 0, host: "127.0.0.1" });
  token = storage.ensurePaired();

  const ws = storage.createWorkspace({ name: "test-ws", skills: [] });
  workspaceId = ws.id;

  server = new Server(storage);
  await server.start();
  baseUrl = `http://127.0.0.1:${server.port}`;
});

afterAll(async () => {
  await server?.stop();
  rmSync(dataDir, { recursive: true, force: true });
});

describe("applet routes", () => {
  // ─── Create ───

  it("POST /workspaces/:wid/applets creates an applet", async () => {
    const res = await post(`/workspaces/${workspaceId}/applets`, {
      title: "Hello World",
      html: "<html><body>hello</body></html>",
      description: "A test applet",
      tags: ["test"],
    });

    expect(res.status).toBe(201);
    const data = (await res.json()) as {
      applet: { id: string; title: string };
      version: { version: number };
    };
    expect(data.applet.id).toBeTruthy();
    expect(data.applet.title).toBe("Hello World");
    expect(data.version.version).toBe(1);
  });

  it("rejects create without title", async () => {
    const res = await post(`/workspaces/${workspaceId}/applets`, {
      html: "<html></html>",
    });
    expect(res.status).toBe(400);
  });

  it("rejects create without html", async () => {
    const res = await post(`/workspaces/${workspaceId}/applets`, {
      title: "No HTML",
    });
    expect(res.status).toBe(400);
  });

  it("rejects create for missing workspace", async () => {
    const res = await post("/workspaces/nonexistent/applets", {
      title: "Test",
      html: "<html></html>",
    });
    expect(res.status).toBe(404);
  });

  // ─── List ───

  it("GET /workspaces/:wid/applets lists applets", async () => {
    const res = await get(`/workspaces/${workspaceId}/applets`);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { applets: unknown[] };
    expect(data.applets.length).toBeGreaterThanOrEqual(1);
  });

  // ─── Get + Update ───

  it("GET /workspaces/:wid/applets/:aid returns applet with latest version", async () => {
    const createRes = await post(`/workspaces/${workspaceId}/applets`, {
      title: "Get Test",
      html: "<html>original</html>",
    });
    const { applet } = (await createRes.json()) as { applet: { id: string } };

    const res = await get(`/workspaces/${workspaceId}/applets/${applet.id}`);
    expect(res.status).toBe(200);
    const data = (await res.json()) as {
      applet: { title: string };
      latestVersion: { html: string; version: number };
    };
    expect(data.applet.title).toBe("Get Test");
    expect(data.latestVersion.html).toBe("<html>original</html>");
    expect(data.latestVersion.version).toBe(1);
  });

  it("PUT /workspaces/:wid/applets/:aid creates new version", async () => {
    const createRes = await post(`/workspaces/${workspaceId}/applets`, {
      title: "Update Test",
      html: "<html>v1</html>",
    });
    const { applet } = (await createRes.json()) as { applet: { id: string } };

    const updateRes = await put(`/workspaces/${workspaceId}/applets/${applet.id}`, {
      html: "<html>v2</html>",
      changeNote: "Updated content",
    });
    expect(updateRes.status).toBe(200);
    const data = (await updateRes.json()) as {
      applet: { currentVersion: number };
      version: { version: number; changeNote: string };
    };
    expect(data.applet.currentVersion).toBe(2);
    expect(data.version.version).toBe(2);
    expect(data.version.changeNote).toBe("Updated content");
  });

  // ─── Versions ───

  it("GET /workspaces/:wid/applets/:aid/versions lists all versions", async () => {
    const createRes = await post(`/workspaces/${workspaceId}/applets`, {
      title: "Version List",
      html: "<html>v1</html>",
    });
    const { applet } = (await createRes.json()) as { applet: { id: string } };

    await put(`/workspaces/${workspaceId}/applets/${applet.id}`, { html: "<html>v2</html>" });
    await put(`/workspaces/${workspaceId}/applets/${applet.id}`, { html: "<html>v3</html>" });

    const res = await get(`/workspaces/${workspaceId}/applets/${applet.id}/versions`);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { versions: { version: number }[] };
    expect(data.versions).toHaveLength(3);
    expect(data.versions[0].version).toBe(1);
    expect(data.versions[2].version).toBe(3);
  });

  it("GET /workspaces/:wid/applets/:aid/versions/:v returns version with html", async () => {
    const createRes = await post(`/workspaces/${workspaceId}/applets`, {
      title: "Version Get",
      html: "<html>specific</html>",
    });
    const { applet } = (await createRes.json()) as { applet: { id: string } };

    const res = await get(`/workspaces/${workspaceId}/applets/${applet.id}/versions/1`);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { version: { html: string; version: number } };
    expect(data.version.html).toBe("<html>specific</html>");
    expect(data.version.version).toBe(1);
  });

  // ─── Raw HTML serving ───

  it("GET /workspaces/:wid/applets/:aid/versions/:v/html returns raw HTML", async () => {
    const html =
      "<!DOCTYPE html><html><head><title>Test</title></head><body><h1>Hello</h1></body></html>";
    const createRes = await post(`/workspaces/${workspaceId}/applets`, {
      title: "Raw HTML",
      html,
    });
    const { applet } = (await createRes.json()) as { applet: { id: string } };

    const res = await get(`/workspaces/${workspaceId}/applets/${applet.id}/versions/1/html`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.headers.get("content-security-policy")).toBeTruthy();
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");

    const body = await res.text();
    expect(body).toBe(html);
  });

  it("returns 404 for nonexistent version html", async () => {
    const createRes = await post(`/workspaces/${workspaceId}/applets`, {
      title: "Missing Version",
      html: "<html></html>",
    });
    const { applet } = (await createRes.json()) as { applet: { id: string } };

    const res = await get(`/workspaces/${workspaceId}/applets/${applet.id}/versions/99/html`);
    expect(res.status).toBe(404);
  });

  // ─── Delete ───

  it("DELETE /workspaces/:wid/applets/:aid removes applet", async () => {
    const createRes = await post(`/workspaces/${workspaceId}/applets`, {
      title: "Deletable",
      html: "<html></html>",
    });
    const { applet } = (await createRes.json()) as { applet: { id: string } };

    const delRes = await del(`/workspaces/${workspaceId}/applets/${applet.id}`);
    expect(delRes.status).toBe(200);

    const getRes = await get(`/workspaces/${workspaceId}/applets/${applet.id}`);
    expect(getRes.status).toBe(404);
  });

  it("returns 404 when deleting nonexistent applet", async () => {
    const res = await del(`/workspaces/${workspaceId}/applets/nonexistent`);
    expect(res.status).toBe(404);
  });
});
