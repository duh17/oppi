import { spawn, type ChildProcess } from "node:child_process";

/**
 * How long to wait for the opener to exit. `open` and most `xdg-open` handlers
 * exit quickly; some `xdg-open` backends stay attached to the browser, so a
 * still-running opener after this bound counts as launched.
 */
const OPENER_SETTLE_MS = 2_000;

function waitForLaunch(child: ChildProcess, settleMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    let timer: NodeJS.Timeout | undefined;

    const finish = (error?: Error): void => {
      if (timer) clearTimeout(timer);
      child.off("spawn", handleSpawn);
      child.off("error", handleError);
      child.off("exit", handleExit);
      if (error) {
        reject(error);
      } else {
        resolve();
      }
    };

    const handleSpawn = (): void => {
      timer = setTimeout(() => finish(), settleMs);
    };

    const handleError = (error: Error): void => {
      finish(error);
    };

    const handleExit = (code: number | null, signal: NodeJS.Signals | null): void => {
      if (code === 0) {
        finish();
        return;
      }
      finish(new Error(`Browser opener exited with ${code !== null ? `code ${code}` : signal}`));
    };

    child.once("spawn", handleSpawn);
    child.once("error", handleError);
    child.once("exit", handleExit);
  });
}

export async function openBrowser(url: string): Promise<void> {
  const child =
    process.platform === "darwin"
      ? spawn("open", [url], { detached: true, stdio: "ignore" })
      : process.platform === "win32"
        ? spawn("cmd", ["/c", "start", "", url], { detached: true, stdio: "ignore" })
        : spawn("xdg-open", [url], { detached: true, stdio: "ignore" });

  await waitForLaunch(child, OPENER_SETTLE_MS);
  child.unref();
}
