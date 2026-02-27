import { WebSocket, type RawData } from "ws";
import type { ClientMessage, ServerMessage } from "../../src/types.js";

export function connectStream(baseWsUrl: string, token: string): WebSocket {
  return new WebSocket(`${baseWsUrl}/stream`, {
    headers: { Authorization: `Bearer ${token}` },
  });
}

export function waitForOpen(ws: WebSocket, timeoutMs = 5_000): Promise<void> {
  return new Promise((resolve, reject) => {
    if (ws.readyState === WebSocket.OPEN) {
      resolve();
      return;
    }

    const timer = setTimeout(() => {
      ws.off("open", onOpen);
      ws.off("error", onError);
      reject(new Error("WS open timeout"));
    }, timeoutMs);

    const onOpen = (): void => {
      clearTimeout(timer);
      ws.off("error", onError);
      resolve();
    };

    const onError = (error: Error): void => {
      clearTimeout(timer);
      ws.off("open", onOpen);
      reject(error);
    };

    ws.once("open", onOpen);
    ws.once("error", onError);
  });
}

function parseServerMessage(data: RawData): ServerMessage {
  if (typeof data === "string") {
    return JSON.parse(data) as ServerMessage;
  }

  if (Buffer.isBuffer(data)) {
    return JSON.parse(data.toString("utf8")) as ServerMessage;
  }

  if (Array.isArray(data)) {
    return JSON.parse(Buffer.concat(data).toString("utf8")) as ServerMessage;
  }

  return JSON.parse(Buffer.from(data).toString("utf8")) as ServerMessage;
}

export function waitForMessage(
  ws: WebSocket,
  timeoutMs = 3_000,
): Promise<ServerMessage> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.off("message", onMessage);
      ws.off("error", onError);
      reject(new Error("Message timeout"));
    }, timeoutMs);

    const onMessage = (data: RawData): void => {
      clearTimeout(timer);
      ws.off("error", onError);
      resolve(parseServerMessage(data));
    };

    const onError = (error: Error): void => {
      clearTimeout(timer);
      ws.off("message", onMessage);
      reject(error);
    };

    ws.once("message", onMessage);
    ws.once("error", onError);
  });
}

export function collectMessages(ws: WebSocket, durationMs: number): Promise<ServerMessage[]> {
  return new Promise((resolve) => {
    const messages: ServerMessage[] = [];

    const onMessage = (data: RawData): void => {
      messages.push(parseServerMessage(data));
    };

    ws.on("message", onMessage);

    setTimeout(() => {
      ws.off("message", onMessage);
      resolve(messages);
    }, durationMs);
  });
}

export function sendClientMessage(ws: WebSocket, message: ClientMessage): void {
  ws.send(JSON.stringify(message));
}

export function messagesOfType<TType extends ServerMessage["type"]>(
  messages: ServerMessage[],
  type: TType,
): Array<Extract<ServerMessage, { type: TType }>> {
  return messages.filter(
    (message): message is Extract<ServerMessage, { type: TType }> => message.type === type,
  );
}

export function requireMessageOfType<TType extends ServerMessage["type"]>(
  messages: ServerMessage[],
  type: TType,
  predicate?: (message: Extract<ServerMessage, { type: TType }>) => boolean,
): Extract<ServerMessage, { type: TType }> {
  const message = messagesOfType(messages, type).find((candidate) => {
    if (!predicate) {
      return true;
    }
    return predicate(candidate);
  });

  if (!message) {
    throw new Error(`Expected ${type} message was not found`);
  }

  return message;
}
