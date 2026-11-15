/**
 * Godot projects, end to end: discovery in workspace checkouts, a release for each new or changed pack,
 * the pack and capture store, the link broker, and what routes, the WebSocket upgrade, and the
 * `godot_*` tools call.
 *
 * - Discovery walks every workspace's checkouts (`godot-discovery.ts`): once shortly after start,
 *   every five minutes, and when a list is asked for and the last walk is over 30 s old (the
 *   first list waits for the first walk; later ones answer at once and refresh behind).
 * - Each project's pack folder and project folder are watched (`fs.watch`); a change is debounced,
 *   then the pack must hold still before it is copied and hashed. A minute's sweep re-checks every
 *   pack in case an event was missed. A pack whose stat matches the last release's is not read.
 * - A discovery release names one pack, the entry and reload hint from `oppi-godot.json`
 *   (default `scene`; `restart` when `project.godot` changed since the last one), and is
 *   announced on the project's links.
 * - Commands are never queued: one goes only to a player attached when it is sent, so a player
 *   that attaches later never sees it (`godot-link.ts`).
 * - The service never runs Godot; the `godot_export` tool does (`server/plugins/godot/export.ts`)
 *   and hands Web builds to `GodotWebExports`.
 */
import { createHash } from "node:crypto";
import { existsSync, watch, type FSWatcher } from "node:fs";
import * as fs from "node:fs/promises";
import { join } from "node:path";
import type { Readable } from "node:stream";

import type { WebSocket } from "ws";

import type { OppiGodotHost } from "../durable-extension-api.js";
import { HttpStatusError } from "../http-status-error.js";
import { asRecord } from "../json-shape.js";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import { canonicalRealPath } from "../path-utils.js";
import { answerAuthRenew, authRenewToken, type RenewStreamAccess } from "../stream-auth-renewal.js";
import type {
  GodotCapture,
  GodotCommandResult,
  GodotLogLevel,
  GodotLogPage,
  GodotPack,
  GodotPackUploadResponse,
  GodotProject,
  GodotProjectDetail,
  GodotRelease,
  GodotReleaseResponse,
  Session,
  Workspace,
} from "../types.js";
import { listWorkspaceCheckouts } from "../workspace-checkouts.js";
import { MAIN_WORKTREE_ID } from "../worktrees.js";
import {
  findGodotPack,
  findGodotProjectDirs,
  GODOT_PROJECT_FILE,
  packFolderOf,
  readGodotProject,
  type DiscoveredGodotProject,
  type FoundGodotPack,
} from "./godot-discovery.js";
import { GodotLinkBroker, type GodotLinkHandle, type GodotLinkPeer } from "./godot-link.js";
import { commandTimeoutMs, parseCommandInput, parseReleaseRequest } from "./godot-messages.js";
import {
  GODOT_CAPTURE_MAX_BYTES,
  GODOT_FIRST_FRAME_WAIT_MS,
  GODOT_PACK_MAX_BYTES,
  GODOT_PACK_SHA256,
  GODOT_PROJECT_ID,
} from "./godot-protocol.js";
import { serveGodotToSessions, type SessionGodot } from "./godot-sessions.js";
import { GodotStore, statKeyOf, type GodotProjectMeta } from "./godot-store.js";
import { GodotWebExports } from "./godot-web-exports.js";

const log = createLogger({ base: { component: "godot" } });

const LINK_PATH = /^\/godot\/([^/]+)\/link$/;

export interface GodotLinkTarget {
  projectId: string;
  role: string | null;
}

const FIRST_SCAN_DELAY_MS = 1_000;
const RESCAN_INTERVAL_MS = 5 * 60_000;
const RESCAN_WHEN_OLDER_MS = 30_000;
const SWEEP_INTERVAL_MS = 60_000;
const SETTLE_TRIES = 40;
const LEVELS: ReadonlySet<string> = new Set(["debug", "info", "warn", "error"]);

