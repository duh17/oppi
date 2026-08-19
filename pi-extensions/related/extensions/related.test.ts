import { describe, expect, it } from "vitest";

import { createRelatedFactory, type RelatedState } from "./related.js";

type RelatedUpdateParams = {
  summary?: string;
  items?: Array<{
    id: string;
    title: string;
    subtitle?: string;
    detail?: string;
    state?: "queued" | "running" | "success" | "warning" | "error" | "inactive";
    href?: string;
  }>;
  itemUpdates?: Array<{
    id: string;
    title?: string;
    subtitle?: string;
    detail?: string;
    state?: "queued" | "running" | "success" | "warning" | "error" | "inactive";
    href?: string;
  }>;
  clear?: boolean;
};

type ToolResult = {
  content: Array<{ type: string; text: string }>;
  details?: unknown;
};

type RegisteredTool = {
  name: string;
  execute: (
    toolCallId: string,
    params: RelatedUpdateParams,
    signal?: AbortSignal,
    onUpdate?: unknown,
    ctx?: MockContext,
  ) => Promise<ToolResult>;
};

type RegisteredCommand = {
  description?: string;
  handler: (args: string, ctx: MockContext) => Promise<void> | void;
};

type SessionStartHandler = (
  event: { type: "session_start" },
  ctx: MockContext,
) => Promise<void> | void;

type NativeActivityRow = {
  id: string;
  title: string;
  subtitle?: string;
  detail?: string;
  state?: string;
  link?: string;
};

type NativeSurface = {
  version: 1;
  id: string;
  source: "widget";
  presentation: { style: string; title?: string; subtitle?: string };
  blocks: Array<
    | { type: "markdown"; markdown: string }
    | { type: "activityList"; rows: NativeActivityRow[] }
    | { type: string }
  >;
  fallback?: { lines?: string[]; text?: string };
};

type WidgetFactory = (
  tui: { requestRender: () => void },
  theme: unknown,
) => {
  render: (width: number) => string[];
  renderNative?: () => NativeSurface | undefined;
};

interface MockContext {
  hasUI: boolean;
  mode: "tui" | "rpc";
  sessionManager: {
    getEntries: () => unknown[];
    getBranch?: () => unknown[];
  };
  ui: {
    setWidget: (
      key: string,
      content: string[] | WidgetFactory | undefined,
      options?: { placement?: string },
    ) => void;
  };
}

interface MockPi {
  tools: Map<string, RegisteredTool>;
  commands: Map<string, RegisteredCommand>;
  appended: Array<{ customType: string; data: unknown }>;
  sessionStart?: SessionStartHandler;
  on(event: string, handler: SessionStartHandler): void;
  registerTool(tool: RegisteredTool): void;
  registerCommand(name: string, command: RegisteredCommand): void;
  appendEntry(customType: string, data?: unknown): void;
}

function createMockPi(): MockPi {
  const tools = new Map<string, RegisteredTool>();
  const commands = new Map<string, RegisteredCommand>();
  const appended: Array<{ customType: string; data: unknown }> = [];
  return {
    tools,
    commands,
    appended,
    on(event, handler) {
      if (event === "session_start") {
        this.sessionStart = handler;
      }
    },
    registerTool(tool) {
      tools.set(tool.name, tool);
    },
    registerCommand(name, command) {
      commands.set(name, command);
    },
    appendEntry(customType, data) {
      appended.push({ customType, data });
    },
  };
}

function createMockContext(
  entries: unknown[] = [],
  options: { branch?: unknown[]; hasUI?: boolean } = {},
): MockContext & { widgetCalls: Array<[string, unknown, unknown?]> } {
  const widgetCalls: Array<[string, unknown, unknown?]> = [];
  const branch = options.branch ?? entries;
  return {
    hasUI: options.hasUI ?? true,
    mode: "rpc",
    widgetCalls,
    sessionManager: {
      getEntries: () => entries,
      getBranch: () => branch,
    },
    ui: {
      setWidget(key, content, options) {
        widgetCalls.push([key, content, options]);
      },
    },
  };
}

function relatedEntry(data: unknown): Record<string, unknown> {
  return { type: "custom", customType: "oppi-related", data };
}

function install(pi: MockPi): void {
  createRelatedFactory()(pi as never);
}

async function update(
  pi: MockPi,
  ctx: MockContext,
  params: RelatedUpdateParams,
): Promise<ToolResult> {
  const tool = pi.tools.get("related_update");
  if (!tool) {
    throw new Error("related_update is not registered");
  }
  return tool.execute("tc-1", params, undefined, undefined, ctx);
}

async function status(pi: MockPi, ctx: MockContext): Promise<ToolResult> {
  const tool = pi.tools.get("related_status");
  if (!tool) {
    throw new Error("related_status is not registered");
  }
  return tool.execute("tc-status", {}, undefined, undefined, ctx);
}

function lastPersisted(pi: MockPi): RelatedState {
  const entry = [...pi.appended]
    .reverse()
    .find((item) => item.customType === "oppi-related");
  return entry?.data as RelatedState;
}

function widgetComponent(ctx: ReturnType<typeof createMockContext>): {
  render: (width: number) => string[];
  renderNative?: () => NativeSurface | undefined;
} {
  const relatedCalls = ctx.widgetCalls.filter((call) => call[0] === "related");
  const factoryCall = [...relatedCalls]
    .reverse()
    .find((call) => typeof call[1] === "function");
  if (typeof factoryCall?.[1] !== "function") {
    throw new Error("related widget component was not published");
  }
  return (factoryCall[1] as WidgetFactory)({ requestRender() {} }, {});
}

