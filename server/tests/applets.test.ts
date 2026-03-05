import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";

describe("applet store", () => {
  let dir: string;
  let storage: Storage;
  let workspaceId: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-applets-"));
    storage = new Storage(dir);
    storage.ensurePaired();
    const ws = storage.createWorkspace({ name: "test", skills: [] });
    workspaceId = ws.id;
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  // ─── Create ───

  it("creates an applet with version 1", () => {
    const { applet, version } = storage.createApplet(workspaceId, {
      title: "JSON Formatter",
      html: "<html><body>hello</body></html>",
      description: "Formats JSON",
      tags: ["utility"],
    });

    expect(applet.id).toBeTruthy();
    expect(applet.workspaceId).toBe(workspaceId);
    expect(applet.title).toBe("JSON Formatter");
    expect(applet.description).toBe("Formats JSON");
    expect(applet.currentVersion).toBe(1);
    expect(applet.tags).toEqual(["utility"]);

    expect(version.version).toBe(1);
    expect(version.appletId).toBe(applet.id);
    expect(version.size).toBe(Buffer.byteLength("<html><body>hello</body></html>", "utf-8"));
  });

  it("stores HTML as separate file", () => {
    const html = "<html><body>test</body></html>";
    const { applet } = storage.createApplet(workspaceId, {
      title: "Test",
      html,
    });

    const htmlPath = join(
      dir,
      "workspaces",
      workspaceId,
      "applets",
      applet.id,
      "versions",
      "1.html",
    );
    expect(existsSync(htmlPath)).toBe(true);
    expect(readFileSync(htmlPath, "utf-8")).toBe(html);
  });

  it("writes files with owner-only permissions", () => {
    const { applet } = storage.createApplet(workspaceId, {
      title: "Perms",
      html: "<html></html>",
    });

    const appletDir = join(dir, "workspaces", workspaceId, "applets", applet.id);
    const metaPath = join(appletDir, "applet.json");
    const htmlPath = join(appletDir, "versions", "1.html");
    const versionMetaPath = join(appletDir, "versions", "1.json");

    expect(statSync(join(appletDir, "versions")).mode & 0o777).toBe(0o700);
    expect(statSync(metaPath).mode & 0o777).toBe(0o600);
    expect(statSync(htmlPath).mode & 0o777).toBe(0o600);
    expect(statSync(versionMetaPath).mode & 0o777).toBe(0o600);
  });

  it("records session provenance", () => {
    const { version } = storage.createApplet(workspaceId, {
      title: "Provenance",
      html: "<html></html>",
      sessionId: "sess-123",
      toolCallId: "call-456",
    });

    expect(version.sessionId).toBe("sess-123");
    expect(version.toolCallId).toBe("call-456");
  });

  it("rejects HTML over 1MB", () => {
    const bigHtml = "x".repeat(1_048_577);
    expect(() => storage.createApplet(workspaceId, { title: "Big", html: bigHtml })).toThrow(
      /too large/i,
    );
  });

  // ─── Read ───

  it("gets applet by ID", () => {
    const { applet: created } = storage.createApplet(workspaceId, {
      title: "Getter",
      html: "<html></html>",
    });

    const got = storage.getApplet(workspaceId, created.id);
    expect(got).toBeDefined();
    expect(got!.id).toBe(created.id);
    expect(got!.title).toBe("Getter");
  });

  it("returns undefined for missing applet", () => {
    expect(storage.getApplet(workspaceId, "nonexistent")).toBeUndefined();
  });

  it("lists applets sorted by updatedAt desc", () => {
    storage.createApplet(workspaceId, { title: "First", html: "<html>1</html>" });
    storage.createApplet(workspaceId, { title: "Second", html: "<html>2</html>" });
    storage.createApplet(workspaceId, { title: "Third", html: "<html>3</html>" });

    const applets = storage.listApplets(workspaceId);
    expect(applets).toHaveLength(3);
    // Most recently updated first
    expect(applets[0].title).toBe("Third");
    expect(applets[2].title).toBe("First");
  });

  it("returns empty list for workspace with no applets", () => {
    expect(storage.listApplets(workspaceId)).toEqual([]);
  });

  // ─── Update ───

  it("creates new version on update", () => {
    const { applet } = storage.createApplet(workspaceId, {
      title: "Updatable",
      html: "<html>v1</html>",
    });

    const result = storage.updateApplet(workspaceId, applet.id, {
      html: "<html>v2</html>",
      changeNote: "Added dark mode",
    });

    expect(result).toBeDefined();
    expect(result!.applet.currentVersion).toBe(2);
    expect(result!.version.version).toBe(2);
    expect(result!.version.changeNote).toBe("Added dark mode");

    // Both versions exist
    const v1 = storage.getAppletVersion(workspaceId, applet.id, 1);
    const v2 = storage.getAppletVersion(workspaceId, applet.id, 2);
    expect(v1).toBeDefined();
    expect(v1!.html).toBe("<html>v1</html>");
    expect(v2).toBeDefined();
    expect(v2!.html).toBe("<html>v2</html>");
  });

  it("updates metadata fields on update", () => {
    const { applet } = storage.createApplet(workspaceId, {
      title: "Old Title",
      html: "<html></html>",
      description: "Old desc",
    });

    const result = storage.updateApplet(workspaceId, applet.id, {
      html: "<html>v2</html>",
      title: "New Title",
      description: "New desc",
      tags: ["updated"],
    });

    expect(result!.applet.title).toBe("New Title");
    expect(result!.applet.description).toBe("New desc");
    expect(result!.applet.tags).toEqual(["updated"]);
  });

  it("returns undefined when updating nonexistent applet", () => {
    expect(
      storage.updateApplet(workspaceId, "nonexistent", { html: "<html></html>" }),
    ).toBeUndefined();
  });

  // ─── Versions ───

  it("lists versions in order", () => {
    const { applet } = storage.createApplet(workspaceId, {
      title: "Versioned",
      html: "<html>v1</html>",
    });

    storage.updateApplet(workspaceId, applet.id, { html: "<html>v2</html>" });
    storage.updateApplet(workspaceId, applet.id, { html: "<html>v3</html>" });

    const versions = storage.listAppletVersions(workspaceId, applet.id);
    expect(versions).toHaveLength(3);
    expect(versions[0].version).toBe(1);
    expect(versions[1].version).toBe(2);
    expect(versions[2].version).toBe(3);
  });

  it("gets version HTML directly", () => {
    const { applet } = storage.createApplet(workspaceId, {
      title: "HTML",
      html: "<html>direct</html>",
    });

    expect(storage.getAppletVersionHtml(workspaceId, applet.id, 1)).toBe("<html>direct</html>");
    expect(storage.getAppletVersionHtml(workspaceId, applet.id, 99)).toBeUndefined();
  });

  // ─── Delete ───

  it("deletes applet and all versions", () => {
    const { applet } = storage.createApplet(workspaceId, {
      title: "Deletable",
      html: "<html></html>",
    });

    storage.updateApplet(workspaceId, applet.id, { html: "<html>v2</html>" });

    expect(storage.deleteApplet(workspaceId, applet.id)).toBe(true);
    expect(storage.getApplet(workspaceId, applet.id)).toBeUndefined();
    expect(storage.listAppletVersions(workspaceId, applet.id)).toEqual([]);
  });

  it("returns false when deleting nonexistent applet", () => {
    expect(storage.deleteApplet(workspaceId, "nonexistent")).toBe(false);
  });
});
