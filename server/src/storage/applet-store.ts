import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { generateId } from "../id.js";
import type { Applet, AppletVersion, CreateAppletRequest, UpdateAppletRequest } from "../types.js";
import type { ConfigStore } from "./config-store.js";

/** Maximum HTML payload size in bytes (1 MB). */
const MAX_HTML_SIZE = 1_048_576;

export class AppletStore {
  constructor(private readonly configStore: ConfigStore) {}

  // ─── Paths ───

  private appletsDir(workspaceId: string): string {
    return join(this.configStore.getDataDir(), "workspaces", workspaceId, "applets");
  }

  private appletDir(workspaceId: string, appletId: string): string {
    return join(this.appletsDir(workspaceId), appletId);
  }

  private appletMetaPath(workspaceId: string, appletId: string): string {
    return join(this.appletDir(workspaceId, appletId), "applet.json");
  }

  private versionsDir(workspaceId: string, appletId: string): string {
    return join(this.appletDir(workspaceId, appletId), "versions");
  }

  private versionMetaPath(workspaceId: string, appletId: string, version: number): string {
    return join(this.versionsDir(workspaceId, appletId), `${version}.json`);
  }

  private versionHtmlPath(workspaceId: string, appletId: string, version: number): string {
    return join(this.versionsDir(workspaceId, appletId), `${version}.html`);
  }

  // ─── CRUD ───

  createApplet(
    workspaceId: string,
    req: CreateAppletRequest,
  ): { applet: Applet; version: AppletVersion } {
    const htmlBytes = Buffer.byteLength(req.html, "utf-8");
    if (htmlBytes > MAX_HTML_SIZE) {
      throw new AppletError(`HTML too large: ${htmlBytes} bytes (max ${MAX_HTML_SIZE})`, 400);
    }

    const id = generateId(12);
    const now = Date.now();

    const applet: Applet = {
      id,
      workspaceId,
      title: req.title,
      description: req.description,
      currentVersion: 1,
      tags: req.tags,
      createdAt: now,
      updatedAt: now,
    };

    const version: AppletVersion = {
      version: 1,
      appletId: id,
      sessionId: req.sessionId,
      toolCallId: req.toolCallId,
      size: htmlBytes,
      createdAt: now,
    };

    // Write atomically: metadata then HTML
    const vDir = this.versionsDir(workspaceId, id);
    mkdirSync(vDir, { recursive: true, mode: 0o700 });

    writeFileSync(this.appletMetaPath(workspaceId, id), JSON.stringify(applet, null, 2), {
      mode: 0o600,
    });
    writeFileSync(this.versionMetaPath(workspaceId, id, 1), JSON.stringify(version, null, 2), {
      mode: 0o600,
    });
    writeFileSync(this.versionHtmlPath(workspaceId, id, 1), req.html, { mode: 0o600 });

    return { applet, version };
  }

  updateApplet(
    workspaceId: string,
    appletId: string,
    req: UpdateAppletRequest,
  ): { applet: Applet; version: AppletVersion } | undefined {
    const applet = this.getApplet(workspaceId, appletId);
    if (!applet) {
      return undefined;
    }

    const htmlBytes = Buffer.byteLength(req.html, "utf-8");
    if (htmlBytes > MAX_HTML_SIZE) {
      throw new AppletError(`HTML too large: ${htmlBytes} bytes (max ${MAX_HTML_SIZE})`, 400);
    }

    const nextVersion = applet.currentVersion + 1;
    const now = Date.now();

    // Update metadata
    if (req.title !== undefined) applet.title = req.title;
    if (req.description !== undefined) applet.description = req.description;
    if (req.tags !== undefined) applet.tags = req.tags;
    applet.currentVersion = nextVersion;
    applet.updatedAt = now;

    const version: AppletVersion = {
      version: nextVersion,
      appletId,
      sessionId: req.sessionId,
      toolCallId: req.toolCallId,
      size: htmlBytes,
      changeNote: req.changeNote,
      createdAt: now,
    };

    // Ensure versions dir exists (should already)
    const vDir = this.versionsDir(workspaceId, appletId);
    if (!existsSync(vDir)) {
      mkdirSync(vDir, { recursive: true, mode: 0o700 });
    }

    writeFileSync(this.appletMetaPath(workspaceId, appletId), JSON.stringify(applet, null, 2), {
      mode: 0o600,
    });
    writeFileSync(
      this.versionMetaPath(workspaceId, appletId, nextVersion),
      JSON.stringify(version, null, 2),
      { mode: 0o600 },
    );
    writeFileSync(this.versionHtmlPath(workspaceId, appletId, nextVersion), req.html, {
      mode: 0o600,
    });

    return { applet, version };
  }

