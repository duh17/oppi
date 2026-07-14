import { EventRing } from "./event-ring.js";
import type { CacheMissModelPriceSource, CacheMissTrackerState } from "./cache-miss.js";
import type { ExtensionUIState } from "./extension-ui-state.js";
import type { PendingStop } from "./session-stop.js";
import { TurnDedupeCache } from "./turn-cache.js";
import type { MessageQueueState, ServerMessage, Session } from "./types.js";

export interface RuntimeSessionStateScaffold<
  TQueue extends MessageQueueState = MessageQueueState,
> extends ExtensionUIState {
  session: Session;
  subscribers: Set<(msg: ServerMessage) => void>;
  seq: number;
  eventRing: EventRing;
  partialResults: Map<string, string>;
  streamedAssistantText: string;
  hasStreamedThinking: boolean;
  streamedThinkingContentIndexes: Set<number>;
  currentThinkingContentIndex?: number;
  pendingStop?: PendingStop;
  toolNames: Map<string, string>;
  toolArgs: Map<string, Record<string, unknown>>;
  shellPreviewLastSent: Map<string, number>;
  streamingToolUpdatesSeen: Map<string, string>;
  toolFullOutputPaths: Map<string, string>;
  messageQueue: TQueue;
  turnCache: TurnDedupeCache;
  pendingTurnStarts: string[];
  cacheMissTracker: CacheMissTrackerState;
  showCacheMissNotices: boolean;
  cacheMissModelPriceSource?: CacheMissModelPriceSource;
}

export function createEmptyRuntimeMessageQueue(): MessageQueueState {
  return {
    version: 0,
    steering: [],
    followUp: [],
  };
}

export function createRuntimeSessionStateScaffold<
  TQueue extends MessageQueueState = MessageQueueState,
>(
  session: Session,
  eventRingCapacity: number,
  messageQueue: TQueue = createEmptyRuntimeMessageQueue() as TQueue,
): RuntimeSessionStateScaffold<TQueue> {
  return {
    session,
    subscribers: new Set(),
    seq: 0,
    eventRing: new EventRing(eventRingCapacity),
    pendingUIRequests: new Map(),
    persistentExtensionUINotifications: new Map(),
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    streamedThinkingContentIndexes: new Set(),
    toolNames: new Map(),
    toolArgs: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map(),
    toolFullOutputPaths: new Map(),
    messageQueue,
    turnCache: new TurnDedupeCache(),
    pendingTurnStarts: [],
    cacheMissTracker: {},
    showCacheMissNotices: false,
  };
}