export interface GodotServiceStorage {
  listWorkspaces(): Workspace[];
  getWorkspace(id: string): Workspace | undefined;
  getSession(id: string): Session | undefined;
  getDataDir(): string;
}

export interface GodotServiceOptions {
  now?: () => number;
  /** Quiet time after a file event before the pack is looked at. */
  debounceMs?: number;
  /** Interval between the stats that decide a pack holds still. */
  settleMs?: number;
  /** `auth_renew` on a link: the server's socket access deadlines. */
  renewAccess?: RenewStreamAccess;
}

interface LiveProject {
  project: DiscoveredGodotProject;
  pack?: FoundGodotPack;
  watchers: FSWatcher[];
  watchKey: string;
  timer?: ReturnType<typeof setTimeout>;
  running?: Promise<void>;
  again: boolean;
  /** The stat of a file refused as a pack, so the same file is not read again. */
  refused?: string;
}

export class GodotService implements SessionGodot {
  readonly broker: GodotLinkBroker;
  private readonly store: GodotStore;
  private readonly web: GodotWebExports;
  private readonly live = new Map<string, LiveProject>();
  private readonly now: () => number;
  private readonly debounceMs: number;
  private readonly settleMs: number;
  private readonly renewAccess: RenewStreamAccess | undefined;
  private firstScan?: Promise<void>;
  private scanning?: Promise<void>;
  private lastScanAt = 0;
  private scannedOnce = false;
  private timers: Array<ReturnType<typeof setTimeout>> = [];
  private closed = false;

  constructor(
    private readonly storage: GodotServiceStorage,
    options: GodotServiceOptions = {},
  ) {
    this.now = options.now ?? Date.now;
    this.debounceMs = options.debounceMs ?? 300;
    this.settleMs = options.settleMs ?? 250;
    this.renewAccess = options.renewAccess;
    this.store = new GodotStore(join(storage.getDataDir(), "godot"), this.now);
    this.web = new GodotWebExports(join(storage.getDataDir(), "godot"));
    this.broker = new GodotLinkBroker({ describe: (id) => this.describe(id), now: this.now });
  }

  /** Bind the `godot_*` tools to this service and start discovery. */
  start(): void {
    serveGodotToSessions(this);
    const first = setTimeout(() => void this.scan(), FIRST_SCAN_DELAY_MS);
    const rescan = setInterval(() => void this.scan(), RESCAN_INTERVAL_MS);
    const sweep = setInterval(() => {
      for (const live of this.live.values()) this.schedule(live, 0);
    }, SWEEP_INTERVAL_MS);
    for (const timer of [first, rescan, sweep]) timer.unref?.();
    this.timers.push(first, rescan, sweep);
  }

  close(): void {
    this.closed = true;
    serveGodotToSessions(undefined);
    for (const timer of this.timers) clearTimeout(timer);
    for (const live of this.live.values()) this.unwatch(live);
    this.live.clear();
    this.broker.close();
  }

  // --- Discovery --------------------------------------------------------------------------------

  /** Walk every workspace's checkouts; resolves when the walk and its first pack looks end. */
  scan(): Promise<void> {
    this.scanning ??= this.walk().finally(() => {
      this.scanning = undefined;
    });
    this.firstScan ??= this.scanning;
    return this.scanning;
  }

