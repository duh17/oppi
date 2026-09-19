import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { createServer } from "node:https";
import { connect } from "node:tls";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

function requireOpenSSL(): void {
  try {
    execFileSync("openssl", ["version"], { stdio: "ignore" });
  } catch {
    throw new Error("openssl is required for TLS identity tests");
  }
}

function openssl(args: string[], cwd: string): void {
  execFileSync("openssl", args, { cwd, stdio: "pipe" });
}

describe("TLS identity", () => {
  const dirs: string[] = [];
  afterEach(() => {
    for (const dir of dirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("accepts a trusted test CA with the correct hostname and rejects the rest", async () => {
    requireOpenSSL();
    const dir = mkdtempSync(join(tmpdir(), "oppi-tls-id-"));
    dirs.push(dir);

    openssl(
      [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-keyout",
        "ca.key",
        "-out",
        "ca.crt",
        "-days",
        "2",
        "-nodes",
        "-subj",
        "/CN=oppi-rp39-test-ca",
      ],
      dir,
    );
    writeFileSync(join(dir, "san.cnf"), "subjectAltName=DNS:oppi.rp39.test\n");
    openssl(
      [
        "req",
        "-newkey",
        "rsa:2048",
        "-keyout",
        "server.key",
        "-out",
        "server.csr",
        "-nodes",
        "-subj",
        "/CN=oppi.rp39.test",
      ],
      dir,
    );
    openssl(
      [
        "x509",
        "-req",
        "-in",
        "server.csr",
        "-CA",
        "ca.crt",
        "-CAkey",
        "ca.key",
        "-CAcreateserial",
        "-out",
        "server.crt",
        "-days",
        "2",
        "-extfile",
        "san.cnf",
      ],
      dir,
    );
    const ca = readFileSync(join(dir, "ca.crt"));
    const listen = (certFile: string, keyFile: string) =>
      new Promise<{ port: number; close: () => Promise<void> }>((resolve, reject) => {
        const server = createServer(
          {
            cert: readFileSync(join(dir, certFile)),
            key: readFileSync(join(dir, keyFile)),
          },
          (_req, res) => {
            res.end("ok");
          },
        );
        server.listen(0, "127.0.0.1", () => {
          const address = server.address();
          if (!address || typeof address === "string") {
            reject(new Error("bind failed"));
            return;
          }
          resolve({
            port: address.port,
            close: () =>
              new Promise((closeResolve, closeReject) => {
                server.close((error) => (error ? closeReject(error) : closeResolve()));
              }),
          });
        });
      });

    const handshake = (port: number, opts: { servername: string; ca?: Buffer }) =>
      new Promise<boolean>((resolve) => {
        const socket = connect(
          {
            host: "127.0.0.1",
            port,
            servername: opts.servername,
            ca: opts.ca,
            rejectUnauthorized: true,
          },
          () => {
            socket.end();
            resolve(true);
          },
        );
        socket.on("error", () => resolve(false));
      });

    const good = await listen("server.crt", "server.key");
    try {
      expect(await handshake(good.port, { servername: "oppi.rp39.test", ca })).toBe(true);
      expect(await handshake(good.port, { servername: "wrong.example", ca })).toBe(false);
      expect(await handshake(good.port, { servername: "oppi.rp39.test" })).toBe(false);
    } finally {
      await good.close();
    }
  });
});
