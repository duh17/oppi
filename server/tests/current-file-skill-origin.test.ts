import { createHash } from "node:crypto";
import { once } from "node:events";
import {
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

import { afterEach, describe, expect, it } from "vitest";

import { createHostFileRoutes } from "../src/routes/host-files.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { ServerResourceService } from "../src/server-resource-service.js";
import { makeRawRequest, MockWritableResponse } from "./harness/route-test-helpers.js";

interface Fixture {
  root: string;
  agentDir: string;
  dataDir: string;
  service: ServerResourceService;
}

const roots: string[] = [];
const originalHome = process.env.HOME;
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalOffline = process.env.PI_OFFLINE;

afterEach(() => {
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
  if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
  if (originalOffline === undefined) delete process.env.PI_OFFLINE;
  else process.env.PI_OFFLINE = originalOffline;
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function writeSkill(baseDir: string, name: string): string {
  const skillDir = join(baseDir, name);
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(
    join(skillDir, "SKILL.md"),
    ["---", `name: ${name}`, `description: ${name} description`, "---", `# ${name}`, ""].join("\n"),
  );
  return skillDir;
}

function seed(): Fixture {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "oppi-skill-source-")));
  roots.push(root);
  const homeDir = join(root, "home");
  const agentDir = join(homeDir, ".pi", "agent");
  const dataDir = join(root, "data");
  mkdirSync(agentDir, { recursive: true });
  mkdirSync(dataDir, { recursive: true });
  process.env.HOME = homeDir;
  process.env.PI_CODING_AGENT_DIR = agentDir;
  process.env.PI_OFFLINE = "1";
  return { root, agentDir, dataDir, service: new ServerResourceService({ dataDir, agentDir }) };
}

async function skillId(fixture: Fixture, name: string): Promise<string> {
  const skill = (await fixture.service.listSkills()).skills.find((entry) => entry.name === name);
  if (!skill) throw new Error(`missing skill ${name}`);
  return skill.id;
}

function etagFor(bytes: Buffer | string): string {
  return `"sha256-${createHash("sha256").update(bytes).digest("hex")}"`;
}

async function call(
  fixture: Fixture,
  method: "GET" | "PUT",
  id: string,
  path: string,
  body?: Buffer,
  headers: Record<string, string> = {},
): Promise<MockWritableResponse> {
  const dispatch = createHostFileRoutes(
    {
      storage: { getDataDir: () => fixture.dataDir },
      serverResources: fixture.service,
    } as unknown as RouteContext,
    createRouteHelpers(),
  );
  const res = new MockWritableResponse();
  const finished = once(res, "finish");
  const query = new URLSearchParams({ origin: "skill", skillId: id, path });
  const url = new URL(`https://localhost/files/current?${query}`);
  const req = body ? makeRawRequest(body) : ({} as IncomingMessage);
  req.headers = body ? { "content-length": String(body.length), ...headers } : headers;
  const handled = await dispatch({
    method,
    path: url.pathname,
    url,
    req,
    res: res as unknown as ServerResponse,
  });
  expect(handled).toBe(true);
  if (!res.writableEnded) await finished;
  return res;
}

function errorOf(res: MockWritableResponse): string {
  return (JSON.parse(res.body.toString("utf8")) as { error: string }).error;
}

