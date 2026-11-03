import type { Extension as DurableExtension } from "@earendil-works/pi-durable";
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";

/**
 * What an extension tells the model, as an extension's detail shows it: each tool's definition
 * and each prompt section's text. A plugin's come from its loaded extension value; a classic Pi
 * extension's tools from the catalog loader's `registerTool` definitions (classic
 * `before_agent_start` prompt edits cannot be read without a session).
 *
 * Everything is bounded: a block over its cap is left out rather than cut, so what the client
 * shows is always the whole of it. Newlines stay; a description or section is prose the reader
 * lays out, unlike the one-line messages of the list.
 */

/** Which sessions a tool reaches: a plugin's run in durable sessions, a classic one's in Pi's. */
export type ToolDefinitionOrigin = "plugin" | "pi-extension";

export interface ServerToolDefinition {
  name: string;
  description?: string;
  /** The arguments' JSON Schema; absent when it is not plain JSON or is over the cap. */
  parameters?: Record<string, unknown>;
  /** A classic tool's line in Pi's default prompt's tool list. */
  promptSnippet?: string;
  /** A classic tool's bullets in Pi's default prompt's guidelines, while it is active. */
  promptGuidelines?: string[];
  from: ToolDefinitionOrigin;
}

export interface ServerPromptSection {
  name: string;
  /** The section as its plugin writes it, before other plugins' wraps. Absent per conversation. */
  text?: string;
  /**
   * Written for each conversation: the trial render read the conversation, returned a promise,
   * threw, returned nothing, or was over the cap or the time budget.
   */
  perConversation: boolean;
}

const MAX_NAME = 256;
const MAX_DESCRIPTION = 16 * 1024;
const MAX_SECTION_TEXT = 32 * 1024;
/** Bytes of the schema's JSON text. */
const MAX_SCHEMA_JSON = 64 * 1024;
const MAX_GUIDELINES = 32;
const MAX_GUIDELINE = 2048;
/**
 * How long one extension's trial renders may take together. A synchronous render cannot be
 * interrupted, so this bounds the route by sections, not by the clock: a render that finishes past
 * it is per conversation, and so is every section after it, unrendered.
 */
const SECTION_PROBE_BUDGET_MS = 200;

/** A plugin's tools as its loaded extension defines them. A tool that cannot be read is left out. */
export function pluginToolDefinitions(extension: DurableExtension): ServerToolDefinition[] {
  const definitions: ServerToolDefinition[] = [];
  for (const tool of extension.tools ?? []) {
    try {
      definitions.push(
        toolDefinition(
          "plugin",
          tool.name,
          tool.description,
          tool.parameters,
          undefined,
          undefined,
        ),
      );
    } catch {
      // A getter that throws: nothing of this tool is shown.
    }
  }
  return definitions;
}

/** A classic extension's tools as `registerTool` defined them, by name. */
export function classicToolDefinitions(
  tools: Iterable<{ definition: ToolDefinition }>,
): ServerToolDefinition[] {
  const definitions: ServerToolDefinition[] = [];
  for (const { definition } of tools) {
    try {
      definitions.push(
        toolDefinition(
          "pi-extension",
          definition.name,
          definition.description,
          definition.parameters,
          definition.promptSnippet,
          definition.promptGuidelines,
        ),
      );
    } catch {
      // As above.
    }
  }
  return definitions.sort((left, right) => left.name.localeCompare(right.name, "en-US"));
}

/**
 * A plugin's prompt sections. Each is rendered once with a trapped input and context that throw on
 * any read, so a section shows text only when it is a plain string that never looks at the
 * conversation. Anything else is per conversation; no rejection or exception escapes.
 */
export function promptSections(extension: DurableExtension): ServerPromptSection[] {
  const deadline = Date.now() + SECTION_PROBE_BUDGET_MS;
  const sections: ServerPromptSection[] = [];
  for (const section of extension.sections ?? []) {
    let name: string;
    try {
      name = boundText(String(section.key), MAX_NAME);
    } catch {
      continue;
    }
    const text = Date.now() < deadline ? trialRender(section) : undefined;
    sections.push(
      text === undefined || Date.now() >= deadline
        ? { name, perConversation: true }
        : { name, text, perConversation: false },
    );
  }
  return sections;
}