  private async walk(): Promise<void> {
    const found = new Map<string, DiscoveredGodotProject>();
    for (const workspace of this.storage.listWorkspaces()) {
      for (const checkout of await listWorkspaceCheckouts(
        workspace,
        this.storage.getDataDir(),
        "godot",
      )) {
        const root = canonicalRealPath(checkout.root);
        if (!root) continue;
        const at = { workspaceId: workspace.id, ...checkout };
        for (const dir of await findGodotProjectDirs(root)) {
          const project = await readGodotProject(at, root, dir);
          found.set(project.id, project);
        }
      }
    }
    if (this.closed) return;
    this.lastScanAt = this.now();
    // A project the walk no longer finds is gone: its links close and its log ring goes.
    for (const [id, live] of this.live) {
      if (found.has(id)) continue;
      this.unwatch(live);
      this.live.delete(id);
      this.broker.forget(id);
    }
    this.scannedOnce = true;
    const looks: Promise<void>[] = [];
    for (const project of found.values()) {
      let live = this.live.get(project.id);
      if (!live) {
        live = { project, watchers: [], watchKey: "", again: false };
        this.live.set(project.id, live);
        this.noteConfigProblem(project);
      } else this.adopt(live, project);
      this.watch(live);
      looks.push(this.refresh(live));
    }
    await Promise.all(looks);
    // A discovered project whose checkout is gone (a removed worktree) goes with its packs.
    for (const stored of this.store.stored()) {
      if (stored.checkoutRoot && !found.has(stored.id) && !existsSync(stored.checkoutRoot)) {
        await this.store.deleteProject(stored.id);
      }
    }
    await this.store.collectUnreleased(new Set(this.live.keys()));
  }

  private async ensureScanned(): Promise<void> {
    if (!this.firstScan) await this.scan();
    else if (!this.scanning && this.now() - this.lastScanAt > RESCAN_WHEN_OLDER_MS)
      void this.scan();
    await this.firstScan;
  }

  private watch(live: LiveProject): void {
    const folders = [live.project.dir, packFolderOf(live.project)];
    const key = folders.join("\0");
    if (live.watchKey === key && live.watchers.length === folders.length) return;
    this.unwatch(live);
    live.watchKey = key;
    for (const folder of folders) {
      try {
        const watcher = watch(folder, () => this.schedule(live, this.debounceMs));
        watcher.on("error", () => watcher.close());
        watcher.unref?.();
        live.watchers.push(watcher);
      } catch {
        // Not there yet (no `build/`): the project folder's watcher sees it appear.
      }
    }
  }

  private unwatch(live: LiveProject): void {
    for (const watcher of live.watchers) watcher.close();
    live.watchers = [];
    live.watchKey = "";
    if (live.timer) clearTimeout(live.timer);
  }

  private schedule(live: LiveProject, delayMs: number): void {
    if (this.closed) return;
    if (live.timer) clearTimeout(live.timer);
    live.timer = setTimeout(() => {
      live.timer = undefined;
      void this.reread(live);
    }, delayMs);
    live.timer.unref?.();
  }

  /** After a file event: the project's config may have changed, then its pack. */
  private async reread(live: LiveProject): Promise<void> {
    const { project } = live;
    if (this.live.get(project.id) !== live) return;
    this.adopt(live, await readGodotProject(project.checkout, project.checkoutRoot, project.dir));
    this.watch(live);
    await this.refresh(live);
  }

  /** Take a fresh read of a project; a new problem with its `oppi-godot.json` goes to its log. */
  private adopt(live: LiveProject, project: DiscoveredGodotProject): void {
    const before = live.project.configProblem;
    live.project = project;
    if (project.configProblem !== before) this.noteConfigProblem(project);
  }

  private noteConfigProblem(project: DiscoveredGodotProject): void {
    if (project.configProblem) this.broker.serverLog(project.id, "warn", project.configProblem);
  }

  /** Look at a project's pack; one look at a time, and one more if asked meanwhile. */
  refresh(live: LiveProject): Promise<void> {
    if (live.running) {
      live.again = true;
      return live.running;
    }
    live.running = (async () => {
      do {
        live.again = false;
        try {
          await this.lookAtPack(live);
        } catch (error: unknown) {
          log.warn("godot.pack_look_failed", {
            projectId: live.project.id,
            error: safeErrorMessage(error),
          });
          this.schedule(live, Math.max(this.debounceMs, 1_000));
        }
      } while (live.again && !this.closed);
    })().finally(() => {
      live.running = undefined;
    });
    return live.running;
  }

