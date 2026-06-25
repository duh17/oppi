import { randomUUID } from "node:crypto";

import type {
  ExtensionUIDialogOptions,
  ExtensionUIContext,
  WorkingIndicatorOptions,
} from "@earendil-works/pi-coding-agent";

import { safeErrorMessage } from "./log-utils.js";
import type {
  ExtensionAudioStreamEvent,
  ExtensionUIRequestEvent,
  SessionBackendEvent,
} from "./pi-events.js";
import {
  createExtensionUINativeRenderContext,
  EXTENSION_UI_HIGH_FREQUENCY_UPDATE_THROTTLE_MS,
  normalizeExtensionUIWidgetNativeSurface,
  parseExtensionUIAskResponse,
  parseExtensionUIConfirmResponse,
  parseExtensionUISelectResponse,
  parseExtensionUITextResponse,
  type ExtensionUIAskResult,
  type ExtensionUINativeRenderableComponent,
  type ExtensionUIResponsePayload,
} from "./extension-ui-contract.js";
import { terminalLineVisibleText } from "./ansi.js";
import type { AskQuestion, ExtensionUINativeSurface, ExtensionUIWidgetPlacement } from "./types.js";

type ExtensionAudioStreamInput = Omit<ExtensionAudioStreamEvent, "type">;

type OppiExtensionUIContext = ExtensionUIContext & {
  audioStream: (event: ExtensionAudioStreamInput) => void;
};

interface PendingExtensionUIResponse {
  resolve: (response: ExtensionUIResponsePayload) => void;
  cancel: () => void;
}

interface ExtensionUISourceScope {
  extensionScopeId?: string;
  extensionDisplayName?: string;
}

interface ActiveWidgetComponent extends ExtensionUISourceScope {
  component: ExtensionUINativeRenderableComponent;
  placement?: ExtensionUIWidgetPlacement;
}

// Snapshot callbacks are not attached to a real terminal, but Pi extension authors
// commonly read this public TUI subset while producing render output.
interface CustomUISnapshotTui {
  requestRender: () => void;
  terminal: {
    columns: number;
    rows: number;
    kittyProtocolActive: boolean;
    write(data: string): void;
    setTitle(title: string): void;
    setProgress(active: boolean): void;
  };
}

const MAX_EXTENSION_AUDIO_CHUNK_BASE64_BYTES = 512 * 1024;
const MAX_EXTENSION_AUDIO_TEXT_CHARS = 2_000;
const EXTENSION_AUDIO_MIME_TYPES = new Set<ExtensionAudioStreamEvent["mimeType"]>([
  "audio/wav",
  "audio/pcm; codecs=s16le",
]);
const CUSTOM_UI_SNAPSHOT_WIDTH = 88;
const CUSTOM_UI_SNAPSHOT_ROWS = 40;
const CUSTOM_UI_SNAPSHOT_WIDGET_MAX_LINES = 8;

