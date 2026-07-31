import { chmodSync, mkdtempSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  clearIrohInviteState,
  irohInviteTransportFromState,
  readIrohInviteState,
  writeIrohInviteState,
} from "../src/iroh-invite-state.js";

const PAIR_ALPN = "oppi/pair/1";

let dataDir: string;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-iroh-invite-state-"));
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

describe("Iroh invite state persistence", () => {
  it("writes signed-invite-ready state under the data dir with private permissions", async () => {
    const state = {
      version: 2 as const,
      nodeId: "iroh-node-abc123",
      alpns: [PAIR_ALPN],
      addressMode: "ticket" as const,
      ticket: "endpoint-ticket-hint",
      relayMode: "custom" as const,
      relayUrls: ["https://relay.example/"],
      ticketHomeRelay: "https://relay.example/",
      readinessId: "ready-ticket",
      processId: process.pid,
    };

    await writeIrohInviteState(dataDir, state);

    const irohDir = join(dataDir, "iroh");
    const statePath = join(irohDir, "invite.json");
    expect(statSync(irohDir).mode & 0o777).toBe(0o700);
    expect(statSync(statePath).mode & 0o777).toBe(0o600);
    expect(readIrohInviteState(dataDir)).toEqual(state);
    expect(irohInviteTransportFromState(state)).toEqual({
      version: 2,
      nodeId: state.nodeId,
      alpns: state.alpns,
      addressMode: state.addressMode,
      ticket: state.ticket,
      relayUrls: state.relayUrls,
    });
    expect(irohInviteTransportFromState(state)).not.toHaveProperty("ticketHomeRelay");
  });

  it("accepts node-id state without a ticket hint", async () => {
    const state = {
      version: 2 as const,
      nodeId: "iroh-node-id-only",
      alpns: [PAIR_ALPN],
      addressMode: "node-id" as const,
      relayMode: "default" as const,
      ticketHomeRelay: "https://use1-1.relay.n0.iroh.link/",
      readinessId: "ready-node-id",
      processId: process.pid,
    };

    await writeIrohInviteState(dataDir, state);

    expect(readIrohInviteState(dataDir)).toEqual(state);
    expect(irohInviteTransportFromState(state)).toEqual({
      version: 2,
      nodeId: state.nodeId,
      alpns: state.alpns,
      addressMode: state.addressMode,
    });
  });

  it("omits empty relay URLs so clients retain public defaults", () => {
    expect(
      irohInviteTransportFromState({
        version: 2,
        nodeId: "iroh-node-empty-relays",
        alpns: [PAIR_ALPN],
        addressMode: "node-id",
        relayMode: "default",
        relayUrls: [],
        readinessId: "ready-empty-relays",
        processId: process.pid,
      }),
    ).toEqual({
      version: 2,
      nodeId: "iroh-node-empty-relays",
      alpns: [PAIR_ALPN],
      addressMode: "node-id",
    });
  });

  it("clears persisted invite state without removing other Iroh files", async () => {
    const state = {
      version: 2 as const,
      nodeId: "iroh-node-clear",
      alpns: [PAIR_ALPN],
      addressMode: "node-id" as const,
      relayMode: "default" as const,
      ticketHomeRelay: "https://use1-1.relay.n0.iroh.link/",
      readinessId: "ready-clear",
      processId: process.pid,
    };
    const irohDir = join(dataDir, "iroh");
    const otherPath = join(irohDir, "server-secret.json");

    await writeIrohInviteState(dataDir, state);
    writeFileSync(otherPath, JSON.stringify({ secretKey: [] }), { mode: 0o600 });

    clearIrohInviteState(dataDir);

    expect(readIrohInviteState(dataDir)).toBeUndefined();
    expect(statSync(otherPath).mode & 0o777).toBe(0o600);
  });

  it("refuses to publish state that does not advertise the pairing ALPN", () => {
    const state = {
      version: 2 as const,
      nodeId: "iroh-node-no-pairing",
      alpns: ["oppi/http/1"],
      addressMode: "node-id" as const,
      relayMode: "default" as const,
      ticketHomeRelay: "https://use1-1.relay.n0.iroh.link/",
      readinessId: "ready-no-pair",
      processId: process.pid,
    };

    expect(() => writeIrohInviteState(dataDir, state)).toThrow(
      "Iroh invite state must advertise oppi/pair/1",
    );
  });

  it("ignores malformed persisted state and clamps readable files back to private mode", () => {
    const irohDir = join(dataDir, "iroh");
    const statePath = join(irohDir, "invite.json");
    mkdirSync(irohDir, { recursive: true, mode: 0o700 });
    writeFileSync(
      statePath,
      JSON.stringify({
        version: 2,
        nodeId: "iroh-node-readable",
        alpns: ["oppi/http/1"],
        addressMode: "node-id",
      }),
      { mode: 0o644 },
    );
    chmodSync(statePath, 0o644);

    expect(readIrohInviteState(dataDir)).toBeUndefined();
    expect(statSync(statePath).mode & 0o777).toBe(0o600);
  });
});
