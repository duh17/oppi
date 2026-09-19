#!/usr/bin/env node
/**
 * App Review mint sidecar. Bind to loopback or an internal port that the
 * public reverse proxy does not forward. Uses `oppi pair --json` on the
 * shared data dir. Never log the secret or invite URL.
 */

import { createServer } from "node:http";
import { execFileSync } from "node:child_process";

const secret = process.env.REVIEW_MINT_SECRET || "";
if (secret.length < 16) {
  throw new Error("REVIEW_MINT_SECRET must be at least 16 characters");
}
const listenHost = process.env.REVIEW_MINT_HOST || "127.0.0.1";
const listenPort = Number(process.env.REVIEW_MINT_PORT || "8790");
const PREVIEW_UA =
  /facebookexternalhit|twitterbot|slackbot|linkedinbot|whatsapp|telegrambot|discordbot|applebot|bingpreview|googlebot|preview/i;

let outstanding = null;
let chain = Promise.resolve();

function redact(pathname) {
  return pathname.split(secret).join("<redacted>");
}

function mint() {
  const output = execFileSync("oppi", ["pair", "--json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: process.env,
  });
  const parsed = JSON.parse(output);
  if (typeof parsed.inviteURL !== "string" || !parsed.inviteURL.startsWith("oppi://")) {
    throw new Error("oppi pair did not return an invite URL");
  }
  return { inviteURL: parsed.inviteURL, expiresAt: Date.now() + 90_000 };
}

function connect(input) {
  const run = chain.then(async () => {
    const method = (input.method || "GET").toUpperCase();
    if (method === "HEAD" || method === "OPTIONS") return { status: "method_not_allowed" };
    if (method !== "GET") return { status: "method_not_allowed" };
    if (input.userAgent && PREVIEW_UA.test(input.userAgent)) return { status: "preview" };
    const now = Date.now();
    if (!input.retry && outstanding && outstanding.expiresAt > now) {
      return { status: "reused", invite: outstanding };
    }
    outstanding = mint();
    return { status: "minted", invite: outstanding };
  });
  chain = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}

const server = createServer((req, res) => {
  const url = new URL(req.url || "/", "http://127.0.0.1");
  const safePath = redact(url.pathname);
  res.setHeader("Cache-Control", "no-store");
  if (url.pathname === `/r/${secret}/revoke-link` && (req.method || "GET").toUpperCase() === "POST") {
    mint();
    outstanding = null;
    process.stdout.write(`mint link_revoked path=${safePath}\n`);
    res.writeHead(204);
    res.end();
    return;
  }
  if (url.pathname !== `/r/${secret}`) {
    process.stdout.write(`mint miss path=${safePath}\n`);
    res.writeHead(404);
    res.end();
    return;
  }
  void connect({
    method: req.method,
    userAgent: Array.isArray(req.headers["user-agent"])
      ? req.headers["user-agent"][0]
      : req.headers["user-agent"],
    retry: url.searchParams.get("retry") === "1",
  }).then((result) => {
    if (result.status === "preview" || result.status === "method_not_allowed") {
      process.stdout.write(`mint skipped reason=${result.status} path=${safePath}\n`);
      res.writeHead(result.status === "method_not_allowed" ? 405 : 200, {
        "Content-Type": "text/html; charset=utf-8",
      });
      res.end("<!doctype html><title>Oppi Review</title><p>Open this link in Oppi.</p>");
      return;
    }
    process.stdout.write(`mint ${result.status} path=${safePath}\n`);
    res.writeHead(302, { Location: result.invite.inviteURL });
    res.end();
  });
});

server.listen(listenPort, listenHost, () => {
  process.stdout.write(`review mint listening on ${listenHost}:${listenPort}\n`);
});
