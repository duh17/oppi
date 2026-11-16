import { createHash } from "node:crypto";
import { Readable } from "node:stream";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  findGodotPack,
  findGodotProjectDirs,
  readGodotProject,
} from "../src/godot/godot-discovery.js";
import { GodotService } from "../src/godot/godot-service.js";
import { GodotStore } from "../src/godot/godot-store.js";
import type { GodotLinkPeer } from "../src/godot/godot-link.js";
import { GODOT_PANE_CLIENT_CAPABILITY, GODOT_RELEASES_KEPT } from "../src/godot/godot-protocol.js";
import type { GodotLinkServerMessage, Session, Workspace } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

const services: GodotService[] = [];
afterEach(() => {
  for (const service of services.splice(0)) service.close();
});

function pck(body: string): Buffer {
  return Buffer.concat([Buffer.from("GDPC"), Buffer.from(body)]);
}

function godotProject(dir: string, name: string): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "project.godot"),
    `config_version=5\n\n[application]\n\nconfig/name="${name}"\nconfig/features=PackedStringArray("4.7", "Mobile")\n`,
  );
}

function workspaceAt(root: string, id = "ws-games"): Workspace {
  return {
    id,
    name: "Games",
    hostMount: root,
    runtime: "host",
    createdAt: 1,
    updatedAt: 1,
  } as unknown as Workspace;
}

function service(
  workspaces: Workspace[],
  sessions: Session[] = [],
  dataDir = makeTempDir("oppi-games-data-"),
) {
  const games = new GodotService(
    {
      listWorkspaces: () => workspaces,
      getWorkspace: (id) => workspaces.find((w) => w.id === id),
      getSession: (id) => sessions.find((s) => s.id === id),
      getDataDir: () => dataDir,
    },
    { debounceMs: 5, settleMs: 5 },
  );
  services.push(games);
  return games;
}

class Follower implements GodotLinkPeer {
  readonly sent: GodotLinkServerMessage[] = [];
  send(message: GodotLinkServerMessage): void {
    this.sent.push(message);
  }
  close(): void {}
}