describe("/files/current?origin=skill", () => {
  it("reads with a tag, writes with If-Match, and refuses stale or missing tags", async () => {
    const fixture = seed();
    const skillDir = writeSkill(join(fixture.agentDir, "skills"), "notes");
    mkdirSync(join(skillDir, "refs"));
    writeFileSync(join(skillDir, "refs", "guide.md"), "guide\n");
    const id = await skillId(fixture, "notes");

    const read = await call(fixture, "GET", id, "SKILL.md");
    expect(read.statusCode).toBe(200);
    const original = readFileSync(join(skillDir, "SKILL.md"));
    expect(read.body.equals(original)).toBe(true);
    expect(read.headers.ETag).toBe(etagFor(original));

    const missingTag = await call(fixture, "PUT", id, "SKILL.md", Buffer.from("x"));
    expect(missingTag.statusCode).toBe(428);

    const edited = Buffer.from(original.toString("utf8").replace("# notes", "# notes v2"));
    const saved = await call(fixture, "PUT", id, "SKILL.md", edited, {
      "if-match": read.headers.ETag,
    });
    expect(saved.statusCode).toBe(200);
    expect(JSON.parse(saved.body.toString("utf8"))).toMatchObject({
      etag: etagFor(edited),
      size: edited.length,
    });
    expect(readFileSync(join(skillDir, "SKILL.md")).equals(edited)).toBe(true);

    // The first tag no longer matches disk.
    const stale = await call(fixture, "PUT", id, "SKILL.md", Buffer.from("lost\n"), {
      "if-match": read.headers.ETag,
    });
    expect(stale.statusCode).toBe(412);
    expect(readFileSync(join(skillDir, "SKILL.md")).equals(edited)).toBe(true);

    // Every file in the Skill's directory edits through the same contract.
    const nested = await call(fixture, "GET", id, "refs/guide.md");
    const nestedSaved = await call(fixture, "PUT", id, "refs/guide.md", Buffer.from("guide 2\n"), {
      "if-match": nested.headers.ETag,
    });
    expect(nestedSaved.statusCode).toBe(200);
    expect(readFileSync(join(skillDir, "refs", "guide.md"), "utf8")).toBe("guide 2\n");
  });

  it("never writes outside the Skill, through a symlink, or creates a file", async () => {
    const fixture = seed();
    const skillsDir = join(fixture.agentDir, "skills");
    const skillDir = writeSkill(skillsDir, "guarded");
    writeSkill(skillsDir, "neighbor");
    const outside = join(fixture.root, "outside.md");
    writeFileSync(outside, "outside\n");
    symlinkSync(outside, join(skillDir, "link.md"));
    const id = await skillId(fixture, "guarded");
    const anyTag = etagFor("outside\n");

    for (const path of ["../neighbor/SKILL.md", "/etc/hosts", "link.md", "new.md"]) {
      const res = await call(fixture, "PUT", id, path, Buffer.from("owned\n"), {
        "if-match": anyTag,
      });
      expect(res.statusCode).toBe(404);
      // Nor read anything outside the Skill through it.
      if (path !== "link.md") expect((await call(fixture, "GET", id, path)).statusCode).toBe(404);
    }
    expect(readFileSync(outside, "utf8")).toBe("outside\n");
    expect(readFileSync(join(skillsDir, "neighbor", "SKILL.md"), "utf8")).toContain("# neighbor");

    // A symlinked file stays readable as before, but untagged: not editable.
    const linked = await call(fixture, "GET", id, "link.md");
    expect(linked.statusCode).toBe(200);
    expect(linked.body.toString("utf8")).toBe("outside\n");
    expect(linked.headers.ETag).toBeUndefined();
  });

  it("keeps a single-file Skill to that file and package Skills read-only", async () => {
    const fixture = seed();
    const skillsDir = join(fixture.agentDir, "skills");
    mkdirSync(skillsDir, { recursive: true });
    writeFileSync(
      join(skillsDir, "solo.md"),
      ["---", "name: solo", "description: solo description", "---", "# solo", ""].join("\n"),
    );
    writeSkill(skillsDir, "sibling");

    const packageDir = join(fixture.root, "package");
    writeSkill(join(packageDir, "skills"), "packaged");
    writeFileSync(
      join(packageDir, "package.json"),
      JSON.stringify({
        name: "skill-package",
        version: "1.0.0",
        pi: { skills: ["skills/packaged/SKILL.md"] },
      }),
    );
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ packages: [packageDir] }),
    );

    const solo = await skillId(fixture, "solo");
    const soloRead = await call(fixture, "GET", solo, "solo.md");
    expect(soloRead.statusCode).toBe(200);
    expect(soloRead.headers.ETag).toBeDefined();
    // The single-file Skill's directory holds other Skills; they are not its files.
    const sibling = await call(fixture, "GET", solo, "sibling/SKILL.md");
    expect(sibling.statusCode).toBe(404);

    const packaged = await skillId(fixture, "packaged");
    const packagedRead = await call(fixture, "GET", packaged, "SKILL.md");
    expect(packagedRead.statusCode).toBe(403);
    expect(errorOf(packagedRead)).toBe("Skill is read-only");
    const before = readFileSync(join(packageDir, "skills", "packaged", "SKILL.md"));
    const packagedWrite = await call(fixture, "PUT", packaged, "SKILL.md", Buffer.from("x"), {
      "if-match": etagFor(before),
    });
    expect(packagedWrite.statusCode).toBe(403);
    expect(readFileSync(join(packageDir, "skills", "packaged", "SKILL.md")).equals(before)).toBe(
      true,
    );
  });
});
