/**
 * The Godot link broker: per project, the players attached (the app's Godot pane), the followers
 * reading along, a 2,000-entry log ring, and commands waiting for a player's answer.
 *
 * Transport-free: a link is a `GodotLinkPeer` (the WebSocket adapter in `godot-service.ts`, or a
 * test double). A player's first message must be `attach` naming `godot-pane:v1`; anything else
 * first closes the link. A command goes to one player and resolves with its `result`, with
 * `timeout` (the player is sent `cancel`), or with `player_left`; it never throws.
 */
import type {
  GodotCommand,
  GodotCommandInput,
  GodotCommandResult,
  GodotLinkPlayerMessage,
  GodotLinkServerMessage,
  GodotLogEntry,
  GodotLogInput,
  GodotLogLevel,
  GodotLogPage,
  GodotPlayer,
  GodotPlayerState,
  GodotProject,
  GodotRelease,
} from "../types.js";
import { asRecord } from "../json-shape.js";
import {
  parseLogInputs,
  parsePlayerResult,
  parsePlayerState,
  parseRuntimes,
} from "./godot-messages.js";
import {
  GODOT_LOG_PAGE_MAX,
  GODOT_LOG_RING_SIZE,
  GODOT_PANE_CLIENT_CAPABILITY,
} from "./godot-protocol.js";

/** One end of a link, as the broker sees it. */
export interface GodotLinkPeer {
  send(message: GodotLinkServerMessage): void;
  close(code: number, reason: string): void;
}

/** What the broker does with a link's incoming messages and its end. */
export interface GodotLinkHandle {
  receive(message: unknown): void;
  closed(): void;
}

interface PlayerSlot {
  peer: GodotLinkPeer;
  player: GodotPlayer;
}

interface PendingCommand {
  projectId: string;
  playerId: string;
  name: GodotCommand["name"];
  startedAt: number;
  timer: ReturnType<typeof setTimeout>;
  resolve(result: GodotCommandResult): void;
}

interface AppliedWaiter {
  seq: number;
  resolve(applied: { playerId: string; state: GodotPlayerState } | null): void;
}

class ProjectLink {
  readonly players = new Map<string, PlayerSlot>();
  readonly followers = new Set<GodotLinkPeer>();
  readonly ring: GodotLogEntry[] = [];
  nextLogSeq = 1;
  readonly appliedWaiters = new Set<AppliedWaiter>();
}

/** Close code for a link that broke the protocol (WebSocket 1008, policy violation). */
const POLICY_CLOSE = 1008;
/** A player link that has not attached by then is closed. */
const ATTACH_WITHIN_MS = 10_000;
const APPLIED_PHASES: ReadonlySet<string> = new Set(["running", "paused", "error", "relaunch"]);

export interface GodotLinkBrokerOptions {
  /** The project as `attached` describes it, players included; undefined for an unknown id. */
  describe(projectId: string): GodotProject | undefined;
  now?: () => number;
}

export class GodotLinkBroker {
  private readonly links = new Map<string, ProjectLink>();
  private readonly pending = new Map<string, PendingCommand>();
  private nextCommand = 1;
  private nextPlayer = 1;
  private readonly now: () => number;

  constructor(private readonly options: GodotLinkBrokerOptions) {
    this.now = options.now ?? Date.now;
  }

  private link(projectId: string): ProjectLink {
    let link = this.links.get(projectId);
    if (!link) {
      link = new ProjectLink();
      this.links.set(projectId, link);
    }
    return link;
  }

  /** Players attached now, newest first. */
  players(projectId: string): GodotPlayer[] {
    const slots = [...(this.links.get(projectId)?.players.values() ?? [])];
    return slots.map((slot) => slot.player).sort((a, b) => b.attachedAt - a.attachedAt);
  }

