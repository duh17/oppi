import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY } from "../src/extension-ui-contract.js";

const FIXTURE_MODULE_DIR = dirname(fileURLToPath(import.meta.url));

// Resolved here rather than through `protocol-fixtures.ts`: that module builds the canonical
// server messages from these fixtures, so importing it back would close a cycle.
export const SURFACE_FIXTURES_DIR = resolve(FIXTURE_MODULE_DIR, "../../protocol/surfaces");

/**
 * One fixture surface per composite, plus the client's two messages and the patch, and one
 * surface carrying a composite this slice does not draw. Both suites decode these same files, so
 * a field the server writes and the phone cannot read fails a test rather than a build on
 * someone's phone.
 */
export function buildSurfaceFixtures(): Record<string, unknown> {
  return {
    "status-card.json": statusCardSurface(),
    "checklist.json": checklistSurface(),
    "data-table.json": dataTableSurface(),
    "action-bar.json": actionBarSurface(),
    "blocks-panel.json": blocksPanelSurface(),
    "blocks-filters.json": blocksFiltersSurface(),
    "blocks-status.json": blocksStatusSurface(),
    "blocks-elapsed.json": blocksElapsedSurface(),
    "blocks-action.json": blocksActionMessage(),
    "blocks-patch.json": blocksPatchMessage(),
    "blocks-unknown-node.json": blocksUnknownNodeSurface(),
    "action.json": actionMessage(),
    "client-capabilities.json": clientCapabilitiesMessage(),
    "patch.json": patchMessage(),
    "unknown-composite.json": unknownCompositeSurface(),
  };
}

export function serializeSurfaceFixture(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

export function readSurfaceFixture(name: string): unknown {
  return JSON.parse(readFileSync(resolve(SURFACE_FIXTURES_DIR, name), "utf8"));
}

/**
 * What a client says it draws, once on subscribe: the one capability that makes the server send
 * it each composable surface instead of that surface's v1 widget projection.
 */
function clientCapabilitiesMessage(): Record<string, unknown> {
  return {
    type: "client_capabilities",
    capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY],
    requestId: "capabilities-1",
  };
}

function baseSurface(overrides: Record<string, unknown>): Record<string, unknown> {
  return {
    version: 2,
    id: "deploy",
    title: "Deploys",
    placement: { kind: "strip", preferred: "aboveComposer" },
    lifecycle: "persistent",
    header: { title: "web → prod", subtitle: "Deploying 4f2c1ab" },
    actions: {
      retry: {
        title: "Retry",
        role: "primary",
        pending: { title: "Retrying…", disabled: ["retry"] },
      },
      openLog: { title: "Logs" },
      copy: { title: "Copy", role: "secondary" },
    },
    fallback: { text: "Deploy web → prod: running" },
    revision: 7,
    extensionScopeId: "npm:deploy-helper",
    extensionDisplayName: "Deploy Helper",
    ...overrides,
  };
}

function statusCardSurface(): unknown {
  return baseSurface({
    sections: [
      {
        composite: "statusCard",
        id: "status",
        header: { title: "Deploying 4f2c1ab", subtitle: "main → production" },
        state: { kind: "content" },
        actions: ["retry", "openLog"],
        fallback: { text: "Deploying 4f2c1ab: gates running" },
        tone: "warning",
        phase: "running",
        steps: [
          {
            id: "build",
            title: "Build",
            state: "success",
            detail: "Took 42 s",
          },
          {
            id: "test",
            title: "Test",
            state: "running",
            extra: [
              { type: "progress", label: "Tests", value: 0.4 },
              { type: "divider" },
              { type: "text", spans: [{ text: "214 passed", role: "success" }] },
            ],
          },
          { id: "ship", title: "Ship", state: "queued" },
        ],
      },
    ],
  });
}

