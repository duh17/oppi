import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { OPPI_LIFECYCLE_CUSTOM_TYPE } from "../src/lifecycle-journal-extension.js";
import { readSessionTraceOutlineFromFiles } from "../src/trace-outline.js";
import { readSessionTracePageFromFile } from "../src/trace-paging.js";
import {
  buildSessionContext,
  createLiveEntryRendererLookup,
  createLiveEntryRendererSet,
  parseJsonl,
  type CollapsedEntryRenderer,
  type LiveEntryRendererSet,
  type SessionEntry,
  type TraceEvent,
} from "../src/trace.js";

const SENTINEL = "SECRET_SENTINEL_DO_NOT_LEAK_9f3a";
const TIMESTAMP = "2026-09-02T00:00:00.000Z";

let tmpDir: string | undefined;

afterEach(() => {
  vi.restoreAllMocks();
  if (tmpDir) {
    rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = undefined;
  }
});

function liveRenderers(renderers: Record<string, CollapsedEntryRenderer>): LiveEntryRendererSet {
  const map = new Map(Object.entries(renderers));
  return {
    get: (customType) => map.get(customType),
    version: [...map.keys()].sort().join(","),
  };
}

function titleRenderer(title: string, body?: string): CollapsedEntryRenderer {
  return (_entry, options) => {
    expect(options.expanded).toBe(false);
    return {
      render: () => (body === undefined ? [title] : [title, body]),
    };
  };
}

function customEntry(
  id: string,
  parentId: string | null,
  customType: string,
  data: unknown = { secret: SENTINEL },
): SessionEntry {
  return {
    type: "custom",
    id,
    parentId,
    timestamp: TIMESTAMP,
    customType,
    data,
  };
}

function userEntry(id: string, parentId: string | null, text: string): SessionEntry {
  return {
    type: "message",
    id,
    parentId,
    timestamp: TIMESTAMP,
    message: { role: "user", content: text },
  };
}

function assistantEntry(id: string, parentId: string | null, text: string): SessionEntry {
  return {
    type: "message",
    id,
    parentId,
    timestamp: TIMESTAMP,
    message: { role: "assistant", content: [{ type: "text", text }] },
  };
}

function fixtureEntries(): SessionEntry[] {
  return [
    userEntry("u1", null, "hello"),
    customEntry("c1", "u1", "demo:card"),
    assistantEntry("a1", "c1", "done"),
  ];
}

function branchedFixtureEntries(): SessionEntry[] {
  return [
    userEntry("u1", null, "root"),
    assistantEntry("a1", "u1", "root answer"),
    customEntry("abandoned-c", "a1", "demo:card"),
    assistantEntry("abandoned-a", "abandoned-c", "abandoned answer"),
    userEntry("u2", "a1", "current prompt"),
    customEntry("current-c", "u2", "demo:card"),
    assistantEntry("a2", "current-c", "current answer"),
  ];
}

