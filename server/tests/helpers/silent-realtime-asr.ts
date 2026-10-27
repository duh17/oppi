import { createServer } from "node:http";
import type { AddressInfo } from "node:net";

import { WebSocketServer } from "ws";

/**
 * A realtime transcription endpoint that accepts the session and hears nothing: enough for a
 * Live Voice call to start and run. `endpoint` is what `asr.sttEndpoint` takes.
 */
export async function startSilentRealtimeAsr(): Promise<{
  endpoint: string;
  close: () => Promise<void>;
}> {
  const http = createServer();
  const wss = new WebSocketServer({ server: http });
  wss.on("connection", (socket) => {
    socket.on("message", (data) => {
      const event = JSON.parse(String(data)) as { type?: string };
      if (event.type === "session.update") socket.send(JSON.stringify({ type: "session.updated" }));
      // As the real server answers a commit with nothing open to cut: End finishes at once.
      if (event.type === "input_audio_buffer.commit") {
        socket.send(
          JSON.stringify({
            type: "error",
            error: { type: "invalid_request_error", code: "input_audio_buffer_commit_empty" },
          }),
        );
      }
    });
  });
  await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
  return {
    endpoint: `http://127.0.0.1:${(http.address() as AddressInfo).port}`,
    close: async () => {
      for (const client of wss.clients) client.terminate();
      await new Promise<void>((resolve) => wss.close(() => resolve()));
      await new Promise<void>((resolve) => http.close(() => resolve()));
    },
  };
}
