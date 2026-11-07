import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import {
  chmodSync,
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import { afterEach, describe, expect, it } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createHostFileRoutes } from "../src/routes/host-files.js";
import type { RouteContext } from "../src/routes/types.js";
import type { RequestPrincipal } from "../src/request-principal.js";
import type { ServerConfig, Session, Workspace } from "../src/types.js";
import { createWorkspaceWorktree } from "../src/worktrees.js";
import { makeRawRequest, MockWritableResponse } from "./harness/route-test-helpers.js";

/**
 * One file, many ways in: a reader that asks (`X-Oppi-Edit-Resolve: 1`) learns
 * the one origin that edits the canonical file, whichever link, tree, or
 * session reached it, and that origin's write keeps the If-Match contract.
 */

interface Fixture {
  home: string;
  dataDir: string;
  agentDir: string;
  project: string;
  notebook: string;
  skillDir: string;
  /** A package Skill: read-only on its own page. */
  packageSkillDir: string;
  sandboxMount: string;
  outside: string;
  workspaces: Workspace[];
  sessions: Session[];
  config: Partial<ServerConfig>;
}

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function session(overrides: Partial<Session>): Session {
  return {
    id: "sess",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  } as Session;
}

function seed(): Fixture {
  const home = realpathSync(mkdtempSync(join(tmpdir(), "oppi-edit-origins-home-")));
  const outside = realpathSync(mkdtempSync(join(tmpdir(), "oppi-edit-origins-outside-")));
  roots.push(home, outside);
  const dataDir = join(home, "oppi-data");
  const agentDir = join(home, ".pi", "agent");
  const project = join(home, "code", "project");
  const notebook = join(home, "notebook");
  const skillDir = join(home, "skills", "release");
  const packageSkillDir = join(home, "packages", "tools", "skills", "deploy");
  const sandboxMount = join(home, "sandbox", "research");
  for (const dir of [
    dataDir,
    agentDir,
    project,
    notebook,
    skillDir,
    packageSkillDir,
    sandboxMount,
  ]) {
    mkdirSync(dir, { recursive: true });
  }
  writeFileSync(join(packageSkillDir, "SKILL.md"), "# Deploy skill\n");
  writeFileSync(join(project, "README.md"), "# Project\n");
  writeFileSync(join(notebook, "tasks.org"), "* TODO Write the design\n");
  writeFileSync(join(skillDir, "SKILL.md"), "# Release skill\n");
  writeFileSync(join(agentDir, "SYSTEM.md"), "# Pi system prompt\n");
  writeFileSync(join(sandboxMount, "report.md"), "sandbox report\n");
  writeFileSync(join(outside, "elsewhere.md"), "outside the home\n");

  return {
    home,
    dataDir,
    agentDir,
    project,
    notebook,
    skillDir,
    packageSkillDir,
    sandboxMount,
    outside,
    config: {},
    workspaces: [
      { id: "ws-project", name: "project", hostMount: project, createdAt: 1, updatedAt: 1 },
      {
        id: "ws-sandbox",
        name: "research",
        runtime: "sandbox",
        hostMount: sandboxMount,
        createdAt: 1,
        updatedAt: 1,
      },
    ] as Workspace[],
    sessions: [
      session({ id: "host-session", workspaceId: "ws-project" }),
      session({ id: "sandbox-session", workspaceId: "ws-sandbox" }),
    ],
  };
}