function checklistSurface(): unknown {
  return baseSurface({
    id: "release",
    title: "Release",
    header: { title: "Release checklist" },
    actions: {},
    fallback: { text: "Release checklist: 2 of 4 done" },
    revision: 3,
    sections: [
      {
        composite: "checklist",
        id: "gates",
        header: { title: "Before you ship", subtitle: "2 of 4 done" },
        state: { kind: "content" },
        fallback: { text: "2 of 4 gates done" },
        tone: "accent",
        items: [
          { id: "tests", title: "Unit tests", state: "success" },
          { id: "review", title: "Review approved", state: "success" },
          { id: "notes", title: "Release notes", state: "running", detail: "Drafting" },
          { id: "signoff", title: "Sign-off", state: "queued" },
        ],
      },
    ],
  });
}

function dataTableSurface(): unknown {
  return baseSurface({
    id: "query",
    title: "Query",
    header: { title: "sqlite_schema", subtitle: "12 rows" },
    fallback: { text: "12 rows" },
    revision: 2,
    sections: [
      {
        composite: "dataTable",
        id: "rows",
        header: { title: "Tables", subtitle: "12 rows" },
        state: { kind: "content" },
        actions: ["copy"],
        fallback: { text: "Tables: sqlite_schema, sqlite_master" },
        columns: [
          { id: "name", title: "Name" },
          { id: "type", title: "Type" },
          { id: "rows", title: "Rows", kind: "number" },
        ],
        rows: [
          {
            id: "table:sessions",
            cells: { name: "sessions", type: "table", rows: 12 },
            actions: ["copy"],
          },
          {
            id: "table:events",
            cells: { name: "events", type: "table", rows: 4021 },
            actions: ["copy"],
          },
        ],
        sort: { columnId: "name" },
        selectedRowId: "table:sessions",
      },
    ],
  });
}

function actionBarSurface(): unknown {
  return baseSurface({
    id: "approval",
    title: "Approval",
    lifecycle: "oneShot",
    timeoutAt: 1_739_750_700_000,
    header: { title: "Ship 4f2c1ab?", subtitle: "Expires in 5 minutes" },
    actions: {
      approve: {
        title: "Approve",
        role: "primary",
        pending: { title: "Approving…", disabled: ["approve", "reject"] },
      },
      reject: { title: "Reject", role: "destructive" },
    },
    fallback: { text: "Approve shipping 4f2c1ab?" },
    revision: 1,
    sections: [
      {
        composite: "actionBar",
        id: "decide",
        header: { title: "Approve shipping 4f2c1ab?" },
        state: { kind: "content" },
        actions: ["approve", "reject"],
        fallback: { text: "Approve or reject the deploy" },
        tone: "accent",
      },
    ],
  });
}

/**
 * One of every primitive, plus the composed pill, a toggle, a menu, and a table with row actions.
 * This is the shape a client must draw node for node; the Apple suite decodes these same bytes.
 */
