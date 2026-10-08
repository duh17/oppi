import { describe, expect, it } from "vitest";

import {
  formatProgramStatusClear,
  formatProgramStatusReport,
  ProgramStatusEmitter,
  programStatusRecordId,
} from "../src/cli/program-status-osc.js";
import type { ProgramStatus } from "../src/types.js";

const b64 = (text: string) => Buffer.from(text, "utf8").toString("base64");

const SPEC_SEQUENCE =
  /^\x1b\]7501;[a-z]+=[A-Za-z0-9_.,+/=-]*(?::[a-z]+=[A-Za-z0-9_.,+/=-]*)*\x1b\\$/;
const SEGMENT = /^[A-Za-z0-9_.+-]{1,32}$/;

/** Parse a report the way a conforming terminal does and enforce the spec limits. */
function parseReport(sequence: string): Record<string, string> {
  expect(sequence).toMatch(SPEC_SEQUENCE);
  expect(Buffer.byteLength(sequence)).toBeLessThanOrEqual(4096);
  const body = sequence.slice("\x1b]7501;".length, -2);
  const pairs: Record<string, string> = {};
  for (const pair of body.split(":")) {
    const eq = pair.indexOf("=");
    const key = pair.slice(0, eq);
    expect(key.length).toBeLessThanOrEqual(16);
    pairs[key] = pair.slice(eq + 1);
  }
  if (pairs.id !== undefined) {
    expect(Buffer.byteLength(pairs.id)).toBeLessThanOrEqual(128);
    const segments = pairs.id.split("/");
    expect(segments.length).toBeLessThanOrEqual(8);
    for (const segment of segments) expect(segment).toMatch(SEGMENT);
  }
  if (pairs.app !== undefined) expect(pairs.app).toMatch(SEGMENT);
  if (pairs.msg !== undefined) {
    expect(pairs.msg.length).toBeLessThanOrEqual(2732);
    const decoded = Buffer.from(pairs.msg, "base64").toString("utf8");
    expect(Buffer.byteLength(decoded)).toBeLessThanOrEqual(2048);
    expect(decoded).not.toMatch(/[\u0000-\u001f\u007f-\u009f]/);
  }
  if (pairs.title !== undefined) {
    expect(pairs.title.length).toBeLessThanOrEqual(256);
    const decoded = Buffer.from(pairs.title, "base64").toString("utf8");
    expect(Buffer.byteLength(decoded)).toBeLessThanOrEqual(192);
    expect(decoded).not.toMatch(/[\u0000-\u001f\u007f-\u009f]/);
  }
  return pairs;
}

const status = (overrides: Partial<ProgramStatus> = {}): ProgramStatus => ({
  state: "working",
  since: 1,
  ...overrides,
});

describe("OSC 7501 report bytes", () => {
  it("writes the root record as ESC ] 7501 ; pairs ESC \\", () => {
    expect(formatProgramStatusReport(status({ message: "Installing updates" }))).toBe(
      `\x1b]7501;state=working:app=oppi:msg=SW5zdGFsbGluZyB1cGRhdGVz\x1b\\`,
    );
  });

  it("carries kind only for blocked", () => {
    expect(
      formatProgramStatusReport(
        status({ state: "blocked", kind: "permission", message: "Approve deploy?" }),
      ),
    ).toBe(`\x1b]7501;state=blocked:app=oppi:kind=permission:msg=${b64("Approve deploy?")}\x1b\\`);
    expect(formatProgramStatusReport(status({ state: "done", kind: "question" }))).toBe(
      "\x1b]7501;state=done:app=oppi\x1b\\",
    );
  });

  it("writes a child record with id, app, and base64 title", () => {
    const id = programStatusRecordId("123e4567-e89b-42d3-a456-426614174000");
    expect(id).toBe("123e4567e89b42d3a456426614174000");
    expect(id).toHaveLength(32);
    expect(
      formatProgramStatusReport(status({ state: "done", message: "Fix login" }), {
        id,
        title: "Fix login",
      }),
    ).toBe(
      `\x1b]7501;state=done:id=${id}:app=oppi:title=${b64("Fix login")}:msg=${b64("Fix login")}\x1b\\`,
    );
  });

  it("clears one record by id or every record without one", () => {
    expect(formatProgramStatusClear("abc")).toBe("\x1b]7501;state=clear:id=abc\x1b\\");
    expect(formatProgramStatusClear()).toBe("\x1b]7501;state=clear\x1b\\");
  });

  it("replaces control characters, which a terminal would reject, and omits an empty msg", () => {
    const sequence = formatProgramStatusReport(
      status({ message: "line one\nline\u001b[31m two\u0085" }),
    );
    const pairs = parseReport(sequence);
    expect(Buffer.from(pairs.msg!, "base64").toString()).toBe("line one line [31m two");
    expect(parseReport(formatProgramStatusReport(status({ message: "\n\t " }))).msg).toBeUndefined();
  });

  it("caps msg at 2048 and title at 192 decoded bytes without splitting a character", () => {
    const wide = "界".repeat(1000); // 3 bytes each
    const sequence = formatProgramStatusReport(status({ message: wide }), {
      id: "a",
      title: wide,
    });
    const pairs = parseReport(sequence);
    expect(Buffer.from(pairs.msg!, "base64").toString("utf8")).toBe("界".repeat(682));
    expect(Buffer.from(pairs.title!, "base64").toString("utf8")).toBe("界".repeat(64));
  });

  it("keeps a worst-case report inside the 4096-byte sequence limit", () => {
    const sequence = formatProgramStatusReport(
      status({ state: "blocked", kind: "question", message: "x".repeat(5000) }),
      { id: programStatusRecordId("123e4567-e89b-42d3-a456-426614174000"), title: "t".repeat(500) },
    );
    parseReport(sequence);
  });
});

