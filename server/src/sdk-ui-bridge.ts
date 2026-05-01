import { randomUUID } from "node:crypto";

import type { ExtensionUIDialogOptions, ExtensionUIContext } from "@mariozechner/pi-coding-agent";

import { safeErrorMessage } from "./log-utils.js";
import type {
  ExtensionAudioStreamEvent,
  ExtensionUIRequestEvent,
  SessionBackendEvent,
} from "./pi-events.js";
import type { AskQuestion } from "./types.js";

type ExtensionAudioStreamInput = Omit<ExtensionAudioStreamEvent, "type">;

type OppiExtensionUIContext = ExtensionUIContext & {
  audioStream: (event: ExtensionAudioStreamInput) => void;
};

export interface ExtensionUIResponsePayload {
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

interface PendingExtensionUIResponse {
  resolve: (response: ExtensionUIResponsePayload) => void;
  cancel: () => void;
}

interface AskUIResult {
  answers: Record<string, string | string[]>;
  allIgnored: boolean;
}

interface CustomUIComponent {
  render: (width: number) => string[];
  handleInput?: (data: string) => void;
  invalidate?: () => void;
  dispose?: () => void;
}

type CustomUIControl = "up" | "down" | "enter" | "type" | "cancel";

const MAX_EXTENSION_AUDIO_CHUNK_BASE64_BYTES = 512 * 1024;
const MAX_EXTENSION_AUDIO_TEXT_CHARS = 2_000;
const EXTENSION_AUDIO_MIME_TYPES = new Set<ExtensionAudioStreamEvent["mimeType"]>([
  "audio/wav",
  "audio/pcm; codecs=s16le",
]);
const CUSTOM_UI_COMPAT_TITLE = "Extension (TUI compatibility mode)";
const CUSTOM_UI_COMPAT_WIDTH = 88;
const CUSTOM_UI_COMPAT_MAX_LINES = 28;
const CUSTOM_UI_COMPAT_MAX_MESSAGE_CHARS = 6_000;
const CUSTOM_UI_COMPAT_MAX_STEPS = 200;
const CUSTOM_UI_COMPAT_TIMEOUT_MS = 5 * 60_000;
const CUSTOM_UI_COMPAT_WIDGET_MAX_LINES = 8;
const CUSTOM_UI_COMPAT_TYPE_PROMPT = "Type text for extension UI";
const CUSTOM_UI_COMPAT_CONTROL_OPTIONS = [
  "↑ Up",
  "↓ Down",
  "⏎ Enter",
  "Type text…",
  "Cancel",
] as const;

const CUSTOM_UI_COMPAT_CONTROL_INPUT: Record<
  Exclude<CustomUIControl, "type" | "cancel">,
  string
> = {
  up: "__OPPI_TUI_UP__",
  down: "__OPPI_TUI_DOWN__",
  enter: "__OPPI_TUI_ENTER__",
};

function validateExtensionAudioStreamEvent(
  event: ExtensionAudioStreamInput,
): ExtensionAudioStreamInput {
  if (event.kind !== "audio-stream") {
    throw new Error("audioStream kind must be audio-stream");
  }
  if (!event.id || event.id.length > 128) {
    throw new Error("audioStream id must be 1-128 characters");
  }
  if (!["metadata", "chunk", "done", "error"].includes(event.event)) {
    throw new Error("audioStream event must be metadata, chunk, done, or error");
  }
  if (!EXTENSION_AUDIO_MIME_TYPES.has(event.mimeType)) {
    throw new Error(`Unsupported audioStream MIME type: ${event.mimeType}`);
  }
  if (
    event.sampleRate !== undefined &&
    (!Number.isInteger(event.sampleRate) || event.sampleRate < 8_000 || event.sampleRate > 48_000)
  ) {
    throw new Error("audioStream sampleRate must be an integer between 8000 and 48000 Hz");
  }
  if (event.channels !== undefined && event.channels !== 1 && event.channels !== 2) {
    throw new Error("audioStream channels must be 1 or 2");
  }
  if (
    event.chunkIndex !== undefined &&
    (!Number.isInteger(event.chunkIndex) || event.chunkIndex < 0)
  ) {
    throw new Error("audioStream chunkIndex must be a non-negative integer");
  }
  if (
    event.durationSeconds !== undefined &&
    (!Number.isFinite(event.durationSeconds) || event.durationSeconds < 0)
  ) {
    throw new Error("audioStream durationSeconds must be a finite non-negative number");
  }
  if (event.audioBase64 !== undefined) {
    if (Buffer.byteLength(event.audioBase64, "utf8") > MAX_EXTENSION_AUDIO_CHUNK_BASE64_BYTES) {
      throw new Error("audioStream chunk exceeds 512KB base64 limit");
    }
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(event.audioBase64) || event.audioBase64.length % 4 !== 0) {
      throw new Error("audioStream audioBase64 must be valid base64");
    }
  }
  if (event.text !== undefined && event.text.length > MAX_EXTENSION_AUDIO_TEXT_CHARS) {
    throw new Error("audioStream text exceeds 2000 character limit");
  }
  return event;
}

