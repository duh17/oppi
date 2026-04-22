import { spawn, type ChildProcess } from "node:child_process";

function waitForSpawn(child: ChildProcess): Promise<void> {
  return new Promise((resolve, reject) => {
    const handleSpawn = () => {
      cleanup();
      resolve();
    };

    const handleError = (error: Error) => {
      cleanup();
      reject(error);
    };

    const cleanup = () => {
      child.off("spawn", handleSpawn);
      child.off("error", handleError);
    };

    child.once("spawn", handleSpawn);
    child.once("error", handleError);
  });
}

export async function openBrowser(url: string): Promise<void> {
  const child =
    process.platform === "darwin"
      ? spawn("open", [url], { detached: true, stdio: "ignore" })
      : process.platform === "win32"
        ? spawn("cmd", ["/c", "start", "", url], { detached: true, stdio: "ignore" })
        : spawn("xdg-open", [url], { detached: true, stdio: "ignore" });

  await waitForSpawn(child);
  child.unref();
}