describe("game discovery", () => {
  it("finds project folders and skips hidden folders, node_modules, links, and nested projects", async () => {
    const root = realpathSync(makeTempDir("oppi-games-checkout-"));
    const outside = makeTempDir("oppi-games-outside-");
    godotProject(join(root, "games", "tide"), "Tide");
    godotProject(join(root, "games", "tide", "addons", "nested"), "Nested");
    godotProject(join(root, ".hidden", "secret"), "Hidden");
    godotProject(join(root, "node_modules", "pkg"), "Package");
    godotProject(join(root, "ios", "Pods", "pod"), "Pod");
    godotProject(join(root, "Library", "cache"), "Library");
    godotProject(join(root, "build", "out"), "Output");
    godotProject(join(root, "web", ".godot", "cache"), "Cache");
    godotProject(join(outside, "linked"), "Linked");
    symlinkSync(join(outside, "linked"), join(root, "linked"));

    const dirs = await findGodotProjectDirs(root);
    expect(dirs).toEqual([join(root, "games", "tide")]);
    // A workspace on the home folder itself is never walked.
    expect(await findGodotProjectDirs(homedir())).toEqual([]);

    const checkout = { workspaceId: "ws-games", worktreeId: "main", label: "main", root };
    const project = await readGodotProject(checkout, root, dirs[0] ?? "");
    expect(project).toMatchObject({
      name: "Tide",
      engine: { name: "godot", version: "4.7" },
      source: { workspaceId: "ws-games", worktreeId: "main", root: "games/tide" },
    });
    expect(project.id).toMatch(/^tide-[0-9a-f]{8}$/);
    // Stable for the same folder of the same checkout; another worktree gets its own id.
    expect((await readGodotProject(checkout, project.checkoutRoot, project.dir)).id).toBe(
      project.id,
    );
    const other = await readGodotProject(
      { ...checkout, worktreeId: "wt-x" },
      project.checkoutRoot,
      project.dir,
    );
    expect(other.id).not.toBe(project.id);
  });

  it("plays the newest build/*.pck, or oppi-godot.json's pack, never one outside the checkout", async () => {
    const root = realpathSync(makeTempDir("oppi-games-checkout-"));
    const outside = makeTempDir("oppi-games-outside-");
    const dir = join(root, "tide");
    godotProject(dir, "Tide");
    mkdirSync(join(dir, "build"));
    writeFileSync(join(dir, "build", "old.pck"), pck("old"));
    writeFileSync(join(dir, "build", "new.pck"), pck("new"));
    utimesSync(join(dir, "build", "old.pck"), new Date(1_000), new Date(1_000));
    const checkout = { workspaceId: "ws", worktreeId: "main", label: "main", root };
    const project = await readGodotProject(checkout, root, dir);
    expect((await findGodotPack(project))?.relative).toBe("tide/build/new.pck");

    writeFileSync(
      join(dir, "oppi-godot.json"),
      JSON.stringify({
        pack: "out/game.zip",
        reload: "scripts",
        entry: { scene: "res://menu.tscn" },
      }),
    );
    mkdirSync(join(dir, "out"));
    writeFileSync(join(dir, "out", "game.zip"), Buffer.from("PK\x03\x04rest"));
    const configured = await readGodotProject(checkout, root, dir);
    expect(configured.config).toEqual({
      pack: "out/game.zip",
      reload: "scripts",
      entry: { scene: "res://menu.tscn" },
    });
    expect((await findGodotPack(configured))?.relative).toBe("tide/out/game.zip");

    // A pack path that leaves the checkout is refused before anything reads or watches it; the
    // project falls back to its build/ folder.
    writeFileSync(join(dir, "oppi-godot.json"), JSON.stringify({ pack: "../../escape.pck" }));
    const escaping = await readGodotProject(checkout, root, dir);
    expect(escaping.config.pack).toBeUndefined();
    expect(escaping.configProblem).toContain("pack must stay inside the checkout");
    expect((await findGodotPack(escaping))?.relative).toBe("tide/build/new.pck");
    writeFileSync(join(outside, "real.pck"), pck("outside"));
    symlinkSync(join(outside, "real.pck"), join(dir, "build", "link.pck"));
    writeFileSync(join(dir, "oppi-godot.json"), JSON.stringify({ pack: "build/link.pck" }));
    expect(await findGodotPack(await readGodotProject(checkout, root, dir))).toBeUndefined();

    writeFileSync(join(dir, "oppi-godot.json"), JSON.stringify({ pack: 3, reload: "fast" }));
    const broken = await readGodotProject(checkout, root, dir);
    expect(broken.configProblem).toContain("reload must be");
  });
});