function invalidAskResponse(message: string): Error {
  return new Error(`Malformed ask response: ${message}`);
}

function normalizeAskAnswers(value: string): Record<string, string | string[]> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch (error) {
    throw invalidAskResponse(error instanceof Error ? error.message : String(error));
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw invalidAskResponse("expected a JSON object");
  }

  const answers: Record<string, string | string[]> = {};
  for (const [key, answer] of Object.entries(parsed)) {
    if (typeof answer === "string") {
      answers[key] = answer;
      continue;
    }

    if (Array.isArray(answer) && answer.every((item) => typeof item === "string")) {
      answers[key] = answer;
      continue;
    }

    throw invalidAskResponse(`expected string or string[] for "${key}"`);
  }

  return answers;
}

function decodeCustomUIControlOption(option: string | undefined): CustomUIControl | undefined {
  switch (option) {
    case "↑ Up":
      return "up";
    case "↓ Down":
      return "down";
    case "⏎ Enter":
      return "enter";
    case "Type text…":
      return "type";
    case "Cancel":
      return "cancel";
    default:
      return undefined;
  }
}

function stripAnsiCodes(input: string): string {
  let output = "";
  let skippingAnsi = false;

  for (let i = 0; i < input.length; i++) {
    const char = input[i];

    if (!skippingAnsi && char === "\u001b" && input[i + 1] === "[") {
      skippingAnsi = true;
      i += 1;
      continue;
    }

    if (skippingAnsi) {
      if (char === "m") {
        skippingAnsi = false;
      }
      continue;
    }

    output += char;
  }

  return output;
}

function renderCustomUIMessage(component: CustomUIComponent): string {
  let lines: string[];

  try {
    lines = component.render(CUSTOM_UI_COMPAT_WIDTH);
  } catch (error) {
    const reason = safeErrorMessage(error);
    lines = [`[render error] ${reason}`];
  }

  const safeLines = lines.map((line) => stripAnsiCodes(line));
  const limited = safeLines.slice(0, CUSTOM_UI_COMPAT_MAX_LINES);
  if (safeLines.length > CUSTOM_UI_COMPAT_MAX_LINES) {
    limited.push(`… (${safeLines.length - CUSTOM_UI_COMPAT_MAX_LINES} more lines)`);
  }

  const intro = [
    "This extension requested a keyboard-driven TUI component.",
    "Use the controls below to navigate and submit.",
    "",
  ];

  const combined = [...intro, ...limited].join("\n");
  if (combined.length <= CUSTOM_UI_COMPAT_MAX_MESSAGE_CHARS) {
    return combined;
  }

  return `${combined.slice(0, CUSTOM_UI_COMPAT_MAX_MESSAGE_CHARS)}\n…`;
}