  getApplet(workspaceId: string, appletId: string): Applet | undefined {
    const metaPath = this.appletMetaPath(workspaceId, appletId);
    if (!existsSync(metaPath)) {
      return undefined;
    }

    try {
      return JSON.parse(readFileSync(metaPath, "utf-8")) as Applet;
    } catch {
      return undefined;
    }
  }

  listApplets(workspaceId: string): Applet[] {
    const dir = this.appletsDir(workspaceId);
    if (!existsSync(dir)) {
      return [];
    }

    const applets: Applet[] = [];
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;

      const metaPath = this.appletMetaPath(workspaceId, entry.name);
      if (!existsSync(metaPath)) continue;

      try {
        const applet = JSON.parse(readFileSync(metaPath, "utf-8")) as Applet;
        applets.push(applet);
      } catch {
        console.error(`[applets] Corrupt applet metadata ${metaPath}, skipping`);
      }
    }

    return applets.sort((a, b) => b.updatedAt - a.updatedAt);
  }

  getVersion(
    workspaceId: string,
    appletId: string,
    version: number,
  ): (AppletVersion & { html: string }) | undefined {
    const metaPath = this.versionMetaPath(workspaceId, appletId, version);
    const htmlPath = this.versionHtmlPath(workspaceId, appletId, version);

    if (!existsSync(metaPath) || !existsSync(htmlPath)) {
      return undefined;
    }

    try {
      const meta = JSON.parse(readFileSync(metaPath, "utf-8")) as AppletVersion;
      const html = readFileSync(htmlPath, "utf-8");
      return { ...meta, html };
    } catch {
      return undefined;
    }
  }

  getVersionHtml(workspaceId: string, appletId: string, version: number): string | undefined {
    const htmlPath = this.versionHtmlPath(workspaceId, appletId, version);
    if (!existsSync(htmlPath)) {
      return undefined;
    }

    try {
      return readFileSync(htmlPath, "utf-8");
    } catch {
      return undefined;
    }
  }

  listVersions(workspaceId: string, appletId: string): AppletVersion[] {
    const vDir = this.versionsDir(workspaceId, appletId);
    if (!existsSync(vDir)) {
      return [];
    }

    const versions: AppletVersion[] = [];
    for (const file of readdirSync(vDir)) {
      if (!file.endsWith(".json")) continue;

      try {
        const meta = JSON.parse(readFileSync(join(vDir, file), "utf-8")) as AppletVersion;
        versions.push(meta);
      } catch {
        // Skip corrupt version files
      }
    }

    return versions.sort((a, b) => a.version - b.version);
  }

  deleteApplet(workspaceId: string, appletId: string): boolean {
    const dir = this.appletDir(workspaceId, appletId);
    if (!existsSync(dir)) {
      return false;
    }

    rmSync(dir, { recursive: true, force: true });
    return true;
  }
}

/** Typed error with HTTP status for route handlers. */
export class AppletError extends Error {
  constructor(
    message: string,
    public readonly status: number,
  ) {
    super(message);
    this.name = "AppletError";
  }
}
