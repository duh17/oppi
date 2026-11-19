import { describe, expect, it } from "vitest";

import { formatLogEntry } from "../plugins/godot/contract.js";
import { GodotLinkBroker, type GodotLinkPeer } from "../src/godot/godot-link.js";
import { GODOT_LOG_RING_SIZE, GODOT_PANE_CLIENT_CAPABILITY } from "../src/godot/godot-protocol.js";
import type { GodotLinkServerMessage, GodotProject, GodotRelease } from "../src/types.js";

const PROJECT = "tide-3fa9c2b1";

class FakePeer implements GodotLinkPeer {
  readonly sent: GodotLinkServerMessage[] = [];
  closedWith?: { code: number; reason: string };
  send(message: GodotLinkServerMessage): void {
    this.sent.push(message);
  }
  close(code: number, reason: string): void {
    this.closedWith = { code, reason };
  }
  last<T extends GodotLinkServerMessage["type"]>(type: T) {
    return this.sent.filter((m) => m.type === type).at(-1) as
      Extract<GodotLinkServerMessage, { type: T }> | undefined;
  }
}

function broker(now = () => Date.now()) {
  const project: GodotProject = {
    id: PROJECT,
    name: "Tide",
    engine: { name: "godot" },
    release: null,
    players: [],
  };
  const b: GodotLinkBroker = new GodotLinkBroker({
    describe: (id) => (id === PROJECT ? { ...project, players: b.players(id) } : undefined),
    now,
  });
  return b;
}

function attach(b: GodotLinkBroker, device = "Alex's iPad mini") {
  const peer = new FakePeer();
  const handle = b.openPlayer(PROJECT, peer);
  handle.receive({
    type: "attach",
    capabilities: [GODOT_PANE_CLIENT_CAPABILITY],
    device,
    runtimes: [{ engine: "godot", version: "4.7", formats: ["pck", "zip"] }],
  });
  const attached = peer.last("attached");
  return { peer, handle, playerId: attached?.playerId ?? "" };
}