describe("related extension", () => {
  it("persists related_update and restores the newest compatible v1 entry from the active branch", async () => {
    const writer = createMockPi();
    install(writer);
    const writeCtx = createMockContext();
    const board = {
      summary:
        "See [[docs/extensions.md|extensions]] and the parent session.",
      items: [
        {
          id: "parent",
          title: "Parent session",
          subtitle: "Design",
          href: "oppi://session/abc-123",
        },
      ],
    };

    const written = await update(writer, writeCtx, board);
    expect(writer.appended.at(-1)).toEqual({
      customType: "oppi-related",
      data: {
        version: 1,
        summary: board.summary,
        items: board.items,
      },
    });
    expect(written.details).toMatchObject({
      version: 1,
      summary: board.summary,
      items: board.items,
    });

    const persisted = lastPersisted(writer);
    const reader = createMockPi();
    install(reader);
    const stale = relatedEntry({
      version: 1,
      summary: "Stale sibling",
      items: [{ id: "stale", title: "Stale", href: "https://example.com" }],
    });
    const unknown = relatedEntry({ version: 2, summary: "Future" });
    const active = relatedEntry(persisted);
    const readCtx = createMockContext([stale, active, unknown], {
      branch: [unknown, active],
    });

    await reader.sessionStart?.({ type: "session_start" }, readCtx);
    const restored = await status(reader, readCtx);
    expect(restored.details).toEqual(persisted);
  });

  it("ignores unknown versions instead of migrating them", async () => {
    const pi = createMockPi();
    install(pi);
    const ctx = createMockContext([
      relatedEntry({ version: 9, summary: "Do not migrate", items: [] }),
    ]);

    await pi.sessionStart?.({ type: "session_start" }, ctx);
    const result = await status(pi, ctx);
    expect(result.details).toEqual({ status: "none" });
    expect(pi.appended).toEqual([]);
  });

  it("rejects wiki, scheme-less, and oppi-resource-reference hrefs", async () => {
    const cases = [
      "[[docs/extensions.md|extensions]]",
      "docs/extensions.md",
      "oppi-resource-reference://file/docs/extensions.md",
    ];

    for (const href of cases) {
      const pi = createMockPi();
      install(pi);
      const ctx = createMockContext();
      await expect(
        update(pi, ctx, {
          items: [{ id: "bad", title: "Bad link", href }],
        }),
      ).rejects.toThrow(/href/i);
      expect(pi.appended).toEqual([]);
    }
  });

  it("publishes summary markdown and a session activity link on the native surface", async () => {
    const pi = createMockPi();
    install(pi);
    const ctx = createMockContext();
    await update(pi, ctx, {
      summary:
        "Files stay in markdown: [[docs/extensions.md|extensions docs]].",
      items: [
        {
          id: "session-1",
          title: "Related session",
          state: "success",
          href: "oppi://session/abc-123",
        },
        {
          id: "web-1",
          title: "Spec",
          href: "https://example.com/spec",
        },
      ],
    });

    const lineSnapshot = ctx.widgetCalls.find(
      (call) => call[0] === "related" && Array.isArray(call[1]),
    );
    expect(lineSnapshot?.[1]).toEqual(expect.any(Array));
    expect(lineSnapshot?.[2]).toMatchObject({ placement: "aboveEditor" });

    const surface = widgetComponent(ctx).renderNative?.();
    expect(surface).toMatchObject({
      version: 1,
      id: "widget:related",
      source: "widget",
    });
    expect(surface?.blocks).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "markdown",
          markdown:
            "Files stay in markdown: [[docs/extensions.md|extensions docs]].",
        }),
        expect.objectContaining({
          type: "activityList",
          rows: expect.arrayContaining([
            expect.objectContaining({
              id: "session-1",
              title: "Related session",
              link: "oppi://session/abc-123",
            }),
          ]),
        }),
      ]),
    );
    const activity = surface?.blocks.find(
      (block) => block.type === "activityList",
    ) as { rows: NativeActivityRow[] } | undefined;
    expect(activity?.rows.every((row) => !row.link?.includes("[["))).toBe(true);
  });

  it("clears the board and removes the related widget", async () => {
    const pi = createMockPi();
    install(pi);
    const ctx = createMockContext();
    await update(pi, ctx, {
      summary: "Temporary board",
      items: [
        {
          id: "session-1",
          title: "Related session",
          href: "oppi://session/abc-123",
        },
      ],
    });
    expect(
      ctx.widgetCalls.some(
        (call) => call[0] === "related" && call[1] !== undefined,
      ),
    ).toBe(true);

    await update(pi, ctx, { clear: true });
    expect(await status(pi, ctx)).toMatchObject({
      details: { status: "none" },
    });
    expect(ctx.widgetCalls.at(-1)?.slice(0, 2)).toEqual([
      "related",
      undefined,
    ]);

    const command = pi.commands.get("related");
    expect(command).toBeDefined();
    await update(pi, ctx, {
      items: [
        {
          id: "session-2",
          title: "Another session",
          href: "oppi://session/def-456",
        },
      ],
    });
    await command?.handler("clear", ctx);
    expect(await status(pi, ctx)).toMatchObject({
      details: { status: "none" },
    });
    expect(ctx.widgetCalls.at(-1)?.slice(0, 2)).toEqual([
      "related",
      undefined,
    ]);
  });
});
