import { WebSocket } from "ws";

interface WaitForOptions {
  timeoutMs?: number;
  intervalMs?: number;
  description?: string;
}

export async function waitForCondition(
  predicate: () => boolean,
  options: WaitForOptions = {},
): Promise<void> {
  const timeoutMs = options.timeoutMs ?? 1_000;
  const intervalMs = options.intervalMs ?? 10;
  const description = options.description ?? "condition";
  const deadline = Date.now() + timeoutMs;

  while (!predicate()) {
    if (Date.now() >= deadline) {
      throw new Error(`Timed out waiting for ${description}`);
    }
    await delay(intervalMs);
  }
}

export function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

export async function flushMicrotasks(turns = 2): Promise<void> {
  for (let i = 0; i < turns; i += 1) {
    await Promise.resolve();
  }
}

export function waitForClose(
  ws: WebSocket,
  timeoutMs = 1_000,
): Promise<{ code: number; reason: Buffer }> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.off("close", onClose);
      ws.off("error", onError);
      reject(new Error("WS close timeout"));
    }, timeoutMs);

    const onClose = (code: number, reason: Buffer): void => {
      clearTimeout(timer);
      ws.off("error", onError);
      resolve({ code, reason });
    };

    const onError = (error: Error): void => {
      clearTimeout(timer);
      ws.off("close", onClose);
      reject(error);
    };

    ws.once("close", onClose);
    ws.once("error", onError);
  });
}

export async function waitForReadyState(
  ws: WebSocket,
  readyState: number,
  options: WaitForOptions = {},
): Promise<void> {
  await waitForCondition(() => ws.readyState === readyState, {
    ...options,
    description: options.description ?? `readyState=${readyState}`,
  });
}