function renderWidgetSnapshotLines(component: CustomUIComponent): string[] {
  let lines: string[];

  try {
    lines = component.render(CUSTOM_UI_COMPAT_WIDTH);
  } catch (error) {
    lines = [`[render error] ${safeErrorMessage(error)}`];
  }

  const safeLines = lines
    .map((line) => stripAnsiCodes(line).trimEnd())
    .filter((line) => line.length > 0);

  const limited = safeLines.slice(0, CUSTOM_UI_COMPAT_WIDGET_MAX_LINES);
  if (safeLines.length > CUSTOM_UI_COMPAT_WIDGET_MAX_LINES) {
    limited.push(`… (${safeLines.length - CUSTOM_UI_COMPAT_WIDGET_MAX_LINES} more lines)`);
  }

  return limited;
}

function createCustomUICompatTheme(): ExtensionUIContext["theme"] {
  const passthrough = (value: string): string => value;

  return {
    fg: (_color: unknown, text: string): string => text,
    bg: (_color: unknown, text: string): string => text,
    bold: passthrough,
    dim: passthrough,
    italic: passthrough,
    underline: passthrough,
    inverse: passthrough,
    gray: (_level: unknown, text: string): string => text,
    hex: (_hex: unknown, text: string): string => text,
    rgb: (_r: unknown, _g: unknown, _b: unknown, text: string): string => text,
    parseInline: passthrough,
  } as unknown as ExtensionUIContext["theme"];
}

function createCustomUICompatKeybindings(): {
  matches: (data: string, keybinding: string) => boolean;
} {
  return {
    matches: (data: string, keybinding: string) => {
      switch (keybinding) {
        case "tui.select.up":
          return data === CUSTOM_UI_COMPAT_CONTROL_INPUT.up;
        case "tui.select.down":
          return data === CUSTOM_UI_COMPAT_CONTROL_INPUT.down;
        case "tui.select.confirm":
          return data === CUSTOM_UI_COMPAT_CONTROL_INPUT.enter;
        case "tui.select.cancel":
          return data === "\u001b";
        default:
          return false;
      }
    },
  };
}

export class SdkUiBridge {
  private readonly pendingResponses = new Map<string, PendingExtensionUIResponse>();

  constructor(
    private readonly emitEvent: (event: SessionBackendEvent) => void,
    private readonly isDisposed: () => boolean,
  ) {}