function writeJsonl(entries: SessionEntry[]): string {
  tmpDir = mkdtempSync(join(tmpdir(), "trace-custom-entry-"));
  const path = join(tmpDir, "session.jsonl");
  writeFileSync(path, entries.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  return path;
}

function serialized(value: unknown): string {
  return JSON.stringify(value);
}

function captureStderr(): { text: () => string } {
  const chunks: string[] = [];
  vi.spyOn(process.stderr, "write").mockImplementation(((chunk: unknown) => {
    chunks.push(String(chunk));
    return true;
  }) as typeof process.stderr.write);
  return { text: () => chunks.join("") };
}

function cardEvent(events: TraceEvent[]): TraceEvent | undefined {
  return events.find((event) => event.id === "c1");
}

describe("custom entry timeline projection", () => {
  it("hides custom entries when no live renderer is registered and never leaks data", () => {
    const logs = captureStderr();
    const events = buildSessionContext(fixtureEntries());
    const wire = serialized(events);

    expect(cardEvent(events)).toBeUndefined();
    expect(events.filter((event) => event.type === "system")).toHaveLength(0);
    expect(events).toHaveLength(2);
    expect(wire).not.toContain(SENTINEL);
    expect(logs.text()).not.toContain(SENTINEL);
  });

  it("projects a live renderer as system + custom presentation without copying data", () => {
    const logs = captureStderr();
    const events = buildSessionContext(fixtureEntries(), {
      entryRenderers: liveRenderers({
        "demo:card": titleRenderer("Card title", "Card body"),
      }),
    });
    const card = cardEvent(events);
    const wire = serialized(events);

    expect(events).toHaveLength(3);
    expect(card).toMatchObject({
      id: "c1",
      type: "system",
      timestamp: TIMESTAMP,
      text: "Card title\n\nCard body",
      presentation: {
        kind: "custom",
        title: "Card title",
        body: "Card body",
      },
    });
    expect(card?.presentation).not.toHaveProperty("accent");
    expect(card?.presentation).not.toHaveProperty("status");
    expect(card?.presentation).not.toHaveProperty("fields");
    expect(card).not.toHaveProperty("data");
    expect(wire).not.toContain(SENTINEL);
    expect(wire).not.toContain('"data"');
    expect(logs.text()).not.toContain(SENTINEL);
  });

  it("keeps the file-only parse path hidden even when JSONL contains custom entries", () => {
    const path = writeJsonl(fixtureEntries());
    const events = parseJsonl(readFileSync(path, "utf8"));

    expect(cardEvent(events)).toBeUndefined();
    expect(serialized(events)).not.toContain(SENTINEL);
    expect(readFileSync(path, "utf8")).toContain(SENTINEL);
  });

  it("does not mutate JSONL while projecting a visible card", () => {
    const path = writeJsonl(fixtureEntries());
    const before = readFileSync(path);

    buildSessionContext(fixtureEntries(), {
      entryRenderers: liveRenderers({ "demo:card": titleRenderer("Visible") }),
    });

    expect(readFileSync(path).equals(before)).toBe(true);
  });

  it("hides reserved oppi-* types even when a renderer is registered", () => {
    const events = buildSessionContext(
      [userEntry("u1", null, "hello"), customEntry("c1", "u1", "oppi-secret")],
      { entryRenderers: liveRenderers({ "oppi-secret": titleRenderer("Should not appear") }) },
    );

    expect(cardEvent(events)).toBeUndefined();
    expect(events.map((event) => event.type)).toEqual(["user"]);
  });

  it("leaves oppi-lifecycle as metadata instead of a custom card", () => {
    const events = buildSessionContext(
      [
        {
          type: "message",
          id: "a1",
          parentId: null,
          timestamp: TIMESTAMP,
          message: {
            role: "assistant",
            content: [{ type: "toolCall", id: "call-1", name: "read", arguments: { path: "x" } }],
          },
        },
        {
          type: "custom",
          id: "life-1",
          parentId: "a1",
          timestamp: TIMESTAMP,
          customType: OPPI_LIFECYCLE_CUSTOM_TYPE,
          data: {
            version: 1,
            event: "tool_execution_start",
            toolCallId: "call-1",
            toolName: "read",
            secret: SENTINEL,
          },
        },
        {
          type: "message",
          id: "r1",
          parentId: "life-1",
          timestamp: TIMESTAMP,
          message: {
            role: "toolResult",
            content: "ok",
            toolCallId: "call-1",
            toolName: "read",
          },
        },
      ],
      {
        entryRenderers: liveRenderers({
          [OPPI_LIFECYCLE_CUSTOM_TYPE]: titleRenderer("Lifecycle card"),
        }),
      },
    );

    expect(events.find((event) => event.id === "life-1")).toBeUndefined();
    expect(events.some((event) => event.presentation?.title === "Lifecycle card")).toBe(false);
    expect(events[1]?.lifecycleBefore).toEqual([
      expect.objectContaining({ id: "life-1", event: "toolStart", toolCallId: "call-1" }),
    ]);
    expect(serialized(events)).not.toContain(SENTINEL);
  });

  it("hides thrown, empty, and oversize renderer output without leaking data", () => {
    const logs = captureStderr();
    const entries = [
      userEntry("u1", null, "hello"),
      customEntry("throw-1", "u1", "demo:throw"),
      customEntry("empty-1", "throw-1", "demo:empty"),
      customEntry("oversize-1", "empty-1", "demo:oversize"),
    ];

    const events = buildSessionContext(entries, {
      entryRenderers: liveRenderers({
        "demo:throw": () => {
          throw new Error(`boom ${SENTINEL}`);
        },
        "demo:empty": () => ({ render: () => ["", "  "] }),
        "demo:oversize": () => ({
          render: () => Array.from({ length: 9 }, (_, index) => `line ${index}`),
        }),
      }),
    });
    const logText = logs.text();

    expect(events.map((event) => event.id)).toEqual(["u1"]);
    expect(serialized(events)).not.toContain(SENTINEL);
    expect(logText).not.toContain(SENTINEL);
  });

  it("reuses widget snapshot sanitizer output for title and body", () => {
    const events = buildSessionContext(fixtureEntries(), {
      entryRenderers: liveRenderers({
        "demo:card": () => ({
          render: () => [
            "Open \x1b]8;;oppi://session/child-1\x07child\x1b]8;;\x07 now",
            "Second line",
          ],
        }),
      }),
    });

    expect(cardEvent(events)?.presentation).toEqual({
      kind: "custom",
      title: "Open child now",
      body: "Second line",
    });
  });

  it("counts a visible projection as 1 and a hidden custom entry as 0", () => {
    const path = writeJsonl(fixtureEntries());
    const hidden = readSessionTracePageFromFile(path, { targetEvents: 10 });
    const visible = readSessionTracePageFromFile(path, {
      targetEvents: 10,
      entryRenderers: liveRenderers({ "demo:card": titleRenderer("Visible card") }),
    });

    expect(hidden.metrics.traceEventCount).toBe(2);
    expect(hidden.trace).toHaveLength(2);
    expect(visible.metrics.traceEventCount).toBe(3);
    expect(visible.trace).toHaveLength(3);
    expect(visible.trace.filter((event) => event.id === "c1")).toHaveLength(1);
  });

  it("makes full, page, outline, and aroundEntryId agree for a live renderer", async () => {
    const path = writeJsonl(fixtureEntries());
    const renderers = liveRenderers({ "demo:card": titleRenderer("Agree title", "Agree body") });

    const full = parseJsonl(readFileSync(path, "utf8"), {
      entryRenderers: renderers,
      view: "full",
    });
    const page = readSessionTracePageFromFile(path, {
      targetEvents: 10,
      entryRenderers: renderers,
    });
    const outline = await readSessionTraceOutlineFromFiles([path], { entryRenderers: renderers });
    const around = readSessionTracePageFromFile(path, {
      aroundEntryId: "c1",
      targetEvents: 10,
      entryRenderers: renderers,
    });

    const fullCard = cardEvent(full);
    const pageCard = cardEvent(page.trace);
    const aroundCard = cardEvent(around.trace);
    const outlineCard = outline.outline.entries.find((entry) => entry.id === "c1");

    expect(fullCard?.type).toBe("system");
    expect(fullCard?.presentation).toEqual({
      kind: "custom",
      title: "Agree title",
      body: "Agree body",
    });
    expect(pageCard).toEqual(fullCard);
    expect(aroundCard).toEqual(fullCard);
    expect(outlineCard).toMatchObject({
      id: "c1",
      kind: "custom",
      summary: "Agree title",
    });
    expect(serialized({ full, page, outline, around })).not.toContain(SENTINEL);
  });

  it("treats aroundEntryId on a hidden custom entry like an unknown id", () => {
    const path = writeJsonl(fixtureEntries());
    const hidden = readSessionTracePageFromFile(path, {
      aroundEntryId: "c1",
      targetEvents: 10,
    });
    const unknown = readSessionTracePageFromFile(path, {
      aroundEntryId: "missing-id",
      targetEvents: 10,
    });

    expect(hidden.trace).toEqual([]);
    expect(hidden.page.staleCursor).toBe(unknown.page.staleCursor);
    expect(serialized(hidden)).not.toContain(SENTINEL);
  });

  it("includes the live renderer set in traceVersion and cursor validation", () => {
    const path = writeJsonl(fixtureEntries());
    const renderersA = liveRenderers({ "demo:card": titleRenderer("A") });
    const renderersB = liveRenderers({
      "demo:card": titleRenderer("A"),
      "other:card": titleRenderer("B"),
    });

    const withA = readSessionTracePageFromFile(path, {
      targetEvents: 1,
      entryRenderers: renderersA,
    });
    const withB = readSessionTracePageFromFile(path, {
      targetEvents: 1,
      entryRenderers: renderersB,
    });
    const reused = readSessionTracePageFromFile(path, {
      cursor: withA.page.olderCursor ?? undefined,
      targetEvents: 1,
      entryRenderers: renderersB,
    });
    const sameSet = readSessionTracePageFromFile(path, {
      cursor: withA.page.olderCursor ?? undefined,
      targetEvents: 1,
      entryRenderers: renderersA,
    });

    expect(withA.page.traceVersion).not.toEqual(withB.page.traceVersion);
    expect(withA.page.traceVersion).toContain(renderersA.version);
    expect(reused.page.staleCursor).toBe(true);
    expect(reused.trace).toEqual([]);
    expect(sameSet.page.staleCursor).toBe(false);
  });

  it("changes production renderer version when the same customType is replaced", () => {
    const path = writeJsonl(fixtureEntries());
    const renderersA = createLiveEntryRendererSet([
      ["demo:card", titleRenderer("Generation A")],
    ]);
    const renderersB = createLiveEntryRendererSet([
      ["demo:card", titleRenderer("Generation B")],
    ]);
    const sameSnapshot = createLiveEntryRendererSet([
      ["demo:card", renderersA.get("demo:card") as CollapsedEntryRenderer],
    ]);

    const withA = readSessionTracePageFromFile(path, {
      targetEvents: 1,
      entryRenderers: renderersA,
    });
    const withB = readSessionTracePageFromFile(path, {
      targetEvents: 1,
      entryRenderers: renderersB,
    });
    const reused = readSessionTracePageFromFile(path, {
      cursor: withA.page.olderCursor ?? undefined,
      targetEvents: 1,
      entryRenderers: renderersB,
    });
    const sameGeneration = readSessionTracePageFromFile(path, {
      cursor: withA.page.olderCursor ?? undefined,
      targetEvents: 1,
      entryRenderers: sameSnapshot,
    });

    expect(renderersA.version).not.toEqual(renderersB.version);
    expect(renderersA.version).toEqual(sameSnapshot.version);
    expect(withA.page.traceVersion).not.toEqual(withB.page.traceVersion);
    expect(reused.page.staleCursor).toBe(true);
    expect(reused.trace).toEqual([]);
    expect(sameGeneration.page.staleCursor).toBe(false);
  });

  it("keeps full, page, outline, and around agreed on a branched custom-entry fixture", async () => {
    const path = writeJsonl(branchedFixtureEntries());
    const renderers = liveRenderers({ "demo:card": titleRenderer("Branch card") });

    const full = parseJsonl(readFileSync(path, "utf8"), {
      entryRenderers: renderers,
      view: "full",
    });
    const page = readSessionTracePageFromFile(path, {
      targetEvents: 5,
      entryRenderers: renderers,
    });
    const outline = await readSessionTraceOutlineFromFiles([path], { entryRenderers: renderers });
    const aroundCurrent = readSessionTracePageFromFile(path, {
      aroundEntryId: "current-c",
      targetEvents: 10,
      entryRenderers: renderers,
    });
    const aroundAbandoned = readSessionTracePageFromFile(path, {
      aroundEntryId: "abandoned-c",
      targetEvents: 10,
      entryRenderers: renderers,
    });
    const aroundUnknown = readSessionTracePageFromFile(path, {
      aroundEntryId: "missing-id",
      targetEvents: 10,
      entryRenderers: renderers,
    });

    const fullIds = full.map((event) => event.id);
    const pageIds = page.trace.map((event) => event.id);
    const outlineIds = outline.outline.entries.map((entry) => entry.id);

    expect(fullIds).toContain("current-c");
    expect(fullIds).not.toContain("abandoned-c");
    expect(pageIds).toContain("current-c");
    expect(pageIds).not.toContain("abandoned-c");
    expect(pageIds).toContain("a1-text-0");
    expect(outlineIds).toContain("current-c");
    expect(outlineIds).not.toContain("abandoned-c");
    expect(aroundCurrent.trace.find((event) => event.id === "current-c")).toEqual(
      full.find((event) => event.id === "current-c"),
    );
    expect(aroundAbandoned.trace).toEqual([]);
    expect(aroundAbandoned.page.staleCursor).toBe(aroundUnknown.page.staleCursor);
    expect(serialized({ full, page, outline, aroundCurrent, aroundAbandoned })).not.toContain(
      SENTINEL,
    );
  });

  it("hides non-string, throwing accessors, and oversized-byte renderer output", () => {
    const logs = captureStderr();
    const entries = [
      userEntry("u1", null, "hello"),
      customEntry("nonstr-1", "u1", "demo:nonstr"),
      customEntry("throw-access-1", "nonstr-1", "demo:throw-access"),
      customEntry("huge-1", "throw-access-1", "demo:huge"),
    ];

    const events = buildSessionContext(entries, {
      entryRenderers: liveRenderers({
        "demo:nonstr": () => ({ render: () => [1 as unknown as string] }),
        "demo:throw-access": () => ({
          render: () =>
            new Proxy(["title"], {
              get(target, prop, receiver) {
                if (prop === 0 || prop === "0") {
                  throw new Error(`get ${SENTINEL}`);
                }
                return Reflect.get(target, prop, receiver);
              },
            }),
        }),
        "demo:huge": () => ({ render: () => ["x".repeat(20_000)] }),
      }),
    });
    const logText = logs.text();

    expect(events.map((event) => event.id)).toEqual(["u1"]);
    expect(serialized(events)).not.toContain(SENTINEL);
    expect(logText).not.toContain(SENTINEL);
  });

  it("projects a custom entry once per live renderer set during paging", () => {
    const path = writeJsonl(fixtureEntries());
    let calls = 0;
    const renderers = liveRenderers({
      "demo:card": (_entry, options) => {
        expect(options.expanded).toBe(false);
        calls += 1;
        return { render: () => ["Once"] };
      },
    });

    const page = readSessionTracePageFromFile(path, {
      targetEvents: 10,
      entryRenderers: renderers,
    });

    expect(cardEvent(page.trace)?.presentation?.title).toBe("Once");
    expect(calls).toBe(1);
  });

  it("looks up renderers through getEntryRenderer instead of a private extensions array", () => {
    const renderer = titleRenderer("Public lookup");
    const runner = {
      getEntryRenderer: (customType: string) => (customType === "demo:card" ? renderer : undefined),
    };
    const first = createLiveEntryRendererLookup(runner, 1);
    const reloaded = createLiveEntryRendererLookup(runner, 2);

    expect(first).toBeDefined();
    expect(first?.get("demo:card")).toBe(renderer);
    expect(first?.get("missing")).toBeUndefined();
    expect(first?.version).not.toEqual(reloaded?.version);
    expect(createLiveEntryRendererLookup(runner, 0)).toBeUndefined();
  });
});