describe("game releases from discovery", () => {
  it("makes a release when a pack appears or changes, and only then", async () => {
    const root = makeTempDir("oppi-games-checkout-");
    const dir = join(root, "games", "tide");
    godotProject(dir, "Tide");
    const games = service([workspaceAt(root)]);

    const [noBuild] = await games.list();
    expect(noBuild).toMatchObject({ name: "Tide", release: null, source: { root: "games/tide" } });
    const id = noBuild?.id ?? "";
    const follower = new Follower();
    games.link(id, "follower", follower);

    mkdirSync(join(dir, "build"));
    writeFileSync(join(dir, "build", "tide.pck"), pck("one"));
    await games.scan();
    const first = games.describe(id)?.release;
    expect(first).toMatchObject({
      seq: 1,
      origin: "discovery",
      reload: "scene",
      packs: [{ size: 7, format: "pck" }],
    });
    expect(follower.sent.filter((m) => m.type === "release")).toHaveLength(1);
    expect(games.describe(id)?.source?.pack).toBe("games/tide/build/tide.pck");

    // The same bytes again (touched, not changed) make no release.
    utimesSync(join(dir, "build", "tide.pck"), new Date(), new Date(Date.now() + 5_000));
    await games.scan();
    expect(games.describe(id)?.release?.seq).toBe(1);

    writeFileSync(join(dir, "build", "tide.pck"), pck("two!"));
    await games.scan();
    const second = games.describe(id)?.release;
    expect(second?.seq).toBe(2);
    expect(second?.packs[0]?.sha256).not.toBe(first?.packs[0]?.sha256);
    expect(follower.sent.filter((m) => m.type === "release")).toHaveLength(2);

    // The device fetches what the release names.
    const stored = await games.pack(id, second?.packs[0]?.sha256 ?? "");
    expect(stored?.pack.size).toBe(8);

    // A file that is not a pack is refused once, with a line in the log.
    writeFileSync(join(dir, "build", "tide.pck"), "not a pack");
    await games.scan();
    expect(games.describe(id)?.release?.seq).toBe(2);
    expect(games.logs(id).entries.at(-1)).toMatchObject({ origin: "server", level: "warn" });
  });

  it("notices an export through the file watcher", { timeout: 20_000 }, async () => {
    const root = makeTempDir("oppi-games-checkout-");
    const dir = join(root, "tide");
    godotProject(dir, "Tide");
    mkdirSync(join(dir, "build"));
    const games = service([workspaceAt(root)]);
    const [project] = await games.list();
    const id = project?.id ?? "";

    // No scan after this point: only the watcher can notice. macOS starts a watch's event stream
    // asynchronously and drops what happens before, so export again until it is noticed, as
    // repeated exports would.
    const deadline = Date.now() + 15_000;
    for (let n = 0; !games.describe(id)?.release && Date.now() < deadline; n += 1) {
      writeFileSync(join(dir, "build", "tide.pck"), pck(`watched ${n}`));
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    expect(games.describe(id)?.release?.origin).toBe("discovery");
  });

  it("marks a release restart when project.godot changed since the last one", async () => {
    const root = makeTempDir("oppi-games-checkout-");
    const dir = join(root, "tide");
    godotProject(dir, "Tide");
    mkdirSync(join(dir, "build"));
    const games = service([workspaceAt(root)]);
    const release = async (bytes: string) => {
      writeFileSync(join(dir, "build", "tide.pck"), pck(bytes));
      await games.scan();
      const [project] = await games.list();
      return project?.release;
    };
    expect((await release("one"))?.reload).toBe("scene");
    expect((await release("two"))?.reload).toBe("scene");
    writeFileSync(
      join(dir, "project.godot"),
      'config/name="Tide"\n\n[autoload]\n\nScore="*res://score.gd"\n',
    );
    expect(await release("three")).toMatchObject({ seq: 3, reload: "restart" });
    expect((await release("four"))?.reload).toBe("scene");
  });

  it("logs each use of an API the device engine leaves out as an error of the release", async () => {
    // Real Godot 4.7.2 exports of one script: `Image.create` (line 7) and `Color8` (line 10),
    // with the same names in a comment, strings, a node path and a method of its own; the clean
    // export uses `Image.create_empty` and `Color.from_rgba8`. Text and compressed binary tokens.
    const fixture = (name: string) =>
      readFileSync(join(import.meta.dirname, "fixtures", "godot", name));
    const root = makeTempDir("oppi-games-checkout-");
    const dir = join(root, "probe");
    godotProject(dir, "Probe");
    mkdirSync(join(dir, "build"));
    const games = service([workspaceAt(root)]);
    const [project] = await games.list();
    const id = project?.id ?? "";
    const errorsOf = async (pack: string) => {
      const since = games.logs(id).next;
      writeFileSync(join(dir, "build", "probe.pck"), fixture(pack));
      await games.scan();
      return games
        .logs(id, { since, level: "error" })
        .entries.map((entry) => [entry.source?.file, entry.source?.line, entry.message]);
    };

    const text = await errorsOf("deprecated-text.pck");
    expect(games.describe(id)?.release?.seq).toBe(1);
    expect(text).toEqual([
      [
        "res://main.gd",
        7,
        expect.stringMatching(/^Release 1: Image\.create\(\) is deprecated.*create_empty\(\)/),
      ],
      [
        "res://main.gd",
        10,
        expect.stringMatching(/^Release 1: Color8\(\) is deprecated.*Color\.from_rgba8\(\)/),
      ],
    ]);
    expect(await errorsOf("clean-binary.pck")).toEqual([]);
    expect(games.describe(id)?.release?.seq).toBe(2);
    expect((await errorsOf("deprecated-binary.pck")).map(([file, line]) => [file, line])).toEqual([
      ["res://main.gd", 7],
      ["res://main.gd", 10],
    ]);
  });

  it("keeps the newest five releases", async () => {
    const root = makeTempDir("oppi-games-checkout-");
    const dir = join(root, "tide");
    godotProject(dir, "Tide");
    mkdirSync(join(dir, "build"));
    const games = service([workspaceAt(root)]);
    for (let i = 0; i < GODOT_RELEASES_KEPT + 2; i += 1) {
      writeFileSync(join(dir, "build", "tide.pck"), pck(`build ${i}`));
      await games.scan();
    }
    const [project] = await games.list();
    const detail = await games.detail(project?.id ?? "");
    expect(detail?.releases.map((r) => r.seq)).toEqual([7, 6, 5, 4, 3]);
  });

  it("closes a project's links and drops it when the walk no longer finds it", async () => {
    const root = makeTempDir("oppi-games-checkout-");
    const dir = join(root, "tide");
    godotProject(dir, "Tide");
    mkdirSync(join(dir, "build"));
    writeFileSync(join(dir, "build", "tide.pck"), pck("one"));
    const games = service([workspaceAt(root)]);
    const [project] = await games.list();
    const id = project?.id ?? "";
    let closed: number | undefined;
    games.link(id, "follower", { send: () => {}, close: (code) => (closed = code) });

    rmSync(join(dir, "project.godot"));
    await games.scan();
    expect(closed).toBe(1001);
    expect(await games.list()).toEqual([]);
    expect(games.describe(id)).toBeUndefined();
    expect(games.logs(id).entries).toEqual([]);
  });
});

describe("games before the first walk", () => {
  it("counts the games a previous run found, so a session attaching early keeps its tools", async () => {
    const root = makeTempDir("oppi-games-checkout-");
    const dir = join(root, "tide");
    godotProject(dir, "Tide");
    mkdirSync(join(dir, "build"));
    writeFileSync(join(dir, "build", "tide.pck"), pck("one"));
    const dataDir = makeTempDir("oppi-games-data-");
    const sessions = [{ id: "s-1", workspaceId: "ws-games" } as Session];
    const first = service([workspaceAt(root)], sessions, dataDir);
    const [project] = await first.list();
    first.close();

    // A restart: nothing walked yet, the stored discovered project stands in.
    const restarted = service([workspaceAt(root)], sessions, dataDir);
    expect(restarted.hasGodotProjects("ws-games")).toBe(true);
    expect(restarted.hasGodotProjects("ws-other")).toBe(false);
    expect(await restarted.forSession("s-1")?.detail(project?.id ?? "")).toBeDefined();

    // The walk no longer finds it: gone for good.
    rmSync(join(dir, "project.godot"));
    await restarted.scan();
    expect(restarted.hasGodotProjects("ws-games")).toBe(false);
  });
});

describe("game store", () => {
  it("deletes uploads to an id that never got a release once they are an hour old", async () => {
    const root = makeTempDir("oppi-games-store-");
    let now = Date.now();
    const store = new GodotStore(root, () => now);
    const bytes = pck("orphan");
    const sha = createHash("sha256").update(bytes).digest("hex");
    await store.storePackUpload("never-released", sha, Readable.from([bytes]), 1_000);
    await store.storePackUpload("released", sha, Readable.from([bytes]), 1_000);
    // A discovered project with no release yet: its folder holds captures and its first pack.
    await store.storePackUpload("discovered", sha, Readable.from([bytes]), 1_000);
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 0]);
    await store.storeCapture("discovered", "cap-1", Readable.from([png]), 1_000);
    const live = new Set(["discovered"]);
    await store.addRelease(
      "released",
      { name: "Released", engine: { name: "godot" } },
      {
        origin: "publish",
        engine: { name: "godot" },
        packs: [{ sha256: sha, size: bytes.length, format: "pck" }],
        reload: "scene",
      },
    );

    await store.collectUnreleased(live);
    expect(existsSync(join(root, "never-released"))).toBe(true);
    now += 2 * 60 * 60 * 1000;
    await store.collectUnreleased(live);
    expect(existsSync(join(root, "never-released"))).toBe(false);
    expect(await store.packInfo("released", sha)).toBeDefined();
    expect(await store.packInfo("discovered", sha)).toBeDefined();
    expect(await store.capture("discovered", "cap-1")).toBeDefined();
  });
});

