import resolvePath from "node:path";

import type { PinAddResponse, PinsResponse, PinTarget } from "../src/types.js";
import { PROTOCOL_DIR } from "./protocol-fixtures.js";

/**
 * `protocol/pins-http.json`: the bodies of `GET`, `POST` and `PUT /pins`. Only this serializer
 * defines the bytes; `pins-fixtures.test.ts` compares them with the committed file, and
 * `npm run protocol:fixtures:update` writes it. Apple `PinsContractTests` decodes every body.
 */

export const PINS_HTTP_SNAPSHOT_FILE = resolvePath.join(PROTOCOL_DIR, "pins-http.json");

export const PINS_HTTP_FIXTURE_DESCRIPTION =
  "Pins: saved File Browser locations, one list per server. GET /pins answers every pin with what is at its target now (ok, missing, unreadable, workspaceMissing, or unknown when the check took longer than 500 ms). POST /pins adds a target (a duplicate answers the saved pin's id); PUT /pins sets the order and labels and removes left-out pins, and a stale baseRevision answers 409 revision_conflict with the current list. Each change sends the pins_changed app event. Built by server/tests/pins-fixtures.ts; server/tests/pins-fixtures.test.ts fails when the committed bytes differ, and Apple PinsContractTests decodes these bodies.";

const notebook: PinTarget = { origin: "host", path: "~/notebook" };
const reports: PinTarget = { origin: "workspace", workspaceId: "ws-1", path: "reports" };

export function buildPinsList(): PinsResponse {
  return {
    revision: 7,
    pins: [
      {
        id: "pin_Notebook0001",
        target: notebook,
        kind: "directory",
        createdAt: 1794384000000,
        status: "ok",
      },
      {
        id: "pin_Reports00002",
        target: reports,
        kind: "directory",
        label: "Reports",
        createdAt: 1794384060000,
        status: "ok",
      },
      {
        id: "pin_Book00000003",
        target: { origin: "host", path: "~/Books/The Left Hand of Darkness.epub" },
        kind: "file",
        createdAt: 1794384120000,
        status: "missing",
      },
      {
        id: "pin_Documents004",
        target: { origin: "host", path: "~/Documents" },
        kind: "directory",
        createdAt: 1794384180000,
        status: "unreadable",
      },
      {
        id: "pin_OldRepo00005",
        target: { origin: "workspace", workspaceId: "ws-gone", path: "" },
        kind: "directory",
        label: "Old repo",
        createdAt: 1794384240000,
        status: "workspaceMissing",
      },
      {
        id: "pin_Archive00006",
        target: { origin: "host", path: "~/Volumes/Archive" },
        kind: "directory",
        createdAt: 1794384300000,
        status: "unknown",
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
        addRequests: [{ target: notebook }, { target: reports, label: "Reports" }],
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