  private async lookAtPack(live: LiveProject): Promise<void> {
    const { project } = live;
    live.pack = await findGodotPack(project);
    const pack = live.pack;
    if (!pack) return;
    let info = await fs.stat(pack.path);
    const stored = this.store.get(project.id);
    if (stored?.packStat === statKeyOf(info) || live.refused === statKeyOf(info)) return;
    // Godot writes the pack in place for up to a second before it exits: wait until the file
    // holds still for two intervals in a row.
    for (let tries = 0, still = 0; still < 2; tries += 1) {
      await sleep(this.settleMs);
      const next = await fs.stat(pack.path);
      still = statKeyOf(next) === statKeyOf(info) ? still + 1 : 0;
      info = next;
      if (tries >= SETTLE_TRIES) throw new Error("The pack kept changing");
    }
    let stats;
    try {
      stats = await this.store.storePackFile(project.id, pack.path);
    } catch (error: unknown) {
      if (!(error instanceof HttpStatusError)) throw error;
      // Not a pack: say so once per file version.
      this.broker.serverLog(project.id, "warn", `${pack.relative}: ${error.message}`);
      live.refused = statKeyOf(info);
      return;
    }
    const { statKey, ...packInfo } = stats;
    const current = stored?.releases[0];
    if (current?.packs.length === 1 && current.packs[0]?.sha256 === packInfo.sha256) {
      this.store.rememberPackStat(project.id, statKey);
      return;
    }
    // Project settings and autoloads live in project.godot, and a running engine cannot take a
    // change to them: when it changed since the last discovery release, the hint is `restart`.
    const projectFileSha = await fileSha256(join(project.dir, GODOT_PROJECT_FILE));
    const settingsChanged =
      projectFileSha !== undefined &&
      stored?.projectFileSha !== undefined &&
      projectFileSha !== stored.projectFileSha;
    const release = await this.store.addRelease(
      project.id,
      {
        name: project.name,
        engine: project.engine,
        source: project.source,
        checkoutRoot: project.checkoutRoot,
      },
      {
        origin: "discovery",
        engine: project.engine,
        packs: [packInfo],
        ...(project.config.entry ? { entry: project.config.entry } : {}),
        reload: settingsChanged ? "restart" : (project.config.reload ?? "scene"),
      },
      { packStat: statKey, ...(projectFileSha ? { projectFileSha } : {}) },
    );
    const size =
      packInfo.size >= 1024 * 1024
        ? `${(packInfo.size / (1024 * 1024)).toFixed(1)} MB`
        : `${Math.ceil(packInfo.size / 1024)} KB`;
    this.broker.announce(project.id, release, `${pack.relative} (${size})`);
    log.info("godot.release", { projectId: project.id, seq: release.seq, size: packInfo.size });
  }

  // --- Reading ----------------------------------------------------------------------------------

  /** A project as clients see it; undefined for an unknown id. */
  describe(id: string): GodotProject | undefined {
    const live = this.live.get(id);
    const stored = this.store.get(id);
    if (!live && !stored) return undefined;
    // Once a walk has run, a discovered project it did not find is gone. Before it, the stored
    // one stands in, so a player that reconnects right after a restart can attach.
    if (!live && stored?.source && this.scannedOnce) return undefined;
    const source = live
      ? { ...live.project.source, ...(live.pack ? { pack: live.pack.relative } : {}) }
      : stored?.source;
    return {
      id,
      name: live?.project.name ?? stored?.name ?? id,
      engine: live?.project.engine ?? stored?.engine ?? { name: "godot" },
      ...(source ? { source } : {}),
      release: stored?.releases[0] ?? null,
      players: this.broker.players(id),
    };
  }

  /** Discovered projects, then published ones; optionally one workspace's only. */
  async list(filter: { workspaceId?: string } = {}): Promise<GodotProject[]> {
    await this.ensureScanned();
    const ids = [
      ...this.live.keys(),
      ...this.store
        .stored()
        .filter((p) => !p.source)
        .map((p) => p.id),
    ];
    return ids
      .map((id) => this.describe(id))
      .filter((p): p is GodotProject => p !== undefined)
      .filter((p) => !filter.workspaceId || p.source?.workspaceId === filter.workspaceId);
  }