function blocksPanelSurface(): unknown {
  return baseSurface({
    id: "blocks-panel",
    title: "Deploy panel",
    header: { title: "web → prod", subtitle: "4f2c1ab" },
    actions: {
      refresh: { title: "Refresh" },
      openLog: { title: "Logs" },
      retry: {
        title: "Retry",
        role: "primary",
        pending: { title: "Retrying…", disabled: ["retry"] },
      },
      notify: { title: "Notify on failure" },
      copyRow: { title: "Copy" },
      openRow: { title: "Open" },
      cancel: { title: "Cancel", role: "destructive" },
      filters: { title: "Filters" },
    },
    fallback: { text: "Deploy web → prod: 2 of 4 gates" },
    pill: {
      content: {
        type: "row",
        spacing: "tight",
        children: [
          { type: "icon", name: "hammer", tone: "accent" },
          { type: "text", text: "web → prod", style: "caption" },
          { type: "badge", text: "running", tone: "warning" },
          { type: "progress", value: 0.4, kind: "ring" },
        ],
      },
      tap: "drawer",
    },
    sections: [
      {
        composite: "blocks",
        id: "panel",
        header: { title: "Gates", subtitle: "2 of 4" },
        state: { kind: "content" },
        actions: ["refresh"],
        fallback: { text: "Deploy web → prod: 2 of 4 gates" },
        tone: "accent",
        body: {
          type: "stack",
          id: "body",
          spacing: "normal",
          children: [
            {
              type: "row",
              id: "headline",
              align: "spread",
              spacing: "tight",
              children: [
                { type: "text", id: "phase", text: "Deploying 4f2c1ab", style: "headline" },
                { type: "badge", id: "state", text: "2 of 4", tone: "warning", icon: "clock" },
              ],
            },
            { type: "progress", id: "progress", label: "Tests", value: 0.4, kind: "bar", tone: "success" },
            { type: "progress", id: "waiting", label: "Retrying", kind: "ring", tone: "warning" },
            {
              type: "keyValue",
              id: "facts",
              pairs: [
                { key: "Env", value: "prod" },
                { key: "Commit", value: "4f2c1ab", tone: "accent" },
              ],
            },
            { type: "markdown", id: "notes", markdown: "Two gates remain; the test gate retries once." },
            {
              type: "table",
              id: "gates",
              columns: ["Gate", "State"],
              rows: [
                {
                  id: "build",
                  cells: ["Build", "passed"],
                  actions: [{ id: "copyRow" }, { id: "openRow" }],
                },
                { id: "test", cells: ["Test", "running"], actions: [{ id: "copyRow" }] },
              ],
            },
            {
              type: "chart",
              id: "durations",
              kind: "bar",
              title: "Gate duration",
              labels: ["build", "test"],
              series: [{ name: "seconds", values: [42, 18] }],
            },
            { type: "code", id: "tail", language: "bash", text: "make test" },
            { type: "divider", id: "rule" },
            { type: "spacer", id: "gap", size: "small" },
            {
              type: "row",
              id: "actions",
              spacing: "tight",
              children: [
                { type: "icon", id: "hammer", name: "hammer", tone: "accent" },
                {
                  type: "stack",
                  id: "controls",
                  spacing: "tight",
                  children: [
                    {
                      type: "button",
                      id: "retry",
                      title: "Retry",
                      role: "primary",
                      icon: "arrow.clockwise",
                      action: { id: "retry", pending: { title: "Retrying…" } },
                    },
                    {
                      type: "toggle",
                      id: "notify",
                      title: "Notify on failure",
                      value: false,
                      action: { id: "notify" },
                    },
                    {
                      type: "menu",
                      id: "overflow",
                      title: "More",
                      icon: "list.bullet",
                      items: [
                        { title: "Logs", action: { id: "openLog" } },
                        { title: "Cancel", role: "destructive", action: { id: "cancel" } },
                        { title: "Filters", action: { id: "filters" } },
                      ],
                    },
                    {
                      type: "text",
                      id: "logs-link",
                      text: "Open logs",
                      tone: "accent",
                      action: { id: "openLog" },
                    },
                  ],
                },
              ],
            },
            {
              type: "group",
              id: "filters",
              title: "Filters",
              collapsed: false,
              children: [
                {
                  type: "row",
                  id: "filter-set",
                  spacing: "tight",
                  children: [
                    {
                      type: "text",
                      id: "filter-all",
                      text: "All",
                      selected: true,
                      action: { id: "filters", values: { filter: "all" } },
                    },
                    {
                      type: "text",
                      id: "filter-running",
                      text: "Running",
                      action: { id: "filters", values: { filter: "running" } },
                    },
                    {
                      type: "text",
                      id: "filter-archived",
                      text: "Archived",
                      disabled: true,
                      action: { id: "filters", values: { filter: "archived" } },
                    },
                  ],
                },
              ],
            },
          ],
        },
      },
    ],
  });
}

/**
 * The states a node can be drawn in: the active item of a set, and a control nobody may use. One
 * instance of every kind that carries them, so the same bytes hold the server's validator and the
 * phone's decoder to the same shape.
 */