function titleCaseIdentifier(value: string): string {
  return value
    .replace(/^@[^/]+\//, "")
    .replace(/^pi[-_]/, "")
    .split(/[\s._/-]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function extensionScopeFromPath(rawPath: string): ExtensionUISourceScope | undefined {
  const decodedPath = decodeURIComponent(rawPath.replace(/^file:\/\//, ""));
  const nodeModulesMarker = "/node_modules/";
  const nodeModulesIndex = decodedPath.lastIndexOf(nodeModulesMarker);
  if (nodeModulesIndex >= 0) {
    const rest = decodedPath.slice(nodeModulesIndex + nodeModulesMarker.length);
    const parts = rest.split("/").filter(Boolean);
    const packageName = parts[0]?.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
    if (packageName) {
      return {
        extensionScopeId: `npm:${packageName}`,
        extensionDisplayName: titleCaseIdentifier(packageName),
      };
    }
  }

  const repoExtensionMarker = "/pi-extensions/";
  const repoExtensionIndex = decodedPath.indexOf(repoExtensionMarker);
  if (repoExtensionIndex >= 0) {
    const rest = decodedPath.slice(repoExtensionIndex + repoExtensionMarker.length);
    const directoryName = rest.split("/").filter(Boolean)[0];
    if (directoryName) {
      return {
        extensionScopeId: `repo:${directoryName}`,
        extensionDisplayName: titleCaseIdentifier(directoryName),
      };
    }
  }

  return undefined;
}

function detectExtensionUISourceScope(): ExtensionUISourceScope {
  const stack = new Error().stack ?? "";
  for (const line of stack.split("\n").slice(1)) {
    if (
      line.includes("sdk-ui-bridge") ||
      line.includes("node:internal") ||
      line.includes("internal/process")
    ) {
      continue;
    }

    const match = line.match(/(?:\(|\s)((?:file:\/\/)?\/[^():]+?)(?::\d+:\d+)?\)?$/);
    if (!match) {
      continue;
    }

    const scope = extensionScopeFromPath(match[1]);
    if (scope) {
      return scope;
    }
  }
  return {};
}

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

function renderWidgetSnapshotLines(component: ExtensionUINativeRenderableComponent): string[] {
  let lines: string[];

  try {
    lines = component.render(CUSTOM_UI_SNAPSHOT_WIDTH);
  } catch (error) {
    lines = [`[render error] ${safeErrorMessage(error)}`];
  }

  const safeLines = lines
    .map((line) => terminalLineVisibleText(line).trimEnd())
    .filter((line) => line.length > 0);

  const limited = safeLines.slice(0, CUSTOM_UI_SNAPSHOT_WIDGET_MAX_LINES);
  if (safeLines.length > CUSTOM_UI_SNAPSHOT_WIDGET_MAX_LINES) {
    limited.push(`… (${safeLines.length - CUSTOM_UI_SNAPSHOT_WIDGET_MAX_LINES} more lines)`);
  }

  return limited;
}

function renderWidgetNativeSurface(
  component: ExtensionUINativeRenderableComponent,
  widgetKey: string,
): ExtensionUINativeSurface | undefined {
  if (!component.renderNative) return undefined;

  try {
    return normalizeExtensionUIWidgetNativeSurface(
      component.renderNative(createExtensionUINativeRenderContext()),
      widgetKey,
    );
  } catch {
    return undefined;
  }
}

function createCustomUISnapshotTui(requestRender: () => void): CustomUISnapshotTui {
  return {
    requestRender,
    terminal: {
      columns: CUSTOM_UI_SNAPSHOT_WIDTH,
      rows: CUSTOM_UI_SNAPSHOT_ROWS,
      kittyProtocolActive: false,
      write: () => {},
      setTitle: () => {},
      setProgress: () => {},
    },
  };
}

function createCustomUISnapshotTheme(): ExtensionUIContext["theme"] {
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

export class SdkUiBridge {
  private readonly pendingResponses = new Map<string, PendingExtensionUIResponse>();
  // Match Pi TUI: widget keys are a global namespace. Scope metadata only helps
  // Oppi group status/widget surfaces for display; it does not create ownership.
  private readonly activeWidgets = new Map<string, ActiveWidgetComponent>();
  private readonly pendingWidgetRenderTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private readonly pendingWidgetRenderMicrotasks = new Set<string>();
  private readonly widgetSnapshotEmittedAt = new Map<string, number>();
  private toolsExpanded = false;

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

        return this.createDialogPromise<ExtensionUIAskResult>(
          opts,
          { answers: {}, allIgnored: true },
          { method: "ask", questions, allowCustom },
          parseExtensionUIAskResponse,
        );
      },

      select: (title, options, opts) =>
        this.createDialogPromise(
          opts,
          undefined,
          { method: "select", title, options },
          parseExtensionUISelectResponse,
        ),

      confirm: (title, message, opts) =>
        this.createDialogPromise(
          opts,
          false,
          { method: "confirm", title, message },
          parseExtensionUIConfirmResponse,
        ),

      input: (title, placeholder, opts) =>
        this.createDialogPromise(
          opts,
          undefined,
          { method: "input", title, placeholder },
          parseExtensionUITextResponse,
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

      setWorkingMessage: (message) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setWorkingMessage",
          message,
        });
      },

      setWorkingIndicator: (options?: WorkingIndicatorOptions) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setWorkingIndicator",
          workingIndicator: options,
        });
      },

      setWorkingVisible: (visible) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setWorkingVisible",
          workingVisible: visible,
        });
      },

      setWidget: (key, content, options) => {
        this.disposeWidget(key);
        const sourceScope = detectExtensionUISourceScope();

        if (content === undefined || Array.isArray(content)) {
          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "setWidget",
            widgetKey: key,
            widgetLines: content,
            widgetPlacement: options?.placement,
            ...sourceScope,
          });
          return;
        }

        try {
          const component = content(
            createCustomUISnapshotTui(() => this.scheduleWidgetSnapshot(key)) as never,
            createCustomUISnapshotTheme() as never,
          ) as ExtensionUINativeRenderableComponent;
          this.activeWidgets.set(key, { component, placement: options?.placement, ...sourceScope });
          this.emitWidgetSnapshot(key);
        } catch (error) {
          this.disposeWidget(key);
          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "setWidget",
            widgetKey: key,
            widgetLines: undefined,
            widgetPlacement: options?.placement,
            ...sourceScope,
          });
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
        _factory: (
          tui: unknown,
          theme: ExtensionUIContext["theme"],
          keybindings: unknown,
          done: (result: T) => void,
        ) => ExtensionUINativeRenderableComponent | Promise<ExtensionUINativeRenderableComponent>,
      ) => {
        // Oppi follows Pi's standard RPC/SDK UI contract on mobile. Arbitrary
        // keyboard-driven TUI components are terminal-only, so ctx.ui.custom()
        // resolves undefined without invoking the factory. Extensions that need
        // mobile support should use select/confirm/input/editor/widgets instead.
        return undefined as T;
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
          parseExtensionUITextResponse,
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
        return createCustomUISnapshotTheme();
      },

      getAllThemes: () => [],

      getTheme: (_name) => undefined,

      setTheme: (_theme) => ({
        success: false,
        error: "Theme switching not supported in Oppi sessions",
      }),

      getToolsExpanded: () => this.toolsExpanded,

      setToolsExpanded: (expanded) => {
        this.toolsExpanded = expanded;
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setToolsExpanded",
          toolsExpanded: expanded,
        });
      },

      setHiddenThinkingLabel: (label) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setHiddenThinkingLabel",
          hiddenThinkingLabel: label,
        });
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
    for (const key of this.activeWidgets.keys()) {
      this.disposeWidget(key);
    }
    this.clearPendingWidgetSnapshots();
  }

  private disposeWidget(key: string): void {
    this.clearPendingWidgetSnapshot(key);
    this.widgetSnapshotEmittedAt.delete(key);
    const active = this.activeWidgets.get(key);
    this.activeWidgets.delete(key);
    active?.component.dispose?.();
  }

  private scheduleWidgetSnapshot(key: string): void {
    if (this.isDisposed() || this.hasPendingWidgetSnapshot(key)) {
      return;
    }

    const emittedAt = this.widgetSnapshotEmittedAt.get(key);
    const now = Date.now();
    const delayMs =
      emittedAt === undefined
        ? 0
        : Math.max(0, EXTENSION_UI_HIGH_FREQUENCY_UPDATE_THROTTLE_MS - (now - emittedAt));

    if (delayMs <= 0) {
      this.pendingWidgetRenderMicrotasks.add(key);
      queueMicrotask(() => {
        this.pendingWidgetRenderMicrotasks.delete(key);
        this.emitWidgetSnapshot(key);
      });
      return;
    }

    const timer = setTimeout(() => {
      this.pendingWidgetRenderTimers.delete(key);
      this.emitWidgetSnapshot(key);
    }, delayMs);
    this.pendingWidgetRenderTimers.set(key, timer);
  }

  private hasPendingWidgetSnapshot(key: string): boolean {
    return this.pendingWidgetRenderMicrotasks.has(key) || this.pendingWidgetRenderTimers.has(key);
  }

  private clearPendingWidgetSnapshot(key: string): void {
    this.pendingWidgetRenderMicrotasks.delete(key);
    const timer = this.pendingWidgetRenderTimers.get(key);
    if (timer) {
      clearTimeout(timer);
      this.pendingWidgetRenderTimers.delete(key);
    }
  }

  private clearPendingWidgetSnapshots(): void {
    this.pendingWidgetRenderMicrotasks.clear();
    for (const timer of this.pendingWidgetRenderTimers.values()) {
      clearTimeout(timer);
    }
    this.pendingWidgetRenderTimers.clear();
  }

  private emitWidgetSnapshot(key: string): void {
    if (this.isDisposed()) {
      return;
    }

    const active = this.activeWidgets.get(key);
    if (!active) {
      return;
    }

    const nativeSurface = renderWidgetNativeSurface(active.component, key);

    this.emitExtensionUIRequest({
      id: randomUUID(),
      method: "setWidget",
      widgetKey: key,
      widgetLines: renderWidgetSnapshotLines(active.component),
      widgetPlacement: active.placement,
      nativeSurface,
      extensionScopeId: active.extensionScopeId,
      extensionDisplayName: active.extensionDisplayName,
    });
    this.widgetSnapshotEmittedAt.set(key, Date.now());
  }

  private emitExtensionUIRequest(request: Omit<ExtensionUIRequestEvent, "type">): void {
    const sourceScope = request.extensionScopeId ? {} : detectExtensionUISourceScope();
    this.emitEvent({
      type: "extension_ui_request",
      ...sourceScope,
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
}