  async detail(id: string): Promise<GodotProjectDetail | undefined> {
    if (!this.live.has(id) && !this.store.get(id)) await this.ensureScanned();
    const project = this.describe(id);
    if (!project) return undefined;
    return {
      ...project,
      releases: this.store.get(id)?.releases ?? [],
      logNext: this.broker.logNext(id),
    };
  }

  logs(
    id: string,
    query: { since?: unknown; limit?: unknown; level?: unknown } = {},
  ): GodotLogPage {
    const number = (value: unknown): number | undefined => {
      const n = typeof value === "string" ? Number(value) : value;
      return typeof n === "number" && Number.isFinite(n) ? n : undefined;
    };
    const level =
      typeof query.level === "string" && LEVELS.has(query.level)
        ? (query.level as GodotLogLevel)
        : undefined;
    return this.broker.logs(id, {
      ...(number(query.since) !== undefined ? { since: number(query.since) } : {}),
      ...(number(query.limit) !== undefined ? { limit: number(query.limit) } : {}),
      ...(level ? { level } : {}),
    });
  }

  /**
   * The workspace a discovered game belongs to. Before the first walk ends, a stored discovered
   * project stands in for one not walked yet, as in `describe`.
   */
  private workspaceOf(id: string): string | undefined {
    const live = this.live.get(id);
    if (live) return live.project.source.workspaceId;
    return this.scannedOnce ? undefined : this.store.get(id)?.source?.workspaceId;
  }

  /** Whether discovery found a game in the workspace (any of its checkouts). */
  hasGodotProjects(workspaceId: string): boolean {
    const ids = this.scannedOnce
      ? [...this.live.keys()]
      : [...this.live.keys(), ...this.store.stored().map((project) => project.id)];
    return ids.some((id) => this.workspaceOf(id) === workspaceId);
  }

  /**
   * The games one Session's tools reach: only those discovered in its workspace. Every other id,
   * a game of another workspace or one only a publish created, is not found.
   */
  forSession(sessionId: string): OppiGodotHost | undefined {
    const session = this.storage.getSession(sessionId);
    const workspaceId = session?.workspaceId;
    if (!workspaceId) return undefined;
    const worktreeId = session.worktreeId ?? MAIN_WORKTREE_ID;
    const visible = (id: string): boolean => this.workspaceOf(id) === workspaceId;
    return {
      resolve: (ref) => this.resolveIn(ref, workspaceId, worktreeId),
      detail: async (id) => (visible(id) ? this.detail(id) : undefined),
      logs: (id, query) => (visible(id) ? this.logs(id, query) : undefined),
      command: async (id, request) =>
        visible(id)
          ? this.command(id, request)
          : invalidResult(
              String(asRecord(request.command)?.name ?? "invalid"),
              `No game ${id} in this workspace.`,
              "not_found",
            ),
      captureBytes: async (id, captureId) =>
        visible(id) ? this.captureBytes(id, captureId) : undefined,
      exportSource: (id) => {
        const live = visible(id) ? this.live.get(id) : undefined;
        if (!live) return { error: `No game ${id} in this workspace.` };
        // Exporting opens the project in Godot, which runs its tool scripts on the host.
        if (this.storage.getWorkspace(workspaceId)?.runtime !== "host")
          return {
            error: "Exporting runs Godot on the host, so it is off in sandboxed workspaces.",
          };
        return { dir: live.project.dir, name: live.project.name };
      },
      adoptWebExport: async (id, folder) => {
        if (!visible(id)) throw new Error(`No game ${id} in this workspace.`);
        const exportId = await this.web.adopt(id, folder);
        return { exportId, path: `/godot/${id}/web/${exportId}/` };
      },
    };
  }

