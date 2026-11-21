import { EventEmitter } from "node:events";
import { cpSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { applyImmutable, type Op } from "@earendil-works/chord/delta";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import {
  bindOppiHost,
  type OppiDurableHost,
  type OppiSkillsHost,
} from "../src/durable-extension-api.js";
import { PluginHost } from "../src/plugin-host.js";
import { checkScreenPage } from "../src/plugin-screens.js";
import { ScreensStreamMux } from "../src/screens-stream.js";
import { ServerResourceNotFoundError } from "../src/server-resource-service.js";
import type { ServerSkillSummary } from "../src/server-resource-service.js";
import { SERVER_FEATURE_PRESETS } from "../src/server-features.js";
import type { ScreenPage, ScreensClientMessage, ScreensServerMessage } from "../src/types.js";
import { filesPage } from "../plugins/skills-screen/pages.js";
import { makeTempDir } from "./harness/temp-dir.js";

const id = (name: string): string => `skill_${name.padEnd(64, "0").slice(0, 64)}`;

function summary(name: string, overrides: Partial<ServerSkillSummary> = {}): ServerSkillSummary {
  return {
    id: id(name.replace(/[^a-f0-9]/g, "a")),
    name,
    description: `${name} does things`,
    provenance: { kind: "piAgent", label: "~/.pi/agent/skills" },
    path: `/Users/alex/.pi/agent/skills/${name}/SKILL.md`,
    paths: [`/Users/alex/.pi/agent/skills/${name}/SKILL.md`],
    selectionPath: `/Users/alex/.pi/agent/skills/${name}/SKILL.md`,
    state: "enabled",
    warnings: [],
    editable: true,
    ...overrides,
  };
}

/** The server's Skills catalog as the plugin sees it, in memory. */
const catalog: ServerSkillSummary[] = [];
const files: Record<string, string[]> = {};
const writes: unknown[][] = [];
const skillsHost = {
  listSkills: async () => ({ skills: structuredClone(catalog) }),
  getSkillDetail: async (skillId: string) => {
    const found = catalog.find((skill) => skill.id === skillId);
    if (!found) throw new ServerResourceNotFoundError("skill");
    return { summary: structuredClone(found), skillMarkdown: "# x", files: files[skillId] ?? [] };
  },
  setSkillEnabled: async (skillId: string, enabled: boolean) => {
    writes.push(["enabled", skillId, enabled]);
    const found = catalog.find((skill) => skill.id === skillId)!;
    found.state = enabled ? "enabled" : "disabled";
    return structuredClone(found);
  },
} as unknown as OppiSkillsHost;

bindOppiHost({
  files: { internalUrls: {} },
  mcp: () => undefined,
  skills: () => skillsHost,
} as unknown as OppiDurableHost);

let host: PluginHost;
beforeAll(async () => {
  const base = makeTempDir("oppi-skills-screen-");
  const builtInDir = join(base, "built-in");
  mkdirSync(builtInDir, { recursive: true });
  writeFileSync(
    join(builtInDir, "package.json"),
    JSON.stringify({
      name: "test-built-ins",
      private: true,
      chord: { plugins: ["./skills-screen"] },
    }),
  );
  cpSync(
    fileURLToPath(new URL("../plugins/skills-screen", import.meta.url)),
    join(builtInDir, "skills-screen"),
    { recursive: true },
  );
  host = new PluginHost({
    builtInDir,
    agentDir: join(base, "agent"),
    required: new Set(),
    core: { first: [CodingTools], afterBuiltIns: [] },
  });
  expect((await host.load()).errors).toEqual([]);
});
afterAll(() => host.close());

class FakeSocket extends EventEmitter {
  readonly OPEN = 1;
  readyState = 1;
  readonly sent: ScreensServerMessage[] = [];
  send(text: string): void {
    this.sent.push(JSON.parse(text) as ScreensServerMessage);
  }
}

function connect() {
  const mux = new ScreensStreamMux({
    screens: async () => host.screens(),
    features: () => SERVER_FEATURE_PRESETS.all,
    workspaceExists: () => true,
  });
  const ws = new FakeSocket();
  mux.handleWebSocket(ws as never);
  const send = (message: ScreensClientMessage) =>
    ws.emit("message", Buffer.from(JSON.stringify(message)), false);
  const page = (watch: string): ScreenPage | undefined => {
    let value: unknown;
    for (const message of ws.sent) {
      if (message.type === "value" && message.watch === watch) value = message.value;
      if (message.type === "ops" && message.watch === watch)
        value = applyImmutable(value, message.ops as Op[]);
    }
    return value as ScreenPage | undefined;
  };
  const watch = (watchId: string, pageId: string) =>
    send({
      type: "watch",
      watch: watchId,
      entry: "oppi.skills",
      scope: "server",
      page: pageId,
      v: 1,
    });
  return { ws, send, page, watch };
}

const section = (page: ScreenPage | undefined, sectionId: string) =>
  page?.sections.find((candidate) => candidate.id === sectionId);

describe("Skills plugin screen", () => {
  it("groups the catalog by what needs attention, switches a Skill, and the list follows", async () => {
    const release = summary("release");
    const broken = summary("broken", { state: "error", loadError: "Missing name" });
    const docs = summary("docs", { state: "disabled", packageName: "@acme/docs" });
    catalog.splice(0, catalog.length, release, broken, docs);
    const c = connect();
    c.watch("list", "list");
    await vi.waitFor(() =>
      expect(c.page("list")?.sections.map((s) => [s.header, s.rows.map((r) => r.id)])).toEqual([
        ["Needs Attention", [`skill.${broken.id}`]],
        ["Enabled", [`skill.${release.id}`]],
        ["Disabled", [`skill.${docs.id}`]],
      ]),
    );
    expect(c.page("list")?.search).toEqual({ prompt: "Search skills" });
    expect(section(c.page("list"), "disabled")?.rows[0]).toMatchObject({
      kind: "item",
      symbol: "sparkles.rectangle.stack",
      subtitle: "docs does things\n@acme/docs\n~/.pi/agent/skills",
      status: { text: "Disabled" },
      push: `skill/${docs.id}`,
    });

    c.watch("detail", `skill/${release.id}`);
    await vi.waitFor(() => expect(c.page("detail")?.title).toBe("release"));
    expect(section(c.page("detail"), "contents")?.rows[0]).toMatchObject({
      push: `files/${release.id}`,
    });
    c.send({
      type: "act",
      watch: "detail",
      call: "c1",
      action: "enabled",
      row: "enabled",
      values: [{ field: "enabled", value: false }],
    });
    await vi.waitFor(() =>
      expect(c.ws.sent).toContainEqual({ type: "result", call: "c1", ok: true }),
    );
    expect(writes.at(-1)).toEqual(["enabled", release.id, false]);
    await vi.waitFor(() =>
      expect(section(c.page("detail"), "default")?.rows[0]).toMatchObject({ value: false }),
    );
    // The list under it reads again on its own and moves the Skill.
    await vi.waitFor(
      () =>
        expect(section(c.page("list"), "disabled")?.rows.map((r) => r.id)).toContain(
          `skill.${release.id}`,
        ),
      { timeout: 3000 },
    );

    // A broken Skill's switch is off-limits and its page says why.
    c.watch("broken", `skill/${broken.id}`);
    await vi.waitFor(() =>
      expect(section(c.page("broken"), "default")?.rows[0]).toMatchObject({ disabled: true }),
    );
    expect(section(c.page("broken"), "validation")?.rows[1]).toMatchObject({
      text: "Missing name",
      tone: "danger",
    });

    // A Skill that leaves the catalog closes its page.
    catalog.splice(catalog.indexOf(docs), 1);
    c.watch("gone", `skill/${docs.id}`);
    await vi.waitFor(() =>
      expect(c.ws.sent).toContainEqual({ type: "ended", watch: "gone", reason: "gone" }),
    );
    c.ws.emit("close");
  });

  it("lists a Skill's files by folder, each file a host path the app opens", async () => {
    const release = summary("release");
    catalog.splice(0, catalog.length, release);
    files[release.id] = [
      "SKILL.md",
      "scripts/check.sh",
      "scripts/lib/util.sh",
      "references/a b.md",
    ];
    const c = connect();
    c.watch("root", `files/${release.id}`);
    await vi.waitFor(() =>
      expect(
        c
          .page("root")
          ?.sections[0]?.rows.map((r) => [r.id, r.kind === "item" && (r.push ?? r.file)]),
      ).toEqual([
        ["folder.references", `files/${release.id}/references`],
        ["folder.scripts", `files/${release.id}/scripts`],
        ["file.SKILL.md", "/Users/alex/.pi/agent/skills/release/SKILL.md"],
      ]),
    );
    c.watch("lib", `files/${release.id}/${encodeURIComponent("scripts/lib")}`);
    await vi.waitFor(() =>
      expect(c.page("lib")).toMatchObject({
        title: "lib",
        sections: [
          {
            rows: [
              {
                id: "file.util.sh",
                file: "/Users/alex/.pi/agent/skills/release/scripts/lib/util.sh",
              },
            ],
          },
        ],
      }),
    );
    c.watch("missing", `files/${release.id}/nowhere`);
    await vi.waitFor(() =>
      expect(c.ws.sent).toContainEqual({ type: "ended", watch: "missing", reason: "gone" }),
    );
    c.ws.emit("close");

    // A top-level Markdown Skill's files sit beside it.
    const flat = summary("flat", { path: "/Users/alex/.pi/agent/skills/flat.md" });
    const page = filesPage(
      { value: { summary: flat, skillMarkdown: "", files: ["flat.md"] } },
      flat.id,
      "",
    ) as ScreenPage;
    expect(page.sections[0]?.rows[0]).toMatchObject({
      file: "/Users/alex/.pi/agent/skills/flat.md",
    });
  });

  it("checks the item targets, symbol and search the vocabulary adds", () => {
    const page = (row: object, extra: object = {}) =>
      checkScreenPage({
        title: "t",
        sections: [{ id: "s", rows: [{ kind: "item", id: "i", title: "x", ...row }] }],
        ...extra,
      });
    expect(page({ file: "/tmp/a.md", symbol: "folder" }, { search: { prompt: "Find" } })).toBe(
      undefined,
    );
    expect(page({ file: "relative.md" })).toMatch(/file is wrong/);
    expect(page({ push: "p", file: "/a" })).toBe("an item opens one of push, url or file");
    expect(page({ symbol: "not.a.symbol" })).toMatch(/symbol is wrong/);
    expect(page({}, { search: {} })).toBe("search needs a prompt");
  });
});