describe("game tools' reach", () => {
  it("sees only the session's workspace, and picks the game the session means", async () => {
    const root = makeTempDir("oppi-games-checkout-");
    godotProject(join(root, "tide"), "Tide");
    godotProject(join(root, "dune"), "Dune");
    const sandboxRoot = makeTempDir("oppi-games-sandbox-");
    godotProject(join(sandboxRoot, "solo"), "Solo");
    const sandbox = { ...workspaceAt(sandboxRoot, "ws-sandbox"), runtime: "sandbox" } as Workspace;
    const sessions = [
      { id: "s-sandbox", workspaceId: "ws-sandbox" } as Session,
      { id: "s-games", workspaceId: "ws-games" } as Session,
      { id: "s-control" } as Session,
    ];
    const games = service([workspaceAt(root), sandbox], sessions);
    const all = await games.list();
    const tide = all.find((p) => p.name === "Tide");

    // A player attached to another workspace's game is never picked, and its id is not found.
    games
      .link(tide?.id ?? "", "player", { send: () => {}, close: () => {} })
      ?.receive({ type: "attach", capabilities: [GODOT_PANE_CLIENT_CAPABILITY], runtimes: [] });
    const inSandbox = games.forSession("s-sandbox");
    const solo = await inSandbox?.resolve(undefined);
    expect(solo && "project" in solo && solo.project.name).toBe("Solo");
    const other = await inSandbox?.resolve("tide");
    expect(other && "error" in other && other.error).toBe("No game tide in this workspace.");
    expect(other && "error" in other && other.projects.map((p) => p.name)).toEqual(["Solo"]);
    expect(
      await inSandbox?.command(tide?.id ?? "", { command: { name: "capture" } }),
    ).toMatchObject({ ok: false, error: { code: "not_found" } });
    expect(await inSandbox?.detail(tide?.id ?? "")).toBeUndefined();
    expect(inSandbox?.logs(tide?.id ?? "", {})).toBeUndefined();

    // In its own workspace: a name, the one with a player, else a list to choose from.
    const inGodot = games.forSession("s-games");
    const named = await inGodot?.resolve("dune");
    expect(named && "project" in named && named.project.name).toBe("Dune");
    const playing = await inGodot?.resolve(undefined);
    expect(playing && "project" in playing && playing.project.name).toBe("Tide");

    // A session without a workspace (Oppi Control) has no games.
    expect(games.forSession("s-control")).toBeUndefined();
    expect(games.hasGodotProjects("ws-sandbox")).toBe(true);
    expect(games.hasGodotProjects("ws-none")).toBe(false);
  });
});
