import { createLogger } from "../logger.js";
import { SpeechError, startSpeech } from "../speech-synthesis.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const log = createLogger({ base: { component: "speech" } });

/**
 * `POST /speech` `{ "text": "<markdown>" }` reads a message aloud with the
 * configured `tts` provider.
 *
 * The response is raw 16-bit little-endian PCM (`audio/pcm; codecs=s16le`),
 * with `X-Oppi-Sample-Rate` and `X-Oppi-Channels` headers, written passage by
 * passage as each is synthesized. Headers wait for the first passage, so a
 * provider failure before any audio is a JSON error. A failure later aborts the
 * connection, which the client sees as an incomplete stream rather than a clean
 * end. Closing the request stops synthesis.
 */
export function createSpeechRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (path !== "/speech") return false;
    if (method !== "POST") {
      helpers.error(res, 405, "Method not allowed");
      return true;
    }

    const abort = new AbortController();
    const onClose = (): void => {
      if (!res.writableFinished) abort.abort();
    };
    res.on("close", onClose);
    try {
      const body = await helpers
        .parseBody<unknown>(req, { maxBytes: 512 * 1024 })
        .catch((error: unknown) => {
          throw new SpeechError(400, errorMessage(error));
        });
      const text =
        body && typeof body === "object" && !Array.isArray(body) && "text" in body
          ? (body as { text: unknown }).text
          : undefined;
      if (typeof text !== "string") throw new SpeechError(400, "Expected text");

      const speech = await startSpeech(ctx.storage.getConfig().tts, text, abort.signal, {
        getAuth: ctx.getProviderAuth,
      });
      if (abort.signal.aborted) return true;
      res.writeHead(200, {
        "Content-Type": "audio/pcm; codecs=s16le",
        "Cache-Control": "no-store",
        "X-Oppi-Sample-Rate": String(speech.sampleRate),
        "X-Oppi-Channels": String(speech.channels),
      });
      res.write(speech.first);
      try {
        for await (const pcm of speech.rest) {
          if (abort.signal.aborted) break;
          if (!res.write(pcm)) {
            await new Promise<void>((resolve) => {
              const settle = (): void => {
                res.off("drain", settle);
                res.off("close", settle);
                resolve();
              };
              res.once("drain", settle);
              res.once("close", settle);
            });
          }
        }
      } catch (error) {
        if (!abort.signal.aborted) {
          log.warn("speech.stream_failed", { error: errorMessage(error) });
        }
        res.destroy();
        return true;
      }
      res.end();
    } catch (error) {
      if (abort.signal.aborted || res.headersSent) {
        res.destroy();
        return true;
      }
      const status = error instanceof SpeechError ? error.status : 502;
      helpers.error(res, status, errorMessage(error));
    } finally {
      res.off("close", onClose);
    }
    return true;
  };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