  createContext(): ExtensionUIContext {
    let editorComponentFactory: ReturnType<ExtensionUIContext["getEditorComponent"]>;

    const context = {
      ask: (questions: AskQuestion[], allowCustom = true, opts?: ExtensionUIDialogOptions) => {
        if (!Array.isArray(questions) || questions.length === 0) {
          return Promise.reject(new Error("ask UI requires at least one question"));
        }

        return this.createDialogPromise<AskUIResult>(
          opts,
          { answers: {}, allIgnored: true },
          { method: "ask", questions, allowCustom },
          (response) => {
            if (response.cancelled || !response.value) {
              return { answers: {}, allIgnored: true };
            }

            const answers = normalizeAskAnswers(response.value);
            return {
              answers,
              allIgnored: Object.keys(answers).length === 0,
            };
          },
        );
      },

      select: (title, options, opts) =>
        this.createDialogPromise(
          opts,
          undefined,
          { method: "select", title, options },
          (response) => (response.cancelled ? undefined : response.value),
        ),

      confirm: (title, message, opts) =>
        this.createDialogPromise(opts, false, { method: "confirm", title, message }, (response) =>
          response.cancelled ? false : (response.confirmed ?? false),
        ),

      input: (title, placeholder, opts) =>
        this.createDialogPromise(
          opts,
          undefined,
          { method: "input", title, placeholder },
          (response) => (response.cancelled ? undefined : response.value),
        ),

      notify: (message, type) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "notify",
          message,
          notifyType: type,
        });
      },

      onTerminalInput: () => () => {
        // Raw terminal input is not supported in Oppi server sessions.
      },

      setStatus: (key, text) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setStatus",
          statusKey: key,
          statusText: text,
        });
      },

      setWorkingMessage: (_message) => {
        // Working message requires TUI access; unsupported in Oppi sessions.
      },

      setWorkingIndicator: (_options) => {
        // Working indicator customization requires TUI access; unsupported in Oppi sessions.
      },

      setWorkingVisible: (_visible) => {
        // Working row visibility requires TUI access; unsupported in Oppi sessions.
      },

      setWidget: (key, content, options) => {
        if (content === undefined || Array.isArray(content)) {
          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "setWidget",
            widgetKey: key,
            widgetLines: content,
            widgetPlacement: options?.placement,
          });
          return;
        }

        try {
          const component = content(
            { requestRender: () => {} } as never,
            createCustomUICompatTheme() as never,
          ) as CustomUIComponent;
          const lines = renderWidgetSnapshotLines(component);
          component.dispose?.();

          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "setWidget",
            widgetKey: key,
            widgetLines: lines,
            widgetPlacement: options?.placement,
          });
        } catch (error) {
          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "notify",
            notifyType: "warning",
            message: `Failed to render extension widget: ${safeErrorMessage(error)}`,
          });
        }
      },

      setFooter: (_factory) => {
        // Custom footer requires TUI access; unsupported in Oppi sessions.
      },

      setHeader: (_factory) => {
        // Custom header requires TUI access; unsupported in Oppi sessions.
      },

      setTitle: (title) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setTitle",
          title,
        });
      },

      custom: async <T>(
        factory: (
          tui: unknown,
          theme: ExtensionUIContext["theme"],
          keybindings: unknown,
          done: (result: T) => void,
        ) => CustomUIComponent | Promise<CustomUIComponent>,
      ) => {
        try {
          return await this.runCustomUICompatibility<T>(factory);
        } catch (error) {
          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "notify",
            notifyType: "warning",
            message: `Extension custom UI failed: ${safeErrorMessage(error)}`,
          });
          throw error;
        }
      },

      pasteToEditor: (text) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "set_editor_text",
          text,
        });
      },

      setEditorText: (text) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "set_editor_text",
          text,
        });
      },

      getEditorText: () => {
        return "";
      },

      editor: (title, prefill) =>
        this.createDialogPromise(
          undefined,
          undefined,
          { method: "editor", title, prefill },
          (response) => (response.cancelled ? undefined : response.value),
        ),

      addAutocompleteProvider: (_factory) => {
        // Autocomplete provider stacking requires TUI access; unsupported in Oppi sessions.
      },

      setEditorComponent: (factory) => {
        // Oppi does not render custom TUI editors, but preserving the factory
        // lets extensions wrap/restore editor state without crashing.
        editorComponentFactory = factory;
      },

      getEditorComponent: () => editorComponentFactory,

      get theme() {
        return {} as ExtensionUIContext["theme"];
      },

      getAllThemes: () => [],

      getTheme: (_name) => undefined,

      setTheme: (_theme) => ({
        success: false,
        error: "Theme switching not supported in Oppi sessions",
      }),

      getToolsExpanded: () => false,

      setToolsExpanded: (_expanded) => {
        // Tool expansion requires TUI access; unsupported in Oppi sessions.
      },

      setHiddenThinkingLabel: (_label) => {
        // Thinking label customization requires TUI; unsupported in Oppi sessions.
      },
    } as ExtensionUIContext;

    const oppiContext = context as OppiExtensionUIContext;
    oppiContext.audioStream = (event) => {
      this.emitEvent({
        type: "extension_audio_stream",
        ...validateExtensionAudioStreamEvent(event),
      });
    };
    return oppiContext;
  }

  respond(response: ExtensionUIResponsePayload): boolean {
    const pending = this.pendingResponses.get(response.id);
    if (!pending) {
      return false;
    }

    pending.resolve(response);
    return true;
  }

  dispose(): void {
    for (const pending of this.pendingResponses.values()) {
      pending.cancel();
    }
    this.pendingResponses.clear();
  }

  private emitExtensionUIRequest(request: Omit<ExtensionUIRequestEvent, "type">): void {
    this.emitEvent({
      type: "extension_ui_request",
      ...request,
    });
  }

  private createDialogPromise<T>(
    opts: ExtensionUIDialogOptions | undefined,
    defaultValue: T,
    request: Omit<ExtensionUIRequestEvent, "type" | "id">,
    parseResponse: (response: ExtensionUIResponsePayload) => T,
  ): Promise<T> {
    if (this.isDisposed() || opts?.signal?.aborted) {
      return Promise.resolve(defaultValue);
    }

    const id = randomUUID();

    return new Promise<T>((resolve, reject) => {
      let timeoutId: NodeJS.Timeout | undefined;

      const cleanup = (): void => {
        if (timeoutId) {
          clearTimeout(timeoutId);
        }
        opts?.signal?.removeEventListener("abort", onAbort);
        this.pendingResponses.delete(id);
        this.emitEvent({ type: "extension_ui_request_settled", id });
      };

      const cancel = (): void => {
        cleanup();
        resolve(defaultValue);
      };

      const onAbort = (): void => {
        cancel();
      };

      opts?.signal?.addEventListener("abort", onAbort, { once: true });

      if (opts?.timeout) {
        timeoutId = setTimeout(() => {
          cancel();
        }, opts.timeout);
      }

      this.pendingResponses.set(id, {
        resolve: (response) => {
          cleanup();
          try {
            resolve(parseResponse(response));
          } catch (error) {
            reject(error);
          }
        },
        cancel,
      });

      this.emitExtensionUIRequest({
        id,
        ...request,
        timeout: opts?.timeout,
        timeoutAt: opts?.timeout ? Date.now() + opts.timeout : undefined,
      });
    });
  }

  private async runCustomUICompatibility<T>(
    factory: (
      tui: unknown,
      theme: ExtensionUIContext["theme"],
      keybindings: unknown,
      done: (result: T) => void,
    ) => CustomUIComponent | Promise<CustomUIComponent>,
  ): Promise<T> {
    if (this.isDisposed()) {
      return undefined as T;
    }

    let resolved = false;
    let resolvedValue: T | undefined;

    const done = (value: T): void => {
      resolved = true;
      resolvedValue = value;
    };

    const tui = {
      requestRender: () => {
        // Render is polled after each control action.
      },
    };

    const theme = createCustomUICompatTheme();
    const keybindings = createCustomUICompatKeybindings();

    const component = await factory(tui, theme, keybindings, done);

    try {
      for (let step = 0; step < CUSTOM_UI_COMPAT_MAX_STEPS; step++) {
        if (resolved) {
          return resolvedValue as T;
        }

        if (this.isDisposed()) {
          return undefined as T;
        }

        const control = await this.createDialogPromise<CustomUIControl | undefined>(
          { timeout: CUSTOM_UI_COMPAT_TIMEOUT_MS },
          undefined,
          {
            method: "select",
            title: CUSTOM_UI_COMPAT_TITLE,
            message: renderCustomUIMessage(component),
            options: [...CUSTOM_UI_COMPAT_CONTROL_OPTIONS],
          },
          (response) => {
            if (response.cancelled) {
              return undefined;
            }
            return decodeCustomUIControlOption(response.value);
          },
        );

        if (!control || control === "cancel") {
          return undefined as T;
        }

        if (control === "type") {
          const typed = await this.createDialogPromise<string | undefined>(
            { timeout: CUSTOM_UI_COMPAT_TIMEOUT_MS },
            undefined,
            {
              method: "input",
              title: CUSTOM_UI_COMPAT_TYPE_PROMPT,
              placeholder: "type and submit",
            },
            (response) => (response.cancelled ? undefined : response.value),
          );

          if (typed) {
            for (const char of typed) {
              component.handleInput?.(char);
              if (resolved) {
                return resolvedValue as T;
              }
            }
          }

          continue;
        }

        component.handleInput?.(CUSTOM_UI_COMPAT_CONTROL_INPUT[control]);
      }

      this.emitExtensionUIRequest({
        id: randomUUID(),
        method: "notify",
        notifyType: "warning",
        message:
          "TUI compatibility mode hit the interaction limit before completion. Try again with a more direct extension command.",
      });

      return undefined as T;
    } finally {
      component.dispose?.();
    }
  }
}
