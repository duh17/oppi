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
