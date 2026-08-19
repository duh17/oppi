/**
 * Loads protocol/pi-events.json and runs the AgentSessionEvent examples
 * through translatePiEvent. This is the consumer that keeps the catalog honest.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import { PROTOCOL_DIR } from "./protocol-fixtures.js";

const PI_EVENTS_FILE = resolve(PROTOCOL_DIR, "pi-events.json");

/** Top-level event types with a named case in translatePiEvent. */
const TRANSLATED_EVENT_TYPES = [
  "agent_start",
  "agent_end",
  "agent_settled",
  "turn_start",
  "turn_end",
  "message_start",
  "message_update",
  "message_end",
  "tool_execution_start",
  "tool_execution_update",
  "tool_execution_end",
  "compaction_start",
  "compaction_end",
  "auto_retry_start",
  "auto_retry_end",
] as const;

/** message_update subtypes that take a distinct translation path. */
const TRANSLATED_MESSAGE_UPDATE_TYPES = [
  "text_delta",
  "thinking_start",
  "thinking_delta",
  "thinking_end",
  "error",
  "toolcall_delta",
] as const;

/**
 * Catalog entries that are not AgentSessionEvent inputs to translatePiEvent.
 * `response` is a Pi TUI RPC frame. The extension_* shapes are SessionBackendEvent.
 */
const CATALOG_ONLY_EVENT_TYPES = ["response", "extension_ui_request", "extension_error"] as const;

type PiEventsFixture = {
  _meta: { description?: string; generated?: string; eventCount: number };
  events: Array<Record<string, unknown> & { type: string; _label: string }>;
};

function makeCtx(): TranslationContext {
  return {
    sessionId: "pi-events-fixture",
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    streamedThinkingContentIndexes: new Set(),
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map(),
  };
}

function loadFixture(): PiEventsFixture {
  return JSON.parse(readFileSync(PI_EVENTS_FILE, "utf-8")) as PiEventsFixture;
}

function stripLabel(raw: Record<string, unknown>): Record<string, unknown> {
  const { _label: _unused, ...event } = raw;
  return event;
}

describe("pi-events.json catalog", () => {
  const fixture = loadFixture();

  it("is well-formed and matches its declared event count", () => {
    expect(Array.isArray(fixture.events)).toBe(true);
    expect(fixture.events.length).toBe(fixture._meta.eventCount);
    for (const event of fixture.events) {
      expect(event.type, event._label).toBeTypeOf("string");
      expect(event._label, event.type).toBeTypeOf("string");
      expect(event._label.length, event.type).toBeGreaterThan(0);
    }
  });

  it("only contains translated AgentSessionEvent types or documented catalog-only types", () => {
    const allowed = new Set<string>([...TRANSLATED_EVENT_TYPES, ...CATALOG_ONLY_EVENT_TYPES]);
    const unknown = [
      ...new Set(fixture.events.map((event) => event.type).filter((type) => !allowed.has(type))),
    ];
    expect(unknown).toEqual([]);
  });

  it("includes at least one example for every translatePiEvent named case", () => {
    const present = new Set(fixture.events.map((event) => event.type));
    const missing = TRANSLATED_EVENT_TYPES.filter((type) => !present.has(type));
    expect(missing).toEqual([]);
  });

  it("includes the message_update subtypes that take a distinct translation path", () => {
    const present = new Set(
      fixture.events
        .filter((event) => event.type === "message_update")
        .map((event) => {
          const assistant = event.assistantMessageEvent;
          if (typeof assistant !== "object" || assistant === null || Array.isArray(assistant)) {
            return undefined;
          }
          const type = (assistant as { type?: unknown }).type;
          return typeof type === "string" ? type : undefined;
        })
        .filter((type): type is string => type !== undefined),
    );
    const missing = TRANSLATED_MESSAGE_UPDATE_TYPES.filter((type) => !present.has(type));
    expect(missing).toEqual([]);
  });

  it("translates every AgentSessionEvent example without throwing", () => {
    const catalogOnly = new Set<string>(CATALOG_ONLY_EVENT_TYPES);
    for (const raw of fixture.events) {
      if (catalogOnly.has(raw.type)) {
        continue;
      }

      const event = stripLabel(raw) as AgentSessionEvent;
      const messages = translatePiEvent(event, makeCtx());
      expect(Array.isArray(messages), raw._label).toBe(true);
      for (const message of messages) {
        expect(message.type, `${raw._label} -> ${JSON.stringify(message)}`).toBeTypeOf("string");
      }
    }
  });
});