async function call(
  fixture: Fixture,
  method: "GET" | "PUT",
  params: Record<string, string>,
  options: {
    body?: string;
    headers?: Record<string, string>;
    resolve?: boolean;
    /** Who sent it; the owner unless a test says otherwise. */
    principal?: RequestPrincipal | null;
  } = {},
): Promise<MockWritableResponse> {
  const dispatch = createHostFileRoutes(
    {
      storage: {
        getConfig: () => fixture.config,
        getDataDir: () => fixture.dataDir,
        getWorkspace: (id: string) => fixture.workspaces.find((workspace) => workspace.id === id),
        listWorkspaces: () => fixture.workspaces,
        getSession: (id: string) => fixture.sessions.find((candidate) => candidate.id === id),
      },
      serverResources: {
        // One editable directory Skill and one package Skill, as the catalog
        // would report them.
        skillEditRoot: async () => fixture.skillDir,
        skillContaining: async (realPath: string) => {
          for (const [root, skillId, editable] of [
            [fixture.skillDir, "skill-release", true],
            [fixture.packageSkillDir, "skill-deploy", false],
          ] as const) {
            if (realPath.startsWith(`${root}/`)) {
              return { skillId, root, path: realPath.slice(root.length + 1), editable };
            }
          }
          return null;
        },
      },
    } as unknown as RouteContext,
    createRouteHelpers(),
    { homeDir: fixture.home, piAgentDir: fixture.agentDir },
  );
  const res = new MockWritableResponse();
  const finished = once(res, "finish");
  const url = new URL(`https://localhost/files/current?${new URLSearchParams(params)}`);
  const req = options.body !== undefined ? makeRawRequest(options.body) : ({} as IncomingMessage);
  req.headers = {
    ...(options.resolve === false ? {} : { "x-oppi-edit-resolve": "1" }),
    ...(options.body !== undefined
      ? { "content-length": String(Buffer.byteLength(options.body)) }
      : {}),
    ...options.headers,
  };
  const handled = await dispatch({
    method,
    path: url.pathname,
    url,
    req,
    res: res as unknown as ServerResponse,
    ...(options.principal === null ? {} : { principal: options.principal ?? { kind: "owner" } }),
  });
  expect(handled).toBe(true);
  if (!res.writableEnded) await finished;
  return res;
}

/** What a reader learns about editing from one read. */
function editAnswer(res: MockWritableResponse): {
  status: number;
  origin?: Record<string, string>;
  refusal?: string;
  etag?: string;
} {
  const origin = res.headers["X-Oppi-Edit-Origin"];
  return {
    status: res.statusCode,
    ...(origin ? { origin: Object.fromEntries(new URLSearchParams(origin)) } : {}),
    ...(res.headers["X-Oppi-Edit-Refusal"] ? { refusal: res.headers["X-Oppi-Edit-Refusal"] } : {}),
    ...(res.headers.ETag ? { etag: res.headers.ETag } : {}),
  };
}

/** Write through the origin a read named. */
function put(fixture: Fixture, origin: Record<string, string>, body: string, etag: string) {
  return call(fixture, "PUT", origin, { body, headers: { "if-match": etag }, resolve: false });
}