function blocksFiltersSurface(): unknown {
  return baseSurface({
    id: "blocks-filters",
    title: "Dashboard filters",
    header: { title: "Dashboard", subtitle: "2 filters" },
    actions: {
      apply: { title: "Apply" },
      clear: { title: "Clear" },
      group: { title: "Group by" },
    },
    fallback: { text: "Dashboard filters: 2 selected" },
    pill: {
      content: {
        type: "row",
        spacing: "tight",
        children: [
          { type: "badge", text: "2 filters", tone: "accent", icon: "tag" },
          { type: "text", text: "Dashboard", style: "caption" },
        ],
      },
      tap: "drawer",
    },
    sections: [
      {
        composite: "blocks",
        id: "filters",
        header: { title: "Filters" },
        state: { kind: "content" },
        actions: ["apply"],
        fallback: { text: "Dashboard filters: 2 selected" },
        body: {
          type: "stack",
          id: "filter-body",
          spacing: "normal",
          children: [
            {
              type: "row",
              id: "active-row",
              selected: true,
              action: { id: "clear", values: { scope: "row" } },
              children: [{ type: "text", id: "active-label", text: "Env: prod" }],
            },
            {
              type: "row",
              id: "archived-row",
              disabled: true,
              action: { id: "clear", values: { scope: "archived" } },
              children: [{ type: "text", id: "archived-label", text: "Env: staging" }],
            },
            {
              type: "row",
              id: "segment",
              spacing: "tight",
              children: [
                {
                  type: "button",
                  id: "seg-all",
                  title: "All",
                  selected: true,
                  action: { id: "apply", values: { segment: "all" } },
                },
                {
                  type: "button",
                  id: "seg-running",
                  title: "Running",
                  action: { id: "apply", values: { segment: "running" } },
                },
                {
                  type: "button",
                  id: "seg-failed",
                  title: "Failed",
                  disabled: true,
                  action: { id: "apply", values: { segment: "failed" } },
                },
              ],
            },
            {
              type: "row",
              id: "badge-row",
              spacing: "tight",
              children: [
                {
                  type: "badge",
                  id: "badge-selected",
                  text: "prod",
                  tone: "accent",
                  icon: "cloud",
                  selected: true,
                  action: { id: "clear", values: { badge: "prod" } },
                },
                {
                  type: "badge",
                  id: "badge-disabled",
                  text: "staging",
                  disabled: true,
                  action: { id: "clear", values: { badge: "staging" } },
                },
              ],
            },
            {
              type: "stack",
              id: "locked",
              disabled: true,
              action: { id: "group", values: { by: "env" } },
              children: [
                {
                  type: "text",
                  id: "locked-text",
                  text: "Grouping is locked while a deploy runs.",
                  style: "caption",
                  disabled: true,
                  action: { id: "group", values: { by: "owner" } },
                },
              ],
            },
            {
              type: "toggle",
              id: "notify-toggle",
              title: "Notify on failure",
              value: true,
              disabled: true,
              action: { id: "apply" },
            },
            {
              type: "menu",
              id: "groupby",
              title: "Group by",
              icon: "list.bullet",
              disabled: true,
              items: [
                { title: "Env", action: { id: "group", values: { by: "env" } } },
                { title: "Owner", action: { id: "group", values: { by: "owner" } } },
              ],
            },
          ],
        },
      },
    ],
  });
}

/** A composed pill whose tap is its own action, and a body a small surface actually needs. */
function blocksStatusSurface(): unknown {
  return baseSurface({
    id: "blocks-status",
    title: "Waiting",
    header: { title: "Waiting on you" },
    actions: { refresh: { title: "Refresh" }, approve: { title: "Approve", role: "primary" } },
    fallback: { text: "Waiting on you: approve to continue" },
    pill: {
      content: {
        type: "row",
        spacing: "tight",
        children: [
          { type: "icon", name: "exclamationmark.triangle", tone: "danger" },
          { type: "text", text: "Waiting on you", style: "caption" },
        ],
      },
      tap: { action: { id: "refresh" } },
    },
    sections: [
      {
        composite: "blocks",
        id: "ask",
        state: { kind: "content" },
        fallback: { text: "Waiting on you: approve to continue" },
        body: {
          type: "stack",
          spacing: "normal",
          children: [
            { type: "text", id: "headline", text: "Approve shipping 4f2c1ab?", style: "headline" },
            { type: "text", id: "detail", text: "Two gates passed.", style: "caption" },
            {
              type: "button",
              id: "approve",
              title: "Approve",
              role: "primary",
              action: { id: "approve" },
            },
          ],
        },
      },
    ],
  });
}