  openPlayer(projectId: string, peer: GodotLinkPeer): GodotLinkHandle {
    let playerId: string | undefined;
    const link = this.link(projectId);
    const attachTimer = setTimeout(() => {
      if (!playerId) peer.close(POLICY_CLOSE, "attach required");
    }, ATTACH_WITHIN_MS);
    attachTimer.unref?.();
    return {
      receive: (message) => {
        const raw = asRecord(message);
        if (!playerId) {
          clearTimeout(attachTimer);
          playerId = this.attach(projectId, link, peer, raw);
          return;
        }
        const slot = link.players.get(playerId);
        if (slot && raw) this.fromPlayer(projectId, link, slot, raw);
      },
      closed: () => {
        clearTimeout(attachTimer);
        if (playerId) this.detach(projectId, link, playerId);
      },
    };
  }

  openFollower(projectId: string, peer: GodotLinkPeer): GodotLinkHandle {
    const project = this.options.describe(projectId);
    if (!project) {
      peer.send({ type: "error", error: { code: "invalid", message: "No such game" } });
      peer.close(POLICY_CLOSE, "No such game");
      return { receive: () => {}, closed: () => {} };
    }
    const link = this.link(projectId);
    link.followers.add(peer);
    peer.send({ type: "attached", role: "follower", project });
    return { receive: () => {}, closed: () => link.followers.delete(peer) };
  }

  /** Tell every player and follower of a project about a new release. */
  announce(projectId: string, release: GodotRelease, detail: string): void {
    const link = this.link(projectId);
    for (const { peer } of link.players.values()) peer.send({ type: "release", release });
    for (const peer of link.followers) peer.send({ type: "release", release });
    this.serverLog(projectId, "info", `Release ${release.seq}: ${detail}`);
  }

  /** A server entry in the project's log ring. */
  serverLog(projectId: string, level: GodotLogLevel, message: string): void {
    this.append(this.link(projectId), "server", undefined, [{ level, message }]);
  }

  logs(
    projectId: string,
    query: { since?: number; limit?: number; level?: GodotLogLevel } = {},
  ): GodotLogPage {
    const link = this.links.get(projectId);
    const since = Math.max(0, Math.floor(query.since ?? 0));
    const limit = Math.min(Math.max(1, Math.floor(query.limit ?? 200)), GODOT_LOG_PAGE_MAX);
    if (!link) return { entries: [], next: since, dropped: 0 };
    const oldest = link.ring[0]?.seq ?? link.nextLogSeq;
    const dropped = Math.max(0, oldest - since - 1);
    const minRank = query.level ? LEVEL_RANK[query.level] : 0;
    const after = link.ring.filter((entry) => entry.seq > since);
    const entries: GodotLogEntry[] = [];
    let next = since;
    for (const entry of after) {
      if (entries.length >= limit) break;
      next = entry.seq;
      if (LEVEL_RANK[entry.level] >= minRank) entries.push(entry);
    }
    if (entries.length < limit) next = Math.max(next, link.nextLogSeq - 1);
    return { entries, next, dropped };
  }

  logNext(projectId: string): number {
    return (this.links.get(projectId)?.nextLogSeq ?? 1) - 1;
  }