describe("/files/current edit origins", () => {
  it("names one write origin for a workspace file however it was reached", async () => {
    const fixture = seed();
    const file = join(fixture.project, "README.md");
    const ways: Record<string, string>[] = [
      { origin: "workspace", workspaceId: "ws-project", path: "README.md" },
      { origin: "host", path: file },
      { origin: "host", path: "~/code/project/README.md" },
      { origin: "host", path: pathToFileURL(file).href },
      { origin: "session", sessionId: "host-session", path: "README.md" },
      { origin: "session", sessionId: "host-session", path: file },
    ];
    // A symlinked folder elsewhere in the home is the same file, not a second one.
    symlinkSync(fixture.project, join(fixture.home, "project-link"));
    ways.push({ origin: "host", path: join(fixture.home, "project-link", "README.md") });

    const answers = await Promise.all(
      ways.map(async (way) => editAnswer(await call(fixture, "GET", way))),
    );
    const expected = {
      status: 200,
      origin: { origin: "workspace", workspaceId: "ws-project", path: "README.md" },
      etag: expect.stringMatching(/^"sha256-/),
    };
    for (const answer of answers) expect(answer).toEqual(expected);
    expect(new Set(answers.map((answer) => answer.etag)).size).toBe(1);
  });

  it("names the worktree for a file in a session's worktree", async () => {
    const fixture = seed();
    execSync(
      "git init -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init",
      {
        cwd: fixture.project,
        stdio: "ignore",
        env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" },
      },
    );
    const worktree = await createWorkspaceWorktree(
      fixture.workspaces[0],
      { branch: "feature/edit" },
      { dataDir: fixture.dataDir },
    );
    writeFileSync(join(worktree.path, "README.md"), "worktree copy\n");
    // The worktree sits in Oppi's data directory, which is never a host file;
    // it still edits as its workspace.
    const expected = {
      origin: "workspace",
      workspaceId: "ws-project",
      worktreeId: worktree.id,
      path: "README.md",
    };
    for (const way of [
      { origin: "host", path: join(worktree.path, "README.md") },
      {
        origin: "workspace",
        workspaceId: "ws-project",
        worktreeId: worktree.id,
        path: "README.md",
      },
    ]) {
      expect(editAnswer(await call(fixture, "GET", way)).origin).toEqual(expected);
    }
  });

  it("names the narrowest owner: Pi's file, then a Skill, then the home", async () => {
    const fixture = seed();
    const cases: [Record<string, string>, Record<string, string>][] = [
      [
        { origin: "host", path: "~/.pi/agent/SYSTEM.md" },
        { origin: "pi", path: "SYSTEM.md" },
      ],
      [
        { origin: "pi", path: "SYSTEM.md" },
        { origin: "pi", path: "SYSTEM.md" },
      ],
      [
        { origin: "host", path: join(fixture.skillDir, "SKILL.md") },
        { origin: "skill", skillId: "skill-release", path: "SKILL.md" },
      ],
      [
        { origin: "host", path: "~/notebook/tasks.org" },
        { origin: "host", path: join(fixture.notebook, "tasks.org") },
      ],
      [
        { origin: "session", sessionId: "host-session", path: join(fixture.notebook, "tasks.org") },
        { origin: "host", path: join(fixture.notebook, "tasks.org") },
      ],
    ];
    for (const [way, origin] of cases) {
      const answer = editAnswer(await call(fixture, "GET", way));
      expect(answer.origin, JSON.stringify(way)).toEqual(origin);
      expect(answer.etag).toBeDefined();
    }
  });

  it("keeps If-Match through every origin a read names", async () => {
    const fixture = seed();
    for (const [way, file] of [
      [
        { origin: "host", path: join(fixture.project, "README.md") },
        join(fixture.project, "README.md"),
      ],
      [
        { origin: "host", path: join(fixture.skillDir, "SKILL.md") },
        join(fixture.skillDir, "SKILL.md"),
      ],
      [{ origin: "host", path: "~/.pi/agent/SYSTEM.md" }, join(fixture.agentDir, "SYSTEM.md")],
      [{ origin: "host", path: "~/notebook/tasks.org" }, join(fixture.notebook, "tasks.org")],
      [
        { origin: "session", sessionId: "sandbox-session", path: "report.md" },
        join(fixture.sandboxMount, "report.md"),
      ],
    ] as const) {
      const read = editAnswer(await call(fixture, "GET", way));
      expect(read.origin, JSON.stringify(way)).toBeDefined();
      const origin = read.origin as Record<string, string>;

      const saved = await put(fixture, origin, "first edit\n", read.etag as string);
      expect(saved.statusCode, JSON.stringify(origin)).toBe(200);
      expect(readFileSync(file, "utf8")).toBe("first edit\n");

      // The tag the link's read returned is stale now: a second writer that
      // read before the save is refused and the file keeps the first edit.
      const stale = await put(fixture, origin, "second edit\n", read.etag as string);
      expect(stale.statusCode, JSON.stringify(origin)).toBe(412);
      expect(readFileSync(file, "utf8")).toBe("first edit\n");

      // The reread through the original link sees the save's tag.
      const reread = editAnswer(await call(fixture, "GET", way));
      expect(reread.etag).toBe(JSON.parse(saved.body.toString("utf8")).etag);
    }
  });

  it("refuses protected home files, the data and Pi directories, and paths outside the home", async () => {
    const fixture = seed();
    const protectedFiles = [
      join(fixture.home, ".ssh", "notes.md"),
      join(fixture.home, ".aws", "config.json"),
      join(fixture.home, ".config", "gh", "hosts.yml"),
      join(fixture.notebook, ".env.md"),
      join(fixture.notebook, "auth.json"),
      join(fixture.notebook, ".git", "notes.md"),
      join(fixture.dataDir, "config.json"),
      join(fixture.agentDir, "settings.json"),
    ];
    for (const file of protectedFiles) {
      mkdirSync(join(file, ".."), { recursive: true });
      writeFileSync(file, "{}\n");
    }
    for (const file of protectedFiles) {
      const read = await call(fixture, "GET", { origin: "host", path: file });
      expect(read.statusCode, file).toBe(200);
      expect(editAnswer(read), file).toEqual({ status: 200, refusal: "protected" });
      // A client that writes anyway is refused before the body is read.
      const write = await call(
        fixture,
        "PUT",
        { origin: "host", path: file },
        { body: "x\n", headers: { "if-match": `"sha256-${"0".repeat(64)}"` }, resolve: false },
      );
      expect(write.statusCode, file).toBe(403);
      expect(readFileSync(file, "utf8")).toBe("{}\n");
    }

    const outside = await call(fixture, "GET", {
      origin: "host",
      path: join(fixture.outside, "elsewhere.md"),
    });
    expect(editAnswer(outside)).toEqual({ status: 200, refusal: "outside-home" });
    writeFileSync(join(fixture.notebook, "scan.bin"), Buffer.from([0, 1, 2]));
    expect(
      editAnswer(await call(fixture, "GET", { origin: "host", path: "~/notebook/scan.bin" })),
    ).toEqual({ status: 200, refusal: "type" });
  });

  it("follows folder links to the canonical file and refuses links that escape or are the file", async () => {
    const fixture = seed();
    mkdirSync(join(fixture.home, ".ssh"));
    writeFileSync(join(fixture.home, ".ssh", "keys.md"), "secret\n");
    // Folder links into a protected directory and out of the home.
    symlinkSync(join(fixture.home, ".ssh"), join(fixture.notebook, "keys"));
    symlinkSync(fixture.outside, join(fixture.notebook, "outside"));
    // A file link to an editable file: the link's own name never edits.
    symlinkSync(join(fixture.notebook, "tasks.org"), join(fixture.notebook, "alias.org"));

    expect(
      editAnswer(await call(fixture, "GET", { origin: "host", path: "~/notebook/keys/keys.md" })),
    ).toEqual({ status: 200, refusal: "protected" });
    expect(
      editAnswer(
        await call(fixture, "GET", { origin: "host", path: "~/notebook/outside/elsewhere.md" }),
      ),
    ).toEqual({ status: 200, refusal: "outside-home" });
    expect(
      editAnswer(await call(fixture, "GET", { origin: "host", path: "~/notebook/alias.org" })),
    ).toEqual({ status: 200, refusal: "ineligible" });
    // The target itself, by its own name, edits.
    const target = editAnswer(
      await call(fixture, "GET", { origin: "host", path: "~/notebook/tasks.org" }),
    );
    expect(target.origin).toEqual({ origin: "host", path: join(fixture.notebook, "tasks.org") });

    const tag = target.etag as string;
    for (const [path, status] of [
      [join(fixture.notebook, "keys", "keys.md"), 403],
      [join(fixture.notebook, "outside", "elsewhere.md"), 403],
      // A write through the link itself: the final name is a symlink.
      [join(fixture.notebook, "alias.org"), 403],
    ] as const) {
      const write = await call(
        fixture,
        "PUT",
        { origin: "host", path },
        { body: "overwritten\n", headers: { "if-match": tag }, resolve: false },
      );
      expect(write.statusCode, path).toBe(status);
    }
    expect(readFileSync(join(fixture.home, ".ssh", "keys.md"), "utf8")).toBe("secret\n");
    expect(readFileSync(join(fixture.outside, "elsewhere.md"), "utf8")).toBe("outside the home\n");
    expect(readFileSync(join(fixture.notebook, "tasks.org"), "utf8")).toBe(
      "* TODO Write the design\n",
    );
  });

  it("writes a file a narrower origin owns only through that origin", async () => {
    const fixture = seed();
    const read = editAnswer(
      await call(fixture, "GET", { origin: "host", path: join(fixture.project, "README.md") }),
    );
    const write = await call(
      fixture,
      "PUT",
      { origin: "host", path: join(fixture.project, "README.md") },
      { body: "via host\n", headers: { "if-match": read.etag as string }, resolve: false },
    );
    expect(write.statusCode).toBe(409);
    expect(readFileSync(join(fixture.project, "README.md"), "utf8")).toBe("# Project\n");
  });

  it("keeps a sandbox session's links inside its sandbox", async () => {
    const fixture = seed();
    // A host workspace on the same folder wins the id tie for a host link, but
    // a read in the sandbox's context only ever names the sandbox.
    fixture.workspaces.push({
      id: "ws-a-same-folder",
      name: "same folder",
      hostMount: fixture.sandboxMount,
      createdAt: 1,
      updatedAt: 1,
    } as Workspace);
    expect(
      editAnswer(
        await call(fixture, "GET", {
          origin: "host",
          path: join(fixture.sandboxMount, "report.md"),
        }),
      ).origin,
    ).toEqual({ origin: "workspace", workspaceId: "ws-a-same-folder", path: "report.md" });
    // The sandbox's own file edits as the sandbox workspace, by guest path or
    // mount-relative path, through the session or the workspace.
    for (const way of [
      { origin: "session", sessionId: "sandbox-session", path: "/workspace/research/report.md" },
      { origin: "session", sessionId: "sandbox-session", path: "report.md" },
      { origin: "workspace", workspaceId: "ws-sandbox", path: "report.md" },
    ]) {
      const answer = editAnswer(await call(fixture, "GET", way));
      expect(answer.origin, JSON.stringify(way)).toEqual({
        origin: "workspace",
        workspaceId: "ws-sandbox",
        path: "report.md",
      });
      // Never the host path of the mount.
      expect(JSON.stringify(answer)).not.toContain(fixture.sandboxMount);
    }

    // A host file named from the sandbox context is not even read, let alone
    // offered for editing, and a link planted in the mount does not escape.
    symlinkSync(join(fixture.notebook, "tasks.org"), join(fixture.sandboxMount, "tasks.org"));
    for (const path of [
      join(fixture.notebook, "tasks.org"),
      "~/notebook/tasks.org",
      "tasks.org",
      "../../notebook/tasks.org",
    ]) {
      const read = await call(fixture, "GET", {
        origin: "session",
        sessionId: "sandbox-session",
        path,
      });
      expect(read.statusCode, path).toBe(403);
      expect(read.headers["X-Oppi-Edit-Origin"], path).toBeUndefined();
    }
  });

  it("answers older clients exactly as before when they do not ask", async () => {
    const fixture = seed();
    const workspace = await call(
      fixture,
      "GET",
      { origin: "workspace", workspaceId: "ws-project", path: "README.md" },
      { resolve: false },
    );
    expect(workspace.headers.ETag).toBeDefined();
    expect(workspace.headers["X-Oppi-Edit-Origin"]).toBeUndefined();

    const host = await call(
      fixture,
      "GET",
      { origin: "host", path: "~/notebook/tasks.org" },
      { resolve: false },
    );
    expect(host.statusCode).toBe(200);
    expect(host.headers.ETag).toBeUndefined();
    expect(host.headers["X-Oppi-Edit-Origin"]).toBeUndefined();
  });
});

/** Whether the temp volume ignores case, as macOS volumes usually do. */
const caseInsensitiveTmp = (() => {
  const probe = mkdtempSync(join(tmpdir(), "oppi-case-probe-"));
  try {
    return existsSync(probe.toUpperCase());
  } finally {
    rmSync(probe, { recursive: true, force: true });
  }
})();

/** The tag a read of `file` would carry. */
function etagOf(file: string): string {
  return `"sha256-${createHash("sha256").update(readFileSync(file)).digest("hex")}"`;
}

/** A host write with the file's current tag: refused only by the rule under test. */
function hostWrite(
  fixture: Fixture,
  path: string,
  body: string,
  options: { etag?: string; principal?: RequestPrincipal | null } = {},
) {
  return call(
    fixture,
    "PUT",
    { origin: "host", path },
    {
      body,
      headers: { "if-match": options.etag ?? etagOf(path) },
      resolve: false,
      ...(options.principal !== undefined ? { principal: options.principal } : {}),
    },
  );
}

/** One assertion for "this home file has no editor": the read says why, a write changes nothing. */
async function expectNotEditable(fixture: Fixture, file: string, refusal: string) {
  const before = readFileSync(file, "utf8");
  const read = editAnswer(await call(fixture, "GET", { origin: "host", path: file }));
  expect(read, file).toEqual({ status: 200, refusal });
  const write = await hostWrite(fixture, file, "overwritten\n");
  expect(write.statusCode, file).not.toBe(200);
  expect(readFileSync(file, "utf8"), file).toBe(before);
}

describe("home files that run code or hold credentials", () => {
  it("refuses shell startup, PATH programs, packages, tool hooks, and ~/Library", async () => {
    const fixture = seed();
    const files = [
      ".config/fish/config.fish",
      ".config/fish/conf.d/aliases.fish",
      ".oh-my-zsh/custom/aliases.zsh",
      "bin/deploy.py",
      ".local/bin/sync.py",
      ".local/lib/python3.13/site-packages/requests/__init__.py",
      "Library/Python/3.13/lib/python/site-packages/sitecustomize.py",
      "notebook/tools/node_modules/left-pad/index.js",
      "notebook/tools/.venv/pyvenv.cfg",
      "notebook/sitecustomize.py",
      ".bun/install/global/node_modules/cli/index.js",
      ".bunfig.toml",
      "notebook/bunfig.toml",
      ".claude/settings.json",
      ".claude.json",
      ".codex/config.toml",
      ".cursor/mcp.json",
      ".config/nvim/init.lua",
      ".hammerspoon/init.lua",
      "Library/Application Support/Code/User/settings.json",
      "Library/Application Support/Claude/claude_desktop_config.json",
      "Library/LaunchAgents/local.job.xml",
      // Credentials by name, anywhere.
      "notebook/.credentials.json",
      "notebook/token.json",
      "notebook/oauth-tokens.json",
      ".terraform.d/credentials.tfrc.json",
      // Case-folded: a volume that ignores case reads these as the protected names.
      ".SSH/notes.md",
      "notebook/AUTH.JSON",
      ".Config/Fish/config.fish",
    ].map((path) => join(fixture.home, path));
    for (const file of files) {
      mkdirSync(join(file, ".."), { recursive: true });
      writeFileSync(file, "x = 1\n");
    }
    for (const file of files) await expectNotEditable(fixture, file, "protected");

    // iCloud Drive is the owner's documents, not app state.
    const icloud = join(
      fixture.home,
      "Library",
      "Mobile Documents",
      "com~apple~CloudDocs",
      "notes.md",
    );
    mkdirSync(join(icloud, ".."), { recursive: true });
    writeFileSync(icloud, "# Notes\n");
    const read = editAnswer(await call(fixture, "GET", { origin: "host", path: icloud }));
    expect(read.origin).toEqual({ origin: "host", path: icloud });
    expect((await hostWrite(fixture, icloud, "# Edited\n")).statusCode).toBe(200);
    expect(readFileSync(icloud, "utf8")).toBe("# Edited\n");
  });

  it("refuses an executable and a file with a second hard link", async () => {
    const fixture = seed();
    const script = join(fixture.notebook, "backup.sh");
    writeFileSync(script, "#!/bin/sh\necho backup\n");
    chmodSync(script, 0o755);
    await expectNotEditable(fixture, script, "ineligible");

    // A second name for a protected file is a different path to the same
    // inode; the editor would also split the link on save.
    mkdirSync(join(fixture.home, ".ssh"));
    const secret = join(fixture.home, ".ssh", "keys.md");
    writeFileSync(secret, "secret\n");
    const alias = join(fixture.notebook, "keys.md");
    linkSync(secret, alias);
    await expectNotEditable(fixture, alias, "ineligible");
    expect(readFileSync(secret, "utf8")).toBe("secret\n");

    // The same rule holds when the bit appears between the read and the write.
    const notes = join(fixture.notebook, "tasks.org");
    const tag = editAnswer(await call(fixture, "GET", { origin: "host", path: notes })).etag;
    chmodSync(notes, 0o744);
    expect((await hostWrite(fixture, notes, "x\n", { etag: tag })).statusCode).not.toBe(200);
    expect(readFileSync(notes, "utf8")).toBe("* TODO Write the design\n");
  });

  it("keeps a package Skill's files read-only through the home", async () => {
    const fixture = seed();
    await expectNotEditable(fixture, join(fixture.packageSkillDir, "SKILL.md"), "protected");
  });

  it.runIf(caseInsensitiveTmp)(
    "refuses the data directory when its configured path differs in case",
    async () => {
      const fixture = seed();
      const config = join(fixture.dataDir, "devices.json");
      writeFileSync(config, "{}\n");
      // The server was configured with another spelling of the same folder.
      fixture.dataDir = join(fixture.home, "OPPI-DATA");
      await expectNotEditable(fixture, config, "protected");
    },
  );

  it("refuses a path with `..` after a folder link", async () => {
    const fixture = seed();
    // `~/inbox` links to `~/notebook/today`, so the kernel reads
    // `~/inbox/../tasks.org` as `~/notebook/tasks.org`, while the same text,
    // normalized, names `~/tasks.org`: two different files.
    mkdirSync(join(fixture.notebook, "today"));
    symlinkSync(join(fixture.notebook, "today"), join(fixture.home, "inbox"));
    const decoy = join(fixture.home, "tasks.org");
    writeFileSync(decoy, "home copy\n");
    const path = `${fixture.home}/inbox/../tasks.org`;
    for (const etag of [etagOf(decoy), etagOf(join(fixture.notebook, "tasks.org"))]) {
      expect((await hostWrite(fixture, path, "x\n", { etag })).statusCode).toBe(403);
    }
    expect(readFileSync(decoy, "utf8")).toBe("home copy\n");
    expect(readFileSync(join(fixture.notebook, "tasks.org"), "utf8")).toBe(
      "* TODO Write the design\n",
    );
  });

  it("confines a host path through a link planted in a sandbox mount", async () => {
    const fixture = seed();
    // The sandbox guest writes its mount, so it chose where these lead.
    symlinkSync(fixture.notebook, join(fixture.sandboxMount, "notes"));
    symlinkSync(join(fixture.home, ".config"), join(fixture.sandboxMount, "config"));
    mkdirSync(join(fixture.home, ".config", "tool"), { recursive: true });
    writeFileSync(join(fixture.home, ".config", "tool", "settings.json"), "{}\n");
    // The owner's own link to the sandbox folder does not launder them.
    symlinkSync(fixture.sandboxMount, join(fixture.home, "research"));
    for (const path of [
      join(fixture.sandboxMount, "notes", "tasks.org"),
      join(fixture.sandboxMount, "config", "tool", "settings.json"),
      join(fixture.home, "research", "notes", "tasks.org"),
      "~/research/notes/tasks.org",
    ]) {
      const read = editAnswer(await call(fixture, "GET", { origin: "host", path }));
      expect(read, path).toEqual({ status: 200, refusal: "outside-home" });
      const write = await hostWrite(fixture, path, "x\n", {
        etag: etagOf(join(fixture.notebook, "tasks.org")),
      });
      expect(write.statusCode, path).toBe(403);
    }
    expect(readFileSync(join(fixture.notebook, "tasks.org"), "utf8")).toBe(
      "* TODO Write the design\n",
    );
    // A sandbox file reached through the owner's link is still the sandbox's.
    expect(
      editAnswer(await call(fixture, "GET", { origin: "host", path: "~/research/report.md" }))
        .origin,
    ).toEqual({ origin: "workspace", workspaceId: "ws-sandbox", path: "report.md" });
    // The same file by its own path is an ordinary home file.
    expect(
      editAnswer(await call(fixture, "GET", { origin: "host", path: "~/notebook/tasks.org" }))
        .origin,
    ).toEqual({ origin: "host", path: join(fixture.notebook, "tasks.org") });
  });

  it("writes a home file only for the owner or a paired device", async () => {
    const fixture = seed();
    const notes = join(fixture.notebook, "tasks.org");
    expect((await hostWrite(fixture, notes, "x\n", { principal: null })).statusCode).toBe(403);
    expect(readFileSync(notes, "utf8")).toBe("* TODO Write the design\n");
    const device = await hostWrite(fixture, notes, "from the phone\n", {
      principal: { kind: "device", deviceId: "dev-1", tokenClass: "at_" },
    });
    expect(device.statusCode).toBe(200);
    expect(readFileSync(notes, "utf8")).toBe("from the phone\n");
  });

  it("keeps home files read-only when the owner turns host editing off", async () => {
    const fixture = seed();
    fixture.config = { fileEditing: { hostFiles: false } };
    await expectNotEditable(fixture, join(fixture.notebook, "tasks.org"), "disabled");
    // Every other origin still edits.
    const read = editAnswer(
      await call(fixture, "GET", { origin: "host", path: join(fixture.project, "README.md") }),
    );
    expect(read.origin).toEqual({
      origin: "workspace",
      workspaceId: "ws-project",
      path: "README.md",
    });
    expect(
      (await put(fixture, read.origin as Record<string, string>, "ok\n", read.etag as string))
        .statusCode,
    ).toBe(200);
  });
});