  /**
   * The game a tool means, among one workspace's: `ref` as an id or a name, else the only one
   * with a player attached, else the only one in the Session's checkout, else the only one.
   */
  private async resolveIn(
    ref: string | undefined,
    workspaceId: string,
    worktreeId: string,
  ): Promise<{ project: GodotProject } | { error: string; projects: GodotProject[] }> {
    const all = (await this.list()).filter((p) => p.source?.workspaceId === workspaceId);
    const inCheckout = all.filter((p) => p.source?.worktreeId === worktreeId);
    const one = (list: GodotProject[]): GodotProject | undefined =>
      list.length === 1 ? list[0] : undefined;
    if (ref) {
      const byId = all.find((p) => p.id === ref);
      if (byId) return { project: byId };
      const named = all.filter((p) => p.name.toLowerCase() === ref.toLowerCase());
      const chosen = one(named) ?? one(named.filter((p) => inCheckout.includes(p)));
      if (chosen) return { project: chosen };
      return {
        error: named.length
          ? `Several games are named ${ref}; pass one of their ids.`
          : `No game ${ref} in this workspace.`,
        projects: named.length ? named : all,
      };
    }
    const chosen = one(all.filter((p) => p.players.length > 0)) ?? one(inCheckout) ?? one(all);
    if (chosen) return { project: chosen };
    return {
      error: all.length
        ? "Several games: pass project with one of these ids."
        : "No games in this workspace. Put a Godot project (a folder with project.godot) in it.",
      projects: all,
    };
  }

  // --- Commands, publishing, captures -----------------------------------------------------------

  /** One command to one player. A malformed request answers `invalid`; never throws. */
  async command(id: string, request: unknown): Promise<GodotCommandResult> {
    const raw = asRecord(request);
    const parsed = parseCommandInput(raw?.command);
    const name =
      typeof asRecord(raw?.command)?.name === "string"
        ? String(asRecord(raw?.command)?.name)
        : "invalid";
    if (!parsed.ok) return invalidResult(name, parsed.reason);
    if (!this.describe(id)) return invalidResult(name, `No game ${id}`, "not_found");
    const player = typeof raw?.player === "string" ? raw.player : undefined;
    return this.broker.command(id, parsed.value, {
      ...(player ? { player } : {}),
      timeoutMs: commandTimeoutMs(parsed.value, raw?.timeoutMs),
    });
  }

  pack(id: string, sha256: string): ReturnType<GodotStore["packInfo"]> {
    return this.store.packInfo(id, sha256);
  }

  async uploadPack(id: string, sha256: string, body: Readable): Promise<GodotPackUploadResponse> {
    if (!GODOT_PROJECT_ID.test(id)) throw new HttpStatusError(400, "Invalid project id");
    if (!GODOT_PACK_SHA256.test(sha256))
      throw new HttpStatusError(400, "A pack id is a lowercase hex sha256");
    return this.store.storePackUpload(id, sha256, body, GODOT_PACK_MAX_BYTES);
  }

  /** `POST .../releases`: every pack named must be uploaded already. */
  async publish(
    id: string,
    body: unknown,
    waitForFirstFrame: boolean,
  ): Promise<GodotReleaseResponse> {
    if (!GODOT_PROJECT_ID.test(id)) throw new HttpStatusError(400, "Invalid project id");
    const parsed = parseReleaseRequest(body);
    if (!parsed.ok) throw new HttpStatusError(400, parsed.reason);
    const request = parsed.value;
    const packs: GodotPack[] = [];
    for (const { sha256 } of request.packs) {
      const stored = await this.store.packInfo(id, sha256);
      if (!stored) throw new HttpStatusError(409, `Upload pack ${sha256} first`);
      packs.push(stored.pack);
    }
    const existing = this.describe(id);
    const checkoutRoot =
      this.store.get(id)?.checkoutRoot ?? this.live.get(id)?.project.checkoutRoot;
    const meta: GodotProjectMeta = {
      name: existing?.name ?? request.name ?? id,
      engine: existing?.engine ?? request.engine,
      ...(existing?.source ? { source: existing.source } : {}),
      ...(checkoutRoot ? { checkoutRoot } : {}),
    };
    const { label } = request;
    const release: GodotRelease = await this.store.addRelease(id, meta, {
      origin: "publish",
      engine: request.engine,
      packs,
      ...(request.entry ? { entry: request.entry } : {}),
      reload: request.reload ?? "scene",
      ...(label ? { label } : {}),
    });
    const waiting = waitForFirstFrame
      ? this.broker.waitForApplied(id, release.seq, GODOT_FIRST_FRAME_WAIT_MS)
      : undefined;
    this.broker.announce(id, release, `published${label ? ` (${label})` : ""}`);
    return waiting ? { release, applied: await waiting } : { release };
  }