/** A live timer: the client ticks `elapsed` itself, so the pill and the body cost no traffic. */
function blocksElapsedSurface(): unknown {
  return baseSurface({
    id: "blocks-elapsed",
    title: "Jobs",
    header: { title: "Jobs", subtitle: "1 running" },
    actions: { refresh: { title: "Refresh" } },
    fallback: { text: "1 job running" },
    pill: {
      content: {
        type: "row",
        spacing: "tight",
        children: [
          { type: "icon", name: "hammer", tone: "accent" },
          { type: "text", text: "1 job", style: "caption" },
          { type: "elapsed", since: 1_790_000_000_000, style: "mono", tone: "warning" },
        ],
      },
      tap: "drawer",
    },
    sections: [
      {
        composite: "blocks",
        id: "jobs",
        state: { kind: "content" },
        fallback: { text: "1 job running" },
        body: {
          type: "row",
          spacing: "normal",
          align: "spread",
          children: [
            { type: "text", text: "npm test" },
            { type: "elapsed", id: "job-elapsed", since: 1_790_000_000_000, format: "short" },
          ],
        },
      },
    ],
  });
}

/** A toggle's tap: the node it came from, the switch's new value, and the revision it saw. */
function blocksActionMessage(): unknown {
  return {
    type: "extension_ui_action",
    surfaceId: "blocks-panel",
    compositeId: "panel",
    actionId: "notify",
    nodeId: "notify",
    revision: 7,
    values: { value: true },
    requestId: "blocks-action-1",
  };
}

/** A patch into a body: by child index, and by node id where the tree has one. */
function blocksPatchMessage(): unknown {
  return {
    type: "extension_ui_patch",
    surfaceId: "blocks-panel",
    revision: 8,
    sessionId: "test-session-1",
    patch: {
      "sections.0.body.children.1.value": 0.7,
      "sections.0.body.children.0.children.#state.text": "3 of 4",
      "sections.0.body.children.#gates.rows.0.cells.1": "running",
    },
  };
}

/**
 * A tree a newer server may publish and this build cannot draw: the surface is refused by the
 * server's validator, and a client keeps the section's words instead of failing the frame.
 */
function blocksUnknownNodeSurface(): unknown {
  return baseSurface({
    id: "blocks-future",
    title: "Future",
    header: { title: "Future primitives" },
    actions: {},
    fallback: { text: "Future primitives" },
    sections: [
      {
        composite: "blocks",
        id: "future",
        state: { kind: "content" },
        fallback: { text: "A panel this build cannot draw" },
        body: {
          type: "stack",
          children: [
            { type: "text", id: "known", text: "This part is known" },
            { type: "webview", id: "canvas", url: "https://example.com" },
          ],
        },
      },
    ],
  });
}

function actionMessage(): unknown {
  return {
    type: "extension_ui_action",
    surfaceId: "deploy",
    compositeId: "status",
    actionId: "retry",
    revision: 7,
    values: { env: "prod" },
    requestId: "action-1",
  };
}

function patchMessage(): unknown {
  return {
    type: "extension_ui_patch",
    surfaceId: "deploy",
    revision: 8,
    patch: { "sections.0.state": { kind: "content" }, "sections.0.phase": "queued" },
    sessionId: "test-session-1",
  };
}

/**
 * A surface an older or newer build may receive: one composite this slice draws, one it does
 * not, and a field it has never heard of. Clients show the unknown card's fallback text inside a
 * labeled placeholder instead of failing the whole frame.
 */
function unknownCompositeSurface(): unknown {
  return baseSurface({
    id: "mixed",
    title: "Mixed",
    header: { title: "Mixed sections" },
    actions: {},
    fallback: { text: "Mixed sections" },
    revision: 4,
    sandboxPolicy: { allowNetwork: false },
    sections: [
      {
        composite: "statusCard",
        id: "status",
        header: { title: "Deploy" },
        state: { kind: "content" },
        fallback: { text: "Deploy running" },
        phase: "running",
      },
      {
        composite: "logStream",
        id: "log",
        header: { title: "Log" },
        state: { kind: "content" },
        fallback: { text: "Build log: 42 lines" },
        lines: [{ level: "info", text: "started" }],
        follow: true,
      },
    ],
  });
}
