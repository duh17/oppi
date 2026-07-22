import { EventEmitter } from "node:events";

import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

class FakeBridgeWebSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  sent: Array<Record<string, unknown>> = [];
  closeCode?: number;

  send(data: string): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
  }

  close(code?: number): void {
    this.readyState = WebSocket.CLOSED;
    this.closeCode = code;
  }

  receive(message: Record<string, unknown>): void {
    this.emit("message", Buffer.from(JSON.stringify(message)), false);
  }
}

function taskRecordHello(bridgeId: string): Record<string, unknown> {
  return {
    type: "hello",
    protocolVersion: 2,
    bridgeId,
    cwd: "/tmp/oppi-mirror-test",
    capabilities: ["input_preflight:v1"],
    state: {
      piSessionId: "pi-task",
      sessionName: "general-purpose#738f21e6",
    },
  };
}

describe("PiTuiMirrorRuntime rejection logging", () => {
  it("suppresses repeated no-trace task-record rejection logs", async () => {
    const previousLogLevel = process.env.OPPI_LOG_LEVEL;
    process.env.OPPI_LOG_LEVEL = "debug";
    vi.resetModules();
    const { PiTuiMirrorRuntime } = await import("../src/pi-tui-mirror-runtime.js");
    const writes: string[] = [];
    const writeSpy = vi.spyOn(process.stderr, "write").mockImplementation((chunk) => {
      writes.push(String(chunk));
      return true;
    });
    try {
      const storage = {
        getConfig: () => ({ dataDir: "/tmp/oppi-mirror-test-config" }),
        getDataDir: () => "/tmp/oppi-mirror-test-config",
      };
      const runtime = new PiTuiMirrorRuntime(storage as never);

      for (let index = 0; index < 3; index += 1) {
        const ws = new FakeBridgeWebSocket();
        runtime.handleBridgeWebSocket(ws as unknown as WebSocket);
        ws.receive(taskRecordHello(`bridge-task-${index}`));
        expect(ws.sent.at(-1)).toMatchObject({
          type: "error",
          code: "pi_tui_task_record_not_openable",
        });
        expect(ws.closeCode).toBe(1008);
      }
    } finally {
      writeSpy.mockRestore();
      if (previousLogLevel === undefined) delete process.env.OPPI_LOG_LEVEL;
      else process.env.OPPI_LOG_LEVEL = previousLogLevel;
      vi.resetModules();
    }

    const rejectionLogs = writes
      .flatMap((chunk) => chunk.trim().split("\n").filter(Boolean))
      .map((line) => JSON.parse(line) as Record<string, unknown>)
      .filter((record) => record.event === "mirror_bridge.message_rejected");

    expect(rejectionLogs).toHaveLength(1);
    expect(rejectionLogs[0]).toMatchObject({
      level: "debug",
      code: "pi_tui_task_record_not_openable",
    });
  });
});
