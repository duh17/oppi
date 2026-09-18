import { closeSync, createReadStream, openSync, readSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";

import {
  clampUtf8CodepointRange,
  logRejectedByteRange,
  parseByteRangeHeader,
} from "./http-range.js";

const TOOL_OUTPUT_SIDECAR_TYPE = "text/plain; charset=utf-8";

/**
 * Stream the existing full-tool-output sidecar as raw bytes.
 *
 * HEAD returns `Content-Length` from `stat` and does not read the file.
 * GET with `Range` returns 206. GET ranges are closed on UTF-8 codepoint
 * boundaries (`http-range.ts`); HEAD reports the unclamped length.
 */
export function streamFullToolOutputSidecar(
  sidecar: { path: string; size: number },
  req: IncomingMessage,
  res: ServerResponse,
  method = "GET",
): void {
  const commonHeaders = {
    "Content-Type": TOOL_OUTPUT_SIDECAR_TYPE,
    "Cache-Control": "private, no-cache",
    "Accept-Ranges": "bytes",
  };
  const range = parseByteRangeHeader(req.headers?.range, sidecar.size);
  const isHeadRequest = method.toUpperCase() === "HEAD";

  if (range.kind === "invalid" || range.kind === "unsatisfiable") {
    logRejectedByteRange("tool-output-sidecar", req.headers?.range, range.kind, sidecar.size);
    res.writeHead(416, {
      ...commonHeaders,
      "Content-Range": `bytes */${sidecar.size}`,
      "Content-Length": "0",
    });
    res.end();
    return;
  }

  if (range.kind === "valid") {
    let start = range.start;
    let end = range.end;
    if (!isHeadRequest) {
      const clamped = clampSidecarUtf8Range(sidecar.path, start, end, sidecar.size);
      if ("kind" in clamped) {
        logRejectedByteRange(
          "tool-output-sidecar",
          req.headers?.range,
          "unsatisfiable",
          sidecar.size,
        );
        res.writeHead(416, {
          ...commonHeaders,
          "Content-Range": `bytes */${sidecar.size}`,
          "Content-Length": "0",
        });
        res.end();
        return;
      }
      start = clamped.start;
      end = clamped.end;
    }
    const contentLength = end - start + 1;
    res.writeHead(206, {
      ...commonHeaders,
      "Content-Range": `bytes ${start}-${end}/${sidecar.size}`,
      "Content-Length": contentLength.toString(),
    });
    if (isHeadRequest) {
      res.end();
      return;
    }
    pipeSidecar(sidecar.path, res, { start, end });
    return;
  }

  res.writeHead(200, {
    ...commonHeaders,
    "Content-Length": sidecar.size.toString(),
  });
  if (isHeadRequest) {
    res.end();
    return;
  }
  pipeSidecar(sidecar.path, res);
}

function clampSidecarUtf8Range(
  path: string,
  start: number,
  end: number,
  fileSize: number,
): { start: number; end: number } | { kind: "empty" } {
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(1);
    return clampUtf8CodepointRange(start, end, fileSize, (offset) => {
      const n = readSync(fd, buf, 0, 1, offset);
      return n > 0 ? (buf[0] ?? 0) : 0;
    });
  } finally {
    closeSync(fd);
  }
}

function pipeSidecar(
  filePath: string,
  res: ServerResponse,
  range?: { start: number; end: number },
): void {
  const stream = range
    ? createReadStream(filePath, { start: range.start, end: range.end })
    : createReadStream(filePath);

  stream.on("error", (error) => {
    if (!res.headersSent) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Failed to read tool output" }));
      return;
    }
    res.destroy(error);
  });
  stream.pipe(res as NodeJS.WritableStream);
}
