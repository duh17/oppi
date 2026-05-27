import type { IncomingMessage } from "node:http";
import { Readable } from "node:stream";

export interface MockResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  writeHead: (status: number, headers: Record<string, string>) => MockResponse;
  end: (payload?: string) => void;
}

export function makeResponse(): MockResponse {
  return {
    statusCode: 0,
    headers: {},
    body: "",
    writeHead(status: number, headers: Record<string, string>): MockResponse {
      this.statusCode = status;
      this.headers = headers;
      return this;
    },
    end(payload?: string): void {
      this.body = payload ?? "";
    },
  };
}

export function makeRequest(body?: unknown): IncomingMessage {
  const text = body === undefined ? "" : JSON.stringify(body);
  const req = Readable.from(text ? [text] : []) as unknown as IncomingMessage & {
    socket?: { remoteAddress?: string };
  };
  req.socket = { remoteAddress: "127.0.0.1" };
  return req;
}

export function makeRawRequest(body: Buffer | string): IncomingMessage {
  const req = Readable.from([body]) as unknown as IncomingMessage & {
    socket?: { remoteAddress?: string };
  };
  req.socket = { remoteAddress: "127.0.0.1" };
  return req;
}