  uploadCapture(id: string, captureId: string, body: Readable): Promise<GodotCapture> {
    if (!this.describe(id)) throw new HttpStatusError(404, "No such game");
    return this.store.storeCapture(id, captureId, body, GODOT_CAPTURE_MAX_BYTES);
  }

  capture(id: string, captureId: string): ReturnType<GodotStore["capture"]> {
    return this.store.capture(id, captureId);
  }

  /** A captured image's bytes, for the `godot_capture` tool. */
  async captureBytes(
    id: string,
    captureId: string,
  ): Promise<{ data: Buffer; mimeType: string } | undefined> {
    const found = await this.store.capture(id, captureId);
    return found ? { data: await fs.readFile(found.path), mimeType: found.mimeType } : undefined;
  }

  /** A file of a Web build `godot_export` stored, for `GET /godot/{projectId}/web/...`. */
  webFile(id: string, exportId: string, name: string): ReturnType<GodotWebExports["file"]> {
    return this.web.file(id, exportId, name);
  }

  /** `/godot/{projectId}/link?role=`: the link a WebSocket upgrade asks for, else undefined. */
  linkTarget(url: URL): GodotLinkTarget | undefined {
    const match = LINK_PATH.exec(url.pathname);
    return match ? { projectId: match[1] ?? "", role: url.searchParams.get("role") } : undefined;
  }

  /** Serve an authenticated, upgraded link socket: JSON text frames both ways. */
  serveLink(ws: WebSocket, target: GodotLinkTarget): void {
    const send = (message: unknown): void => {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(message));
    };
    const handle = this.link(target.projectId, target.role, {
      send,
      close: (code, reason) => ws.close(code, reason),
    });
    if (!handle) {
      ws.close(1008, "No such game, or role is not player or follower");
      return;
    }
    ws.on("message", (data, isBinary) => {
      if (isBinary) return;
      let message: unknown;
      try {
        message = JSON.parse(String(data));
      } catch {
        return;
      }
      // `auth_renew` moves the socket's access deadline, as on every device stream; a link that
      // never renews closes when the token it opened with expires.
      const record = asRecord(message);
      const renewToken = record ? authRenewToken(record) : undefined;
      if (renewToken !== undefined) {
        answerAuthRenew(this.renewAccess, ws, renewToken, "godot", send);
        return;
      }
      handle.receive(message);
    });
    ws.on("close", () => handle.closed());
  }

  /** A new link, or undefined for an unknown project or role. */
  link(projectId: string, role: string | null, peer: GodotLinkPeer): GodotLinkHandle | undefined {
    if (!this.describe(projectId)) return undefined;
    if (role === "player") return this.broker.openPlayer(projectId, peer);
    if (role === "follower") return this.broker.openFollower(projectId, peer);
    return undefined;
  }
}

function invalidResult(
  name: string,
  message: string,
  code: "invalid" | "not_found" = "invalid",
): GodotCommandResult {
  return {
    id: "c-0",
    name: name as GodotCommandResult["name"],
    ok: false,
    error: { code, message },
    ms: 0,
  };
}

async function fileSha256(path: string): Promise<string | undefined> {
  try {
    return createHash("sha256")
      .update(await fs.readFile(path))
      .digest("hex");
  } catch {
    return undefined;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