describe("game link broker", () => {
  it("closes a player link whose first message is not attach naming godot-pane:v1", () => {
    const b = broker();
    const peer = new FakePeer();
    b.openPlayer(PROJECT, peer).receive({ type: "attach", capabilities: [], runtimes: [] });
    expect(peer.last("error")?.error.code).toBe("invalid");
    expect(peer.closedWith?.code).toBe(1008);
    expect(b.players(PROJECT)).toEqual([]);
  });

  it("routes a command to the player and resolves with its answer", async () => {
    const b = broker();
    const { peer, handle, playerId } = attach(b);
    const pending = b.command(PROJECT, { name: "capture" }, { timeoutMs: 5_000 });
    const sent = peer.last("command");
    expect(sent?.command).toMatchObject({ name: "capture" });
    const captureId = sent?.command.name === "capture" ? sent.command.captureId : "";
    expect(captureId).toMatch(/^[A-Za-z0-9][A-Za-z0-9_-]*$/);

    // Another player cannot answer it; a result for an unknown id is ignored.
    const other = attach(b, "second");
    other.handle.receive({ type: "result", id: sent?.id, ok: true, output: { forged: true } });
    handle.receive({ type: "result", id: "c-999", ok: true });
    handle.receive({
      type: "result",
      id: sent?.id,
      ok: true,
      output: { captureId, mimeType: "image/png", width: 10, height: 20 },
    });
    const result = await pending;
    expect(result).toMatchObject({
      ok: true,
      name: "capture",
      playerId,
      output: { captureId, width: 10 },
    });
  });

  it("answers no_player without a player, timeout with a cancel, player_left on detach", async () => {
    const b = broker();
    expect(await b.command(PROJECT, { name: "perf" }, { timeoutMs: 1_000 })).toMatchObject({
      ok: false,
      error: { code: "no_player" },
    });

    const { peer, handle } = attach(b);
    const timedOut = await b.command(PROJECT, { name: "perf" }, { timeoutMs: 30 });
    expect(timedOut).toMatchObject({ ok: false, error: { code: "timeout" } });
    expect(peer.last("cancel")?.id).toBe(timedOut.id);
    // The timeout is in the log for whoever reads it next.
    expect(b.logs(PROJECT).entries.at(-1)).toMatchObject({ origin: "server", level: "warn" });
    // A late answer to a timed-out command changes nothing.
    handle.receive({ type: "result", id: timedOut.id, ok: true });

    const left = b.command(PROJECT, { name: "tree" }, { timeoutMs: 5_000 });
    handle.closed();
    expect(await left).toMatchObject({ ok: false, error: { code: "player_left" } });
    expect(b.players(PROJECT)).toEqual([]);
  });

  it("never gives a player a command sent before it attached", async () => {
    const b = broker();
    const first = attach(b, "first");
    const pending = b.command(PROJECT, { name: "capture" }, { timeoutMs: 5_000 });
    first.handle.closed();
    expect(await pending).toMatchObject({ ok: false, error: { code: "player_left" } });
    const late = attach(b, "late");
    expect(late.peer.sent.map((m) => m.type)).toEqual(["attached"]);
  });

  it("sends a command to the named player, else the one that reported last", async () => {
    let clock = 1_000;
    const b = broker(() => clock);
    const first = attach(b, "first");
    clock += 10;
    const second = attach(b, "second");
    clock += 10;
    first.handle.receive({ type: "state", state: { phase: "running", release: 1 } });

    void b.command(PROJECT, { name: "pause" }, { timeoutMs: 50 });
    expect(first.peer.last("command")).toBeDefined();
    expect(second.peer.last("command")).toBeUndefined();

    void b.command(PROJECT, { name: "pause" }, { timeoutMs: 50, player: second.playerId });
    expect(second.peer.last("command")).toBeDefined();
  });

  it("keeps the newest 2,000 log entries and pages them by seq and level", () => {
    const b = broker();
    const { handle } = attach(b);
    const before = b.logNext(PROJECT);
    const entries = Array.from({ length: GODOT_LOG_RING_SIZE + 50 }, (_, i) => ({
      level: i % 10 === 0 ? "error" : "info",
      message: `line ${i}`,
      ...(i % 10 === 0 ? { source: { file: "res://player.gd", line: i } } : {}),
    }));
    for (let i = 0; i < entries.length; i += 500)
      handle.receive({ type: "log", entries: entries.slice(i, i + 500) });

    const all = b.logs(PROJECT, { since: 0, limit: 500 });
    // The attach entry and the first entries fell out of the ring.
    expect(all.dropped).toBe(before + 50);
    expect(all.entries[0]?.message).toBe("line 50");
    expect(all.entries).toHaveLength(500);
    expect(all.next).toBe(all.entries.at(-1)?.seq);

    const rest = b.logs(PROJECT, { since: all.next, limit: 500 });
    expect(rest.entries[0]?.seq).toBe(all.next + 1);
    expect(rest.dropped).toBe(0);

    const errors = b.logs(PROJECT, { since: 0, limit: 500, level: "error" });
    expect(errors.entries.every((e) => e.level === "error" && e.source?.file)).toBe(true);
    expect(errors.entries.length).toBe(GODOT_LOG_RING_SIZE / 10);
    expect(errors.next).toBe(b.logNext(PROJECT));

    // Nothing new: an empty page whose cursor stays.
    const end = b.logNext(PROJECT);
    expect(b.logs(PROJECT, { since: end })).toEqual({ entries: [], next: end, dropped: 0 });
  });

  it("keeps the release a player's line came from, so an old release's error reads as old", () => {
    const b = broker();
    const { handle } = attach(b);
    handle.receive({
      type: "log",
      entries: [
        {
          level: "error",
          message: "Nil",
          release: 15,
          source: { file: "res://waves.gd", line: 300 },
        },
        { level: "info", message: "wave 11", release: 18 },
        { level: "info", message: "no release", release: "18" },
      ],
    });
    const [error, wave, bare] = b.logs(PROJECT, { since: b.logNext(PROJECT) - 3 }).entries;
    expect([error?.release, wave?.release, bare?.release]).toEqual([15, 18, undefined]);
    expect(formatLogEntry(error!)).toMatch(
      /^#\d+ \[error\] \[release 15\] Nil \(res:\/\/waves.gd:300\)$/,
    );
  });

  it("tells followers about releases, players, and logs, and waits for a first frame", async () => {
    const b = broker();
    const follower = new FakePeer();
    b.openFollower(PROJECT, follower);
    expect(follower.last("attached")?.role).toBe("follower");

    const { handle, playerId } = attach(b);
    expect(follower.last("players")?.players.map((p) => p.id)).toEqual([playerId]);

    const release = { v: 1, seq: 3, reload: "scene" } as GodotRelease;
    const applied = b.waitForApplied(PROJECT, 3, 5_000);
    b.announce(PROJECT, release, "build/tide.pck (1.0 MB)");
    expect(follower.last("release")?.release.seq).toBe(3);

    handle.receive({ type: "state", state: { phase: "loading", release: 3 } });
    handle.receive({ type: "state", state: { phase: "running", release: 3, tier: "scene" } });
    expect(await applied).toEqual({
      playerId,
      state: { phase: "running", release: 3, tier: "scene" },
    });
    expect(await b.waitForApplied(PROJECT, 4, 20)).toBeNull();

    handle.receive({ type: "log", entries: [{ level: "warn", message: "low fps" }] });
    expect(follower.last("log")?.entries.map((e) => e.message)).toEqual(["low fps"]);
  });
});
