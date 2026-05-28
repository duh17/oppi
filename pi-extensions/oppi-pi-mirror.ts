import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { WebSocket } from "ws";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { hostname } from "node:os";

interface OppiMirrorSettings {
  serverUrl?: string;
  token?: string;
  autoStart?: boolean;
}

interface QueueImageContent {
  data: string;
  mimeType: string;
}

interface MessageQueueDraftItem {
  id?: string;
  message: string;
  images?: QueueImageContent[];
  createdAt?: number;
}

interface MessageQueueItem {
  id: string;
  message: string;
  images?: QueueImageContent[];
  createdAt: number;
}

interface MessageQueueState {
  version: number;
  steering: MessageQueueItem[];
  followUp: MessageQueueItem[];
}

const EVENT_TYPES = [
  "agent_start",
  "agent_end",
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

function settingsPath(): string {
  return join(process.env.HOME || "", ".pi/agent/settings.json");
}

function oppiConfigPath(): string {
  if (process.env.OPPI_CONFIG_PATH) return process.env.OPPI_CONFIG_PATH;
  const dataDir =
    process.env.OPPI_DATA_DIR || join(process.env.HOME || "", ".config/oppi");
  return join(dataDir, "config.json");
}

function readJsonFile(path: string): Record<string, unknown> {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function readSettingsFile(): Record<string, unknown> {
  return readJsonFile(settingsPath());
}

function localHostForConfig(host: unknown): string {
  const value = typeof host === "string" ? host.trim() : "";
  if (!value || value === "0.0.0.0" || value === "::" || value === "[::]") {
    return "127.0.0.1";
  }
  return value;
}

function autoDiscoverOppiSettings(): Partial<OppiMirrorSettings> {
  const config = readJsonFile(oppiConfigPath()) as {
    host?: unknown;
    port?: unknown;
    tls?: { mode?: unknown };
    token?: unknown;
  };
  const token = typeof config.token === "string" ? config.token.trim() : "";
  const port =
    typeof config.port === "number" || typeof config.port === "string"
      ? String(config.port)
      : "";
  if (!token || !port) return {};

  const scheme = config.tls?.mode === "disabled" ? "http" : "https";
  const host = localHostForConfig(config.host);
  return { serverUrl: `${scheme}://${host}:${port}`, token };
}

function loadSettings(): OppiMirrorSettings {
  const parsed = readSettingsFile() as { oppiMirror?: OppiMirrorSettings };
  const fileSettings = parsed.oppiMirror ?? {};
  const discovered = autoDiscoverOppiSettings();
  const autoStartEnv = process.env.OPPI_MIRROR_AUTO_START?.toLowerCase();
  const envAutoStart =
    autoStartEnv === undefined
      ? undefined
      : autoStartEnv === "1" ||
        autoStartEnv === "true" ||
        autoStartEnv === "yes";

  return {
    serverUrl:
      process.env.OPPI_MIRROR_URL ||
      fileSettings.serverUrl ||
      discovered.serverUrl,
    token:
      process.env.OPPI_MIRROR_TOKEN || fileSettings.token || discovered.token,
    // Installing/enabling the extension is the opt-in. Mirror automatically unless explicitly disabled.
    autoStart: envAutoStart ?? fileSettings.autoStart !== false,
  };
}

function isLocalUrl(urlText: string): boolean {
  try {
    const host = new URL(urlText).hostname;
    return host === "localhost" || host === "127.0.0.1" || host === "::1";
  } catch {
    return false;
  }
}

function bridgeUrl(serverUrl: string): string {
  const url = new URL(serverUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = "/mirror/v1/bridge";
  url.search = "";
  return url.toString();
}

function modelWire(ctx: ExtensionContext) {
  const model = ctx.model;
  if (!model) return null;
  return { provider: model.provider, id: model.id };
}

function contextUsageWire(ctx: ExtensionContext) {
  const usage = ctx.getContextUsage();
  if (!usage) return null;
  return {
    tokens: usage.tokens,
    contextWindow: usage.contextWindow,
  };
}

function queueId(): string {
  return `mirror_q_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function cloneQueueItem(item: MessageQueueItem): MessageQueueItem {
  return {
    id: item.id,
    message: item.message,
    ...(item.images
      ? { images: item.images.map((image) => ({ ...image })) }
      : {}),
    createdAt: item.createdAt,
  };
}

function cloneQueueState(queue: MessageQueueState): MessageQueueState {
  return {
    version: queue.version,
    steering: queue.steering.map(cloneQueueItem),
    followUp: queue.followUp.map(cloneQueueItem),
  };
}

function draftToItem(item: MessageQueueDraftItem): MessageQueueItem {
  return {
    id: item.id?.trim() || queueId(),
    message: item.message,
    ...(item.images
      ? { images: item.images.map((image) => ({ ...image })) }
      : {}),
    createdAt: item.createdAt ?? Date.now(),
  };
}

function itemsFromTexts(
  texts: string[],
  previous: MessageQueueItem[],
): MessageQueueItem[] {
  const used = new Set<number>();
  return texts.map((message) => {
    const previousIndex = previous.findIndex(
      (item, index) => !used.has(index) && item.message === message,
    );
    if (previousIndex !== -1) {
      used.add(previousIndex);
      return cloneQueueItem(previous[previousIndex]!);
    }
    return draftToItem({ message });
  });
}

function textFromUserMessage(message: unknown): string | undefined {
  if (!message || typeof message !== "object") return undefined;
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return undefined;
  return content
    .map((block) => {
      if (!block || typeof block !== "object") return "";
      const item = block as { type?: unknown; text?: unknown };
      return item.type === "text" && typeof item.text === "string"
        ? item.text
        : "";
    })
    .join("")
    .trim();
}

function stateSnapshot(pi: ExtensionAPI, ctx: ExtensionContext) {
  return {
    cwd: ctx.cwd,
    sessionFile: ctx.sessionManager.getSessionFile(),
    piSessionId: ctx.sessionManager.getSessionId(),
    sessionName: ctx.sessionManager.getSessionName?.() ?? undefined,
    model: modelWire(ctx),
    thinkingLevel: pi.getThinkingLevel(),
    isIdle: ctx.isIdle(),
    contextUsage: contextUsageWire(ctx),
  };
}

function commandError(message: string, id: string, error: unknown) {
  return {
    type: "command_result",
    id,
    success: false,
    error: error instanceof Error ? error.message : String(error),
  };
}

export default function oppiPiMirror(pi: ExtensionAPI) {
  let latestCtx: ExtensionContext | null = null;
  let ws: WebSocket | null = null;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  let manualStop = false;
  let connectedSessionId: string | null = null;
  let connectedWorkspaceId: string | null = null;
  let queue: MessageQueueState = { version: 0, steering: [], followUp: [] };

  let settings = loadSettings();

  function notify(
    ctx: ExtensionContext | null,
    message: string,
    type: "info" | "warning" | "error" = "info",
  ) {
    ctx?.ui.notify(message, type);
    if (!ctx) console.log(`[oppi-mirror] ${message}`);
  }

  function send(payload: unknown) {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(payload));
    }
  }

  function sendQueueState() {
    send({ type: "queue_state", queue: cloneQueueState(queue) });
  }

  async function refreshQueueFromRuntime(
    ctx: ExtensionContext,
  ): Promise<MessageQueueState> {
    const api = ctx as unknown as {
      getMessageQueue?: () => Promise<MessageQueueState> | MessageQueueState;
      getSteeringMessages?: () => Promise<string[]> | string[];
      getFollowUpMessages?: () => Promise<string[]> | string[];
    };

    if (api.getMessageQueue) {
      queue = cloneQueueState(await api.getMessageQueue());
      return cloneQueueState(queue);
    }

    if (api.getSteeringMessages && api.getFollowUpMessages) {
      const [steering, followUp] = await Promise.all([
        api.getSteeringMessages(),
        api.getFollowUpMessages(),
      ]);
      queue = {
        version: queue.version + 1,
        steering: itemsFromTexts(steering, queue.steering),
        followUp: itemsFromTexts(followUp, queue.followUp),
      };
      return cloneQueueState(queue);
    }

    return cloneQueueState(queue);
  }

  function enqueueShadow(
    kind: "steer" | "followUp",
    message: string,
    images?: QueueImageContent[],
  ) {
    const item: MessageQueueItem = {
      id: queueId(),
      message,
      ...(images?.length
        ? { images: images.map((image) => ({ ...image })) }
        : {}),
      createdAt: Date.now(),
    };
    if (kind === "steer") queue.steering.push(item);
    else queue.followUp.push(item);
    queue.version += 1;
    sendQueueState();
  }

  function markQueueItemStarted(message: string | undefined) {
    const normalized = message?.trim();
    if (!normalized) return;
    const dequeue = (
      kind: "steer" | "follow_up",
      list: MessageQueueItem[],
    ): MessageQueueItem | null => {
      const index = list.findIndex(
        (item) => item.message.trim() === normalized,
      );
      if (index === -1) return null;
      const [item] = list.splice(index, 1);
      if (!item) return null;
      queue.version += 1;
      send({
        type: "queue_item_started",
        kind,
        item: cloneQueueItem(item),
        queueVersion: queue.version,
        queue: cloneQueueState(queue),
      });
      sendQueueState();
      return item;
    };
    if (dequeue("steer", queue.steering)) return;
    dequeue("follow_up", queue.followUp);
  }

  function clearTimers() {
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = null;
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }

  function startHeartbeat() {
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeatTimer = setInterval(() => {
      if (!latestCtx) return;
      send({
        type: "heartbeat",
        state: stateSnapshot(pi, latestCtx),
        queue: cloneQueueState(queue),
      });
    }, 10_000);
  }

  function configured(): { serverUrl: string; token: string } | null {
    if (!settings.serverUrl || !settings.token) return null;
    return { serverUrl: settings.serverUrl, token: settings.token };
  }

  function connect(ctx: ExtensionContext) {
    latestCtx = ctx;
    settings = loadSettings();
    const config = configured();
    if (!config) {
      notify(
        ctx,
        "Oppi Mirror could not auto-discover ~/.config/oppi/config.json. Start the Oppi server once, or set OPPI_MIRROR_URL/OPPI_MIRROR_TOKEN.",
        "warning",
      );
      return;
    }

    if (
      ws &&
      (ws.readyState === WebSocket.OPEN ||
        ws.readyState === WebSocket.CONNECTING)
    ) {
      notify(ctx, "Oppi Mirror is already running", "info");
      return;
    }

    manualStop = false;
    const url = bridgeUrl(config.serverUrl);
    ws = new WebSocket(url, {
      headers: { Authorization: `Bearer ${config.token}` },
      perMessageDeflate: false,
      // Auto-discovery reads the local Oppi config/token from the same user account.
      // Local self-signed HTTPS is expected; do not require manual cert pairing for this path.
      rejectUnauthorized: !isLocalUrl(config.serverUrl),
    });

    ws.on("open", () => {
      send({
        type: "hello",
        protocolVersion: 1,
        bridgeId: `pi-tui-${process.pid}`,
        pid: process.pid,
        hostname: hostname(),
        cwd: ctx.cwd,
        capabilities: [
          "prompt",
          "steer",
          "follow_up",
          "abort",
          "model",
          "thinking",
          "session_name",
          "compact",
          "state",
        ],
        state: stateSnapshot(pi, ctx),
      });
      sendQueueState();
      startHeartbeat();
      ctx.ui.setStatus("oppi-mirror", "Oppi Mirror connecting");
    });

    ws.on("message", (raw) => {
      void handleServerMessage(raw.toString());
    });

    ws.on("close", () => {
      ctx.ui.setStatus("oppi-mirror", undefined);
      clearTimers();
      if (!manualStop) {
        reconnectTimer = setTimeout(() => connect(ctx), 2_000);
      }
    });

    ws.on("error", (error) => {
      console.error("[oppi-mirror] websocket error", error);
    });
  }

  function stop(ctx: ExtensionContext | null, reason = "stopped") {
    manualStop = true;
    clearTimers();
    if (ws?.readyState === WebSocket.OPEN && latestCtx) {
      send({ type: "goodbye", reason, state: stateSnapshot(pi, latestCtx) });
    }
    ws?.close();
    ws = null;
    connectedSessionId = null;
    connectedWorkspaceId = null;
    ctx?.ui.setStatus("oppi-mirror", undefined);
    notify(ctx, "Oppi Mirror stopped");
  }

  async function handleServerMessage(raw: string) {
    const ctx = latestCtx;
    if (!ctx) return;

    const message = JSON.parse(raw) as {
      type?: string;
      id?: string;
      command?: Record<string, unknown>;
    };
    switch (message.type) {
      case "hello_ack":
        connectedSessionId =
          (message as { sessionId?: string }).sessionId ?? null;
        connectedWorkspaceId =
          (message as { workspaceId?: string }).workspaceId ?? null;
        ctx.ui.setStatus("oppi-mirror", "Oppi Mirror live");
        ctx.ui.notify("Oppi Mirror is live", "info");
        return;

      case "command":
        if (message.id && message.command) {
          await handleCommand(ctx, message.id, message.command);
        }
        return;

      case "error":
        ctx.ui.notify(
          `Oppi Mirror error: ${(message as { error?: string }).error ?? "unknown"}`,
          "error",
        );
        return;
    }
  }

  async function handleCommand(
    ctx: ExtensionContext,
    id: string,
    command: Record<string, unknown>,
  ) {
    try {
      const data = await runCommand(ctx, command);
      send({
        type: "command_result",
        id,
        success: true,
        data,
        state: stateSnapshot(pi, ctx),
      });
    } catch (error) {
      send(commandError("command_result", id, error));
    }
  }

  async function runCommand(
    ctx: ExtensionContext,
    command: Record<string, unknown>,
  ): Promise<unknown> {
    const type = command.type;
    switch (type) {
      case "prompt": {
        const message =
          typeof command.message === "string" ? command.message : "";
        const images = Array.isArray(command.images) ? command.images : [];
        const content = images.length
          ? [
              {
                type: "text" as const,
                text: message || "(see attached image)",
              },
              ...images.flatMap((image) => {
                const item = image as { data?: unknown; mimeType?: unknown };
                return typeof item.data === "string"
                  ? [
                      {
                        type: "image" as const,
                        data: item.data,
                        mimeType:
                          typeof item.mimeType === "string"
                            ? item.mimeType
                            : "image/png",
                      },
                    ]
                  : [];
              }),
            ]
          : message;
        const streamingBehavior = command.streamingBehavior;
        const queueImages = images.flatMap((image) => {
          const item = image as { data?: unknown; mimeType?: unknown };
          return typeof item.data === "string"
            ? [
                {
                  data: item.data,
                  mimeType:
                    typeof item.mimeType === "string"
                      ? item.mimeType
                      : "image/png",
                },
              ]
            : [];
        });
        if (streamingBehavior === "steer") {
          pi.sendUserMessage(content, { deliverAs: "steer" });
          enqueueShadow("steer", message, queueImages);
        } else if (streamingBehavior === "followUp") {
          pi.sendUserMessage(content, { deliverAs: "followUp" });
          enqueueShadow("followUp", message, queueImages);
        } else {
          pi.sendUserMessage(content);
        }
        return { dispatched: true, queue: cloneQueueState(queue) };
      }

      case "steer": {
        const message = String(command.message ?? "");
        pi.sendUserMessage(message, {
          deliverAs: "steer",
        });
        enqueueShadow("steer", message);
        return { dispatched: true, queue: cloneQueueState(queue) };
      }

      case "follow_up": {
        const message = String(command.message ?? "");
        pi.sendUserMessage(message, {
          deliverAs: "followUp",
        });
        enqueueShadow("followUp", message);
        return { dispatched: true, queue: cloneQueueState(queue) };
      }

      case "abort":
        ctx.abort();
        queue = { version: queue.version + 1, steering: [], followUp: [] };
        sendQueueState();
        return { aborted: true, queue: cloneQueueState(queue) };

      case "get_queue": {
        const latestQueue = await refreshQueueFromRuntime(ctx);
        sendQueueState();
        return { queue: latestQueue };
      }

      case "set_queue": {
        const api = ctx as unknown as {
          setMessageQueue?: (payload: {
            baseVersion: number;
            steering: MessageQueueDraftItem[];
            followUp: MessageQueueDraftItem[];
          }) => Promise<MessageQueueState | void> | MessageQueueState | void;
        };
        if (!api.setMessageQueue) {
          throw new Error(
            "Terminal Pi runtime does not expose queue editing yet",
          );
        }
        const steering = Array.isArray(command.steering)
          ? (command.steering as MessageQueueDraftItem[])
          : [];
        const followUp = Array.isArray(command.followUp)
          ? (command.followUp as MessageQueueDraftItem[])
          : [];
        const nextQueue = await api.setMessageQueue({
          baseVersion: Number(command.baseVersion),
          steering,
          followUp,
        });
        queue = nextQueue
          ? cloneQueueState(nextQueue)
          : {
              version: queue.version + 1,
              steering: steering.map(draftToItem),
              followUp: followUp.map(draftToItem),
            };
        sendQueueState();
        return { queue: cloneQueueState(queue) };
      }

      case "get_state":
        return stateSnapshot(pi, ctx);

      case "get_messages":
        return { entries: ctx.sessionManager.getEntries() };

      case "get_session_stats": {
        const entries = ctx.sessionManager.getEntries();
        return {
          sessionFile: ctx.sessionManager.getSessionFile(),
          piSessionId: ctx.sessionManager.getSessionId(),
          totalMessages: entries.length,
          contextUsage: contextUsageWire(ctx),
        };
      }

      case "get_commands":
        return { commands: pi.getCommands() };

      case "get_available_models":
        return { models: await ctx.modelRegistry.getAvailable() };

      case "set_model": {
        const provider = String(command.provider ?? "");
        const modelId = String(command.modelId ?? command.id ?? "");
        const models = await ctx.modelRegistry.getAvailable();
        const model = models.find(
          (candidate) =>
            candidate.provider === provider && candidate.id === modelId,
        );
        if (!model) throw new Error(`Model not found: ${provider}/${modelId}`);
        const ok = await pi.setModel(model);
        if (!ok) throw new Error("No API key for this model");
        return model;
      }

      case "cycle_model": {
        const models = await ctx.modelRegistry.getAvailable();
        if (!ctx.model || models.length === 0) return null;
        const index = models.findIndex(
          (candidate) =>
            candidate.provider === ctx.model?.provider &&
            candidate.id === ctx.model?.id,
        );
        const next = models[(index + 1 + models.length) % models.length];
        await pi.setModel(next);
        return { model: next };
      }

      case "set_thinking_level":
        pi.setThinkingLevel(
          String(command.level ?? "medium") as Parameters<
            typeof pi.setThinkingLevel
          >[0],
        );
        return { level: pi.getThinkingLevel() };

      case "cycle_thinking_level": {
        const levels = [
          "off",
          "minimal",
          "low",
          "medium",
          "high",
          "xhigh",
        ] as const;
        const current = pi.getThinkingLevel();
        const next =
          levels[
            (levels.indexOf(current as (typeof levels)[number]) + 1) %
              levels.length
          ];
        pi.setThinkingLevel(next);
        return { level: pi.getThinkingLevel() };
      }

      case "set_session_name": {
        const name = String(command.name ?? "").trim();
        if (!name) throw new Error("Session name cannot be empty");
        pi.setSessionName(name);
        return { name };
      }

      case "compact":
        ctx.compact({
          customInstructions:
            typeof command.customInstructions === "string"
              ? command.customInstructions
              : undefined,
        });
        return { compacting: true };

      case "set_auto_compaction":
        return { unsupported: true };

      default:
        throw new Error(`Unsupported Oppi Mirror command: ${String(type)}`);
    }
  }

  for (const eventType of EVENT_TYPES) {
    pi.on(eventType as never, (event: unknown, ctx: ExtensionContext) => {
      latestCtx = ctx;
      if (eventType === "message_start") {
        markQueueItemStarted(
          textFromUserMessage((event as { message?: unknown }).message),
        );
      }
      const includeState =
        eventType === "agent_start" ||
        eventType === "agent_end" ||
        eventType === "turn_start" ||
        eventType === "turn_end" ||
        eventType === "message_end";
      send({
        type: "event",
        event: { ...(event as object), type: eventType },
        ...(includeState ? { state: stateSnapshot(pi, ctx) } : {}),
      });
    });
  }

  pi.on("session_start", (_event, ctx) => {
    latestCtx = ctx;
    if (settings.autoStart) connect(ctx);
  });

  pi.on("session_shutdown", () => {
    stop(latestCtx, "session_shutdown");
  });

  pi.registerCommand("oppi-mirror", {
    description: "Mirror this live Pi TUI session into Oppi",
    handler: async (args, ctx) => {
      const [subcommand] = args.trim().split(/\s+/).filter(Boolean);
      switch (subcommand || "status") {
        case "start":
          connect(ctx);
          return;
        case "stop":
          stop(ctx);
          return;
        case "status":
          ctx.ui.notify(
            ws?.readyState === WebSocket.OPEN
              ? `Oppi Mirror live: workspace=${connectedWorkspaceId ?? "?"} session=${connectedSessionId ?? "?"}`
              : "Oppi Mirror is not connected",
            ws?.readyState === WebSocket.OPEN ? "info" : "warning",
          );
          return;
        default:
          ctx.ui.notify("Usage: /oppi-mirror start|stop|status", "warning");
      }
    },
  });
}
