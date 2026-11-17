import resolvePath from "node:path";

import type { PinAddResponse, PinRoute, PinsResponse } from "../src/types.js";
import { PROTOCOL_DIR } from "./protocol-fixtures.js";

/**
 * `protocol/pins-http.json`: the bodies of `GET`, `POST` and `PUT /pins`. Only this serializer
 * defines the bytes; `pins-fixtures.test.ts` compares them with the committed file, and
 * `npm run protocol:fixtures:update` writes it. Apple `PinsContractTests` decodes every body.
 */

export const PINS_HTTP_SNAPSHOT_FILE = resolvePath.join(PROTOCOL_DIR, "pins-http.json");

export const PINS_HTTP_FIXTURE_DESCRIPTION =
  "Pins: saved pane routes, one list per server. A pin's target is a route in the shape protocol/links.json decodes oppi:// links to, without a server, every field of its kind present (null where the link leaves it out). GET /pins answers every pin with what is at its target now where the server checks it (ok, missing, unreadable, workspaceMissing, or unknown when the check took longer than 500 ms): a session, thread, or panel is missing once its session is deleted; a folder or file in the home folder or a workspace's main checkout is probed on disk; a sessions route reads workspaceMissing once its workspace is gone; a game is ok, with its game's name, while the server knows it. Web pages, worktree files, and session-copy files read ok unchecked. POST /pins adds a target (a duplicate answers the saved pin's id; a git or commit route is refused); PUT /pins sets the order and labels and removes left-out pins, and a stale baseRevision answers 409 revision_conflict with the current list. Each change sends the pins_changed app event. Built by server/tests/pins-fixtures.ts; server/tests/pins-fixtures.test.ts fails when the committed bytes differ, and Apple PinsContractTests decodes these bodies.";

const notebook: PinRoute = { kind: "files", origin: "host", path: "~/notebook" };
const reports: PinRoute = { kind: "files", workspace: "ws-1", path: "reports" };
const releaseSession: PinRoute = { kind: "session", id: "2f6c1a9e-session" };
const swordLab: PinRoute = { kind: "godot", project: "sword-lab-3fa9c2b1" };
const docs: PinRoute = { kind: "browser", url: "https://docs.godotengine.org/en/stable/" };

export function buildPinsList(): PinsResponse {
  return {
    revision: 7,
    pins: [
      { id: "pin_Notebook0001", target: notebook, createdAt: 1794384000000, status: "ok" },
      {
        id: "pin_Reports00002",
        target: reports,
        label: "Reports",
        createdAt: 1794384060000,
        status: "ok",
      },
      {
        id: "pin_Book00000003",
        target: {
          kind: "file",
          origin: "host",
          path: "~/Books/The Left Hand of Darkness.epub",
          line: null,
        },
        createdAt: 1794384120000,
        status: "missing",
      },
      {
        id: "pin_Documents004",
        target: { kind: "files", origin: "host", path: "~/Documents" },
        createdAt: 1794384180000,
        status: "unreadable",
      },
      {
        id: "pin_OldRepo00005",
        target: { kind: "files", workspace: "ws-gone", path: null },
        label: "Old repo",
        createdAt: 1794384240000,
        status: "workspaceMissing",
      },
      {
        id: "pin_Archive00006",
        target: { kind: "files", origin: "host", path: "~/Volumes/Archive" },
        createdAt: 1794384300000,
        status: "unknown",
      },
      { id: "pin_Release00007", target: releaseSession, createdAt: 1794384360000, status: "ok" },
      {
        id: "pin_OldChat00008",
        target: { kind: "session", id: "deleted-session" },
        createdAt: 1794384420000,
        status: "missing",
      },
      {
        id: "pin_SwordLab0009",
        target: swordLab,
        createdAt: 1794384480000,
        status: "ok",
        name: "Sword Lab",
      },
      {
        id: "pin_OldGame00010",
        target: { kind: "godot", project: "tide-7c01d2e4" },
        label: "Tide",
        createdAt: 1794384540000,
        status: "missing",
      },
      { id: "pin_GodotDocs013", target: docs, createdAt: 1794384720000, status: "ok" },
      {
        id: "pin_Subagents014",
        target: { kind: "panel", session: "2f6c1a9e-session", id: "subagents" },
        createdAt: 1794384780000,
        status: "ok",
      },
      {
        id: "pin_Thread000015",
        target: { kind: "thread", id: "7d1e-root" },
        createdAt: 1794384840000,
        status: "ok",
      },
      {
        id: "pin_Sessions0016",
        target: { kind: "sessions", workspace: "ws-1" },
        createdAt: 1794384900000,
        status: "ok",
      },
      {
        id: "pin_AppTs000017",
        target: {
          kind: "file",
          origin: "workspace",
          workspace: "ws-1",
          worktree: "wt-feature",
          path: "src/app.ts",
          line: 12,
        },
        createdAt: 1794384960000,
        status: "ok",
      },
    ],
  };
}

export function buildPinAddResponse(): PinAddResponse {
  return { ...buildPinsList(), pinId: "pin_Reports00002" };
}

export function serializePinsHttpFixture(): string {
  return (
    JSON.stringify(
      {
        _meta: {
          description: PINS_HTTP_FIXTURE_DESCRIPTION,
          source: "server/src/types/pins.ts",
        },
        list: buildPinsList(),
        addRequests: [
          { target: notebook },
          { target: reports, label: "Reports" },
          { target: releaseSession },
          { target: swordLab },
          { target: docs },
        ],
        add: buildPinAddResponse(),
        reorderRequest: {
          baseRevision: 7,
          pins: [{ id: "pin_Reports00002", label: "Reports" }, { id: "pin_Notebook0001" }],
        },
        conflict: { error: "Pins changed", code: "revision_conflict", current: buildPinsList() },
      },
      null,
      2,
    ) + "\n"
  );
}