  /**
   * Send one command and wait for its answer. `command` is the controller's; a capture gets its
   * id here. Never throws: a missing player, a timeout, or a player leaving is a failed result.
   */
  command(
    projectId: string,
    input: GodotCommandInput,
    options: { player?: string; timeoutMs: number; captureId?: string },
  ): Promise<GodotCommandResult> {
    const id = `c-${this.nextCommand++}`;
    const startedAt = this.now();
    const slot = this.pickPlayer(projectId, options.player);
    if (!slot) {
      return Promise.resolve({
        id,
        name: input.name,
        ok: false,
        error: {
          code: "no_player",
          message: options.player
            ? `Player ${options.player} is not attached to ${projectId}.`
            : `No player is attached to ${projectId}. Open the game in Oppi's Godot pane first.`,
        },
        ms: 0,
      });
    }
    const command: GodotCommand =
      input.name === "capture"
        ? { ...input, captureId: options.captureId ?? `cap-${id}-${startedAt.toString(36)}` }
        : input;
    const playerId = slot.player.id;
    return new Promise<GodotCommandResult>((resolve) => {
      const timer = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        slot.peer.send({ type: "cancel", id });
        const seconds = Math.round(options.timeoutMs / 100) / 10;
        this.serverLog(projectId, "warn", `${input.name} (${id}) timed out after ${seconds} s`);
        resolve({
          id,
          name: input.name,
          playerId,
          ok: false,
          error: { code: "timeout", message: `The player did not answer within ${seconds} s.` },
          ms: this.now() - startedAt,
        });
      }, options.timeoutMs);
      timer.unref?.();
      this.pending.set(id, { projectId, playerId, name: input.name, startedAt, timer, resolve });
      slot.peer.send({ type: "command", id, command, timeoutMs: options.timeoutMs });
    });
  }

  /**
   * The first player report of release `seq` running, paused, failed, or waiting for a
   * relaunch; null after `timeoutMs`.
   */
  waitForApplied(
    projectId: string,
    seq: number,
    timeoutMs: number,
  ): Promise<{ playerId: string; state: GodotPlayerState } | null> {
    const link = this.link(projectId);
    return new Promise((resolve) => {
      const waiter: AppliedWaiter = {
        seq,
        resolve: (applied) => {
          clearTimeout(timer);
          link.appliedWaiters.delete(waiter);
          resolve(applied);
        },
      };
      const timer = setTimeout(() => waiter.resolve(null), timeoutMs);
      timer.unref?.();
      link.appliedWaiters.add(waiter);
    });
  }

  /** A project is gone: close its links, fail its waiting commands, and drop its log ring. */
  forget(projectId: string): void {
    const link = this.links.get(projectId);
    if (!link) return;
    this.links.delete(projectId);
    for (const [id, pending] of this.pending) {
      if (pending.projectId !== projectId) continue;
      clearTimeout(pending.timer);
      this.pending.delete(id);
      pending.resolve(this.leftResult(id, pending, "The game is gone."));
    }
    for (const { peer } of link.players.values()) peer.close(1001, "The game is gone");
    for (const peer of link.followers) peer.close(1001, "The game is gone");
    for (const waiter of link.appliedWaiters) waiter.resolve(null);
  }

  /** Close every link and fail every waiting command. */
  close(): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.resolve(this.leftResult(id, pending, "The server is stopping."));
    }
    this.pending.clear();
    for (const link of this.links.values()) {
      for (const { peer } of link.players.values()) peer.close(1001, "Server stopping");
      for (const peer of link.followers) peer.close(1001, "Server stopping");
      for (const waiter of link.appliedWaiters) waiter.resolve(null);
    }
    this.links.clear();
  }

  private attach(
    projectId: string,
    link: ProjectLink,
    peer: GodotLinkPeer,
    raw: Record<string, unknown> | undefined,
  ): string | undefined {
    const capabilities = Array.isArray(raw?.capabilities) ? raw.capabilities : [];
    if (raw?.type !== "attach" || !capabilities.includes(GODOT_PANE_CLIENT_CAPABILITY)) {
      const message = `The first message must be attach naming ${GODOT_PANE_CLIENT_CAPABILITY}.`;
      peer.send({ type: "error", error: { code: "invalid", message } });
      peer.close(POLICY_CLOSE, "attach required");
      return undefined;
    }
    if (!this.options.describe(projectId)) {
      peer.send({ type: "error", error: { code: "invalid", message: "No such game" } });
      peer.close(POLICY_CLOSE, "No such game");
      return undefined;
    }
    const now = this.now();
    const device = typeof raw.device === "string" ? raw.device.slice(0, 120) : undefined;
    const player: GodotPlayer = {
      id: `p-${this.nextPlayer++}`,
      ...(device ? { device } : {}),
      runtimes: parseRuntimes(raw.runtimes),
      attachedAt: now,
      state: parsePlayerState(raw.state) ?? { phase: "idle" },
      stateAt: now,
    };
    link.players.set(player.id, { peer, player });
    const project = this.options.describe(projectId);
    if (project) peer.send({ type: "attached", role: "player", playerId: player.id, project });
    this.serverLog(
      projectId,
      "info",
      `Player ${player.id} attached${device ? ` (${device})` : ""}`,
    );
    this.broadcastPlayers(projectId, link);
    return player.id;
  }

  private detach(projectId: string, link: ProjectLink, playerId: string): void {
    // A link of a project that is gone (`forget`) has nothing left to tell.
    if (!link.players.delete(playerId) || this.links.get(projectId) !== link) return;
    for (const [id, pending] of this.pending) {
      if (pending.playerId !== playerId) continue;
      clearTimeout(pending.timer);
      this.pending.delete(id);
      pending.resolve(this.leftResult(id, pending, "The player left before it answered."));
    }
    this.serverLog(projectId, "info", `Player ${playerId} left`);
    this.broadcastPlayers(projectId, link);
  }

  private fromPlayer(
    projectId: string,
    link: ProjectLink,
    slot: PlayerSlot,
    raw: Record<string, unknown>,
  ): void {
    switch (raw.type as GodotLinkPlayerMessage["type"]) {
      case "state": {
        const state = parsePlayerState(raw.state);
        if (!state) return;
        slot.player = { ...slot.player, state, stateAt: this.now() };
        for (const waiter of link.appliedWaiters) {
          if (state.release === waiter.seq && APPLIED_PHASES.has(state.phase))
            waiter.resolve({ playerId: slot.player.id, state });
        }
        this.broadcastPlayers(projectId, link);
        return;
      }
      case "log": {
        this.append(link, "player", slot.player.id, parseLogInputs(raw.entries));
        return;
      }
      case "result": {
        const result = parsePlayerResult(raw);
        const pending = result && this.pending.get(result.id);
        // Only the player the command went to may answer it.
        if (!result || !pending || pending.playerId !== slot.player.id) return;
        clearTimeout(pending.timer);
        this.pending.delete(result.id);
        pending.resolve({
          ...result,
          name: pending.name,
          playerId: pending.playerId,
          ms: this.now() - pending.startedAt,
        });
        return;
      }
      default:
        return;
    }
  }

  private append(
    link: ProjectLink,
    origin: "player" | "server",
    playerId: string | undefined,
    inputs: GodotLogInput[],
  ): void {
    if (inputs.length === 0) return;
    const at = this.now();
    const entries = inputs.map((input): GodotLogEntry => ({
      seq: link.nextLogSeq++,
      at,
      origin,
      ...(playerId ? { playerId } : {}),
      ...input,
    }));
    link.ring.push(...entries);
    if (link.ring.length > GODOT_LOG_RING_SIZE)
      link.ring.splice(0, link.ring.length - GODOT_LOG_RING_SIZE);
    for (const peer of link.followers) peer.send({ type: "log", entries });
  }

  private broadcastPlayers(projectId: string, link: ProjectLink): void {
    if (link.followers.size === 0) return;
    const players = this.players(projectId);
    for (const peer of link.followers) peer.send({ type: "players", players });
  }

  /** The named player, or the one that reported most recently. */
  private pickPlayer(projectId: string, playerId?: string): PlayerSlot | undefined {
    const link = this.links.get(projectId);
    if (!link) return undefined;
    if (playerId) return link.players.get(playerId);
    let best: PlayerSlot | undefined;
    for (const slot of link.players.values()) {
      if (!best || slot.player.stateAt > best.player.stateAt) best = slot;
    }
    return best;
  }

  private leftResult(id: string, pending: PendingCommand, message: string): GodotCommandResult {
    return {
      id,
      name: pending.name,
      playerId: pending.playerId,
      ok: false,
      error: { code: "player_left", message },
      ms: this.now() - pending.startedAt,
    };
  }
}

const LEVEL_RANK: Record<GodotLogLevel, number> = { debug: 0, info: 1, warn: 2, error: 3 };