function makeStream(isTTY: boolean) {
  const writes: string[] = [];
  return { isTTY, write: (chunk: string) => writes.push(chunk), writes };
}

const ID_A = "11111111-1111-4111-8111-111111111111";
const ID_B = "22222222-2222-4222-8222-222222222222";

describe("ProgramStatusEmitter", () => {
  it("writes nothing unless the stream is a TTY", () => {
    const pipe = makeStream(false);
    const emitter = new ProgramStatusEmitter(pipe, [ID_A]);
    emitter.update({ sessionId: ID_A, programStatus: status() });
    emitter.clear();
    expect(pipe.writes).toEqual([]);

    expect(() => {
      const none = new ProgramStatusEmitter(undefined, [ID_A]);
      none.update({ sessionId: ID_A, programStatus: status() });
      none.clear();
    }).not.toThrow();
  });

  it("reports a single session as the root record, once per change, and clears on exit", () => {
    const tty = makeStream(true);
    const emitter = new ProgramStatusEmitter(tty, [ID_A]);

    emitter.update({ sessionId: ID_A, name: "Fix login", programStatus: status() });
    emitter.update({ sessionId: ID_A, name: "Fix login", programStatus: status({ since: 99 }) });
    emitter.update({
      sessionId: ID_A,
      name: "Fix login",
      programStatus: status({ state: "done", message: "Fix login" }),
    });
    emitter.clear();

    expect(tty.writes).toEqual([
      "\x1b]7501;state=working:app=oppi\x1b\\",
      `\x1b]7501;state=done:app=oppi:msg=${b64("Fix login")}\x1b\\`,
      "\x1b]7501;state=clear\x1b\\",
    ]);
    emitter.clear();
    expect(tty.writes).toHaveLength(3);
  });

  it("reports several sessions as child records and clears each by id", () => {
    const tty = makeStream(true);
    const emitter = new ProgramStatusEmitter(tty, [ID_A, ID_B]);

    emitter.update({ sessionId: ID_A, name: "Alpha", programStatus: status() });
    emitter.update({
      sessionId: ID_B,
      programStatus: status({ state: "blocked", kind: "question", message: "Which?" }),
    });
    emitter.clear();

    const idA = programStatusRecordId(ID_A);
    const idB = programStatusRecordId(ID_B);
    expect(tty.writes).toEqual([
      `\x1b]7501;state=working:id=${idA}:app=oppi:title=${b64("Alpha")}\x1b\\`,
      `\x1b]7501;state=blocked:id=${idB}:app=oppi:kind=question:title=${b64("Session 22222222")}:msg=${b64("Which?")}\x1b\\`,
      `\x1b]7501;state=clear:id=${idA}\x1b\\`,
      `\x1b]7501;state=clear:id=${idB}\x1b\\`,
    ]);
    for (const write of tty.writes) parseReport(write);
  });

  it("skips sessions whose program status is unknown", () => {
    const tty = makeStream(true);
    const emitter = new ProgramStatusEmitter(tty, [ID_A]);
    emitter.update({ sessionId: ID_A });
    emitter.clear();
    expect(tty.writes).toEqual([]);
  });
});
