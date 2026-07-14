import { randomUUID, createHash } from "node:crypto";
import {
  chmodSync,
  closeSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { createConnection, type Server as NetServer } from "node:net";
import { dirname, join, resolve } from "node:path";

const MAX_PORTABLE_UNIX_SOCKET_PATH_BYTES = 100;
const LOCAL_API_RUNTIME_DIRECTORY = "run";
const LOCAL_API_SOCKET_NAME = "oppi.sock";
const PROCESS_INSTANCE_TOKEN = randomUUID();

type SocketIdentity = { dev: number; ino: number };

type SocketLockRecord = {
  pid: number;
  token: string;
  processInstanceToken: string;
};

export type LocalApiSocketBinding = {
  socketPath: string;
  release(): void;
};

export function localApiSocketPath(dataDir: string): string {
  const preferredPath = join(dataDir, LOCAL_API_RUNTIME_DIRECTORY, LOCAL_API_SOCKET_NAME);
  if (socketPathFits(preferredPath)) return preferredPath;

  const uid = process.getuid?.() ?? "user";
  const dataDirHash = createHash("sha256").update(resolve(dataDir)).digest("hex").slice(0, 16);
  const fallbackPath = join("/tmp", `oppi-${uid}`, `${dataDirHash}.sock`);
  if (socketPathFits(fallbackPath)) return fallbackPath;

  throw new Error(
    `Oppi local API socket path is too long (${Buffer.byteLength(fallbackPath)} bytes): ${fallbackPath}`,
  );
}

export async function listenOnLocalApiSocket(
  server: NetServer,
  path: string,
): Promise<LocalApiSocketBinding> {
  ensurePrivateRuntimeDirectory(dirname(path));
  const lock = acquireSocketLock(`${path}.lock`);

  try {
    await removeStaleSocket(path);
    await listen(server, path);

    try {
      chmodSync(path, 0o600);
      const stat = lstatSync(path);
      const identity = { dev: stat.dev, ino: stat.ino };
      let released = false;
      return {
        socketPath: path,
        release: () => {
          if (released) return;
          released = true;
          removeSocketWithIdentity(path, identity);
          lock.release();
        },
      };
    } catch (error: unknown) {
      await closeServer(server);
      removeOwnedSocket(path);
      throw error;
    }
  } catch (error: unknown) {
    lock.release();
    throw error;
  }
}

function socketPathFits(path: string): boolean {
  return Buffer.byteLength(path) <= MAX_PORTABLE_UNIX_SOCKET_PATH_BYTES;
}

function ensurePrivateRuntimeDirectory(path: string): void {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const stat = lstatSync(path);
  if (!stat.isDirectory()) {
    throw new Error(`Oppi local API runtime path is not a directory: ${path}`);
  }
  const uid = process.getuid?.();
  if (uid !== undefined && stat.uid !== uid) {
    throw new Error(`Oppi local API runtime directory is owned by uid ${stat.uid}: ${path}`);
  }
  chmodSync(path, 0o700);
}

function acquireSocketLock(path: string): { release(): void } {
  const record: SocketLockRecord = {
    pid: process.pid,
    token: randomUUID(),
    processInstanceToken: PROCESS_INSTANCE_TOKEN,
  };
  const serialized = `${JSON.stringify(record)}\n`;

  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const fd = openSync(path, "wx", 0o600);
      try {
        writeFileSync(fd, serialized, "utf8");
      } catch (error: unknown) {
        unlinkSync(path);
        throw error;
      } finally {
        closeSync(fd);
      }
      return {
        release: () => {
          try {
            if (readFileSync(path, "utf8") === serialized) unlinkSync(path);
          } catch (error: unknown) {
            if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
          }
        },
      };
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    }

    const existing = readSocketLock(path);
    const currentProcessOwnsLock =
      existing.pid === process.pid && existing.processInstanceToken === PROCESS_INSTANCE_TOKEN;
    if (
      currentProcessOwnsLock ||
      (existing.pid !== process.pid && isProcessRunning(existing.pid))
    ) {
      throw new Error(`Oppi local API startup is already owned by pid ${existing.pid}: ${path}`);
    }

    try {
      if (readFileSync(path, "utf8") === existing.serialized) unlinkSync(path);
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }

  throw new Error(`Could not acquire Oppi local API startup lock: ${path}`);
}

function readSocketLock(path: string): SocketLockRecord & { serialized: string } {
  const stat = lstatSync(path);
  if (!stat.isFile()) {
    throw new Error(`Refusing to replace non-file local API startup lock: ${path}`);
  }
  const uid = process.getuid?.();
  if (uid !== undefined && stat.uid !== uid) {
    throw new Error(`Refusing to replace local API startup lock owned by uid ${stat.uid}: ${path}`);
  }

  const serialized = readFileSync(path, "utf8");
  let parsed: unknown;
  try {
    parsed = JSON.parse(serialized) as unknown;
  } catch {
    throw new Error(`Refusing to replace invalid local API startup lock: ${path}`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`Refusing to replace invalid local API startup lock: ${path}`);
  }
  const record = parsed as {
    pid?: unknown;
    token?: unknown;
    processInstanceToken?: unknown;
  };
  if (
    !Number.isInteger(record.pid) ||
    Number(record.pid) < 1 ||
    typeof record.token !== "string" ||
    typeof record.processInstanceToken !== "string"
  ) {
    throw new Error(`Refusing to replace invalid local API startup lock: ${path}`);
  }
  return {
    pid: Number(record.pid),
    token: record.token,
    processInstanceToken: record.processInstanceToken,
    serialized,
  };
}

function isProcessRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error: unknown) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

function listen(server: NetServer, path: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const onError = (error: Error): void => reject(error);
    server.once("error", onError);
    server.listen(path, () => {
      server.off("error", onError);
      resolve();
    });
  });
}

function closeServer(server: NetServer): Promise<void> {
  if (!server.listening) return Promise.resolve();
  return new Promise((resolve) => server.close(() => resolve()));
}

function removeSocketWithIdentity(path: string, identity: SocketIdentity): void {
  try {
    const stat = lstatSync(path);
    if (stat.isSocket() && stat.dev === identity.dev && stat.ino === identity.ino) unlinkSync(path);
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

function removeOwnedSocket(path: string): void {
  try {
    const stat = lstatSync(path);
    const uid = process.getuid?.();
    if (stat.isSocket() && (uid === undefined || stat.uid === uid)) unlinkSync(path);
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

async function removeStaleSocket(path: string): Promise<void> {
  let stat;
  try {
    stat = lstatSync(path);
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw error;
  }

  if (!stat.isSocket()) {
    throw new Error(`Refusing to replace non-socket local API path: ${path}`);
  }
  const uid = process.getuid?.();
  if (uid !== undefined && stat.uid !== uid) {
    throw new Error(`Refusing to replace local API socket owned by uid ${stat.uid}: ${path}`);
  }
  if (await canConnect(path)) {
    throw new Error(`Oppi local API socket is already in use: ${path}`);
  }
  unlinkSync(path);
}

function canConnect(path: string): Promise<boolean> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(path);
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", (error: NodeJS.ErrnoException) => {
      socket.destroy();
      if (error.code === "ECONNREFUSED" || error.code === "ENOENT") {
        resolve(false);
        return;
      }
      reject(error);
    });
  });
}