/** The section's text when it rendered a string without reading the trap, else undefined. */
function trialRender(
  section: NonNullable<DurableExtension["sections"]>[number],
): string | undefined {
  // An `async` render is never called: its body runs up to its first `await` at once and the rest
  // later, with nothing to stop it (a fetch on every open). It is per conversation unrun.
  if (isAsyncFunction(section.render)) return undefined;
  let touched = false;
  const trap = conversationTrap(() => {
    touched = true;
  });
  let result: unknown;
  try {
    result = section.render(trap as never, trap as never);
    if (isThenable(result)) {
      // A plain function that returned a promise: per conversation, its outcome ignored.
      Promise.resolve(result).then(undefined, () => undefined);
      return undefined;
    }
  } catch {
    return undefined;
  }
  // A render that caught the trap's throw still read the conversation.
  if (touched || typeof result !== "string" || result.length > MAX_SECTION_TEXT) return undefined;
  return boundText(result, MAX_SECTION_TEXT);
}

function isAsyncFunction(value: unknown): boolean {
  const tag = Object.prototype.toString.call(value);
  return tag === "[object AsyncFunction]" || tag === "[object AsyncGeneratorFunction]";
}

function isThenable(value: unknown): boolean {
  return (
    (typeof value === "object" || typeof value === "function") &&
    value !== null &&
    typeof (value as { then?: unknown }).then === "function"
  );
}

/** An object every operation on throws, after `onRead` notes it. */
function conversationTrap(onRead: () => void): object {
  const refuse = (): never => {
    onRead();
    throw new Error("A trial render cannot read the conversation");
  };
  return new Proxy(Object.create(null) as object, {
    get: refuse,
    has: refuse,
    ownKeys: refuse,
    getOwnPropertyDescriptor: refuse,
    getPrototypeOf: refuse,
    setPrototypeOf: refuse,
    isExtensible: refuse,
    preventExtensions: refuse,
    set: refuse,
    defineProperty: refuse,
    deleteProperty: refuse,
  });
}

function toolDefinition(
  from: ToolDefinitionOrigin,
  name: unknown,
  description: unknown,
  parameters: unknown,
  promptSnippet: unknown,
  promptGuidelines: unknown,
): ServerToolDefinition {
  const schema = jsonSchema(parameters);
  const guidelines = Array.isArray(promptGuidelines)
    ? promptGuidelines
        .slice(0, MAX_GUIDELINES)
        .filter((line): line is string => typeof line === "string" && line.length <= MAX_GUIDELINE)
        .map((line) => boundText(line, MAX_GUIDELINE))
    : [];
  return {
    name: boundText(String(name), MAX_NAME),
    ...(typeof description === "string" && description && description.length <= MAX_DESCRIPTION
      ? { description: boundText(description, MAX_DESCRIPTION) }
      : {}),
    ...(schema ? { parameters: schema } : {}),
    ...(typeof promptSnippet === "string" && promptSnippet && promptSnippet.length <= MAX_GUIDELINE
      ? { promptSnippet: boundText(promptSnippet, MAX_GUIDELINE) }
      : {}),
    ...(guidelines.length > 0 ? { promptGuidelines: guidelines } : {}),
    from,
  };
}

/**
 * `value` as plain JSON when it is an object whose JSON text is within the cap: TypeBox's symbol
 * keys drop out, and anything JSON cannot hold (a cycle, a BigInt, a throwing getter) leaves no
 * schema.
 */
function jsonSchema(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
  let text: string | undefined;
  try {
    text = JSON.stringify(value);
  } catch {
    return undefined;
  }
  if (text === undefined || Buffer.byteLength(text, "utf8") > MAX_SCHEMA_JSON) return undefined;
  const parsed: unknown = JSON.parse(text);
  return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
    ? (parsed as Record<string, unknown>)
    : undefined;
}

/** `value` without control characters other than newline and tab, at most `max` characters. */
function boundText(value: string, max: number): string {
  let cleaned = "";
  for (const character of value) {
    const code = character.charCodeAt(0);
    const control = code <= 0x1f || (code >= 0x7f && code <= 0x9f);
    cleaned += control && character !== "\n" && character !== "\t" ? " " : character;
    if (cleaned.length >= max) break;
  }
  return cleaned.slice(0, max);
}
