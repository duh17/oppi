# Oppi Dictation Mode: Design Document

**Date:** 2026-04-03
**Status:** Design ready, implementation not started
**Location:** Oppi server + iOS client (no mlx_server dependency)

## Problem

The iOS client sends 2-second audio chunks independently to a separate STT server. Each chunk is transcribed without context, producing duplicate text at boundaries and 22.87% WER — 8.5× worse than the model's batch capability (2.70%).

Production ASR services solve this with accumulate-and-retranscribe: grow an audio buffer, retranscribe the whole thing each update, return the complete transcript.

## Solution

Build the STT service directly into the Oppi server. A managed Python sidecar loads Qwen3-ASR via mlx-audio. The iOS client sends audio over the existing WebSocket. The Oppi server accumulates audio per session and retranscribes the growing buffer.

```
iPhone (Oppi app)
  │ existing WS to Oppi server (/stream)
  │
  │ → {type: "dictation_start", language: "en"}
  │ → binary audio frames (PCM 16kHz mono)
  │ → {type: "dictation_stop"}
  │
  ▼
Oppi Server (Node.js)
  │ DictationManager
  │   accumulates audio per WS connection
  │   sends accumulated buffer to Python sidecar
  │
  │ ← transcript text
  │
  │ → {type: "dictation_result", text: "...", confirmed: "...", tentative: "..."}
  │ → {type: "dictation_final", text: "..."}
  │
  ▼
Python Sidecar (managed child process)
  │ Loads Qwen3-ASR-1.7B via mlx-audio
  │ Accepts audio over stdin/pipe
  │ Returns transcription over stdout
  │ Stays warm (model loaded once)
```

### Why this architecture

- **No separate STT server** — no mlx_server, no extra port, no separate URL config
- **Auth for free** — the existing WS connection is already authenticated
- **No chunked HTTP** — continuous audio stream over WS, server controls processing schedule
- **Accumulate-and-retranscribe** — server owns the audio buffer, always transcribes the full thing
- **Auto-discovery** — dictation works as soon as the Oppi server is connected (iOS already knows the server)

## Performance Budget

At 28× RTFx on M3 Ultra, Qwen3-ASR-1.7B can retranscribe:

| Accumulated audio | Processing time | Within 2s budget? |
|---|---|---|
| 5s | ~175ms | ✅ |
| 15s | ~520ms | ✅ |
| 30s | ~1.0s | ✅ |
| 60s | ~2.1s | ⚠️ borderline |

O(n²) total compute for a 30s session = 12s. For 60s = 47s. Both fine.

### Expected results

| Metric | Current (chunked HTTP) | Target (accumulate WS) | Batch baseline |
|---|---|---|---|
| WER | 22.87% | 3-5% | 2.70% |
| TTFT | ~2s | ~1.5s | N/A |
| Update latency | 140ms/chunk + HTTP | ~500ms | 316ms |

## Server Components

### 1. Python Sidecar Worker

`oppi/server/stt/worker.py` — standalone Python script managed by the Oppi server.

**Lifecycle:**
- Spawned on first dictation request (or at server startup if configured)
- Stays alive — model loaded once (~3s load, 4.1GB RAM)
- Communicates via stdin/stdout with newline-delimited JSON
- If it crashes, Oppi server respawns on next request

**Protocol (stdin → stdout):**
```jsonl
→ {"cmd": "transcribe", "id": "req1", "audio_b64": "...", "language": "English"}
← {"id": "req1", "text": "The quick brown fox", "language": "English", "duration_ms": 520}

→ {"cmd": "ping"}
← {"ok": true, "model": "Qwen3-ASR-1.7B-bf16", "uptime_s": 3600}
```

Audio sent as base64-encoded 16-bit PCM (16kHz mono). ~32KB/s of audio = ~43KB/s base64. For a 30s buffer = ~1.3MB per request. Acceptable for stdio.

**Implementation:**
```python
#!/usr/bin/env python3
"""Oppi STT worker — loads Qwen3-ASR, transcribes via stdio JSON protocol."""
import sys, json, base64, numpy as np
from mlx_audio.stt.utils import load_model

model = load_model("mlx-community/Qwen3-ASR-1.7B-bf16")

for line in sys.stdin:
    req = json.loads(line)
    if req["cmd"] == "transcribe":
        pcm = np.frombuffer(base64.b64decode(req["audio_b64"]), dtype=np.int16)
        audio = pcm.astype(np.float32) / 32768.0
        # Write to temp wav, transcribe
        result = model.generate(audio_path, language=req.get("language"))
        print(json.dumps({"id": req["id"], "text": result.text}), flush=True)
    elif req["cmd"] == "ping":
        print(json.dumps({"ok": True}), flush=True)
```

### 2. DictationManager (TypeScript)

`oppi/server/src/dictation-manager.ts` — manages sidecar lifecycle + per-connection audio state.

```typescript
class DictationManager {
  private sidecar: ChildProcess | null = null;
  private sessions: Map<WebSocket, DictationSession> = new Map();

  // Sidecar lifecycle
  async ensureSidecar(): Promise<void>
  private spawnSidecar(): ChildProcess
  private handleSidecarExit(): void

  // Per-connection dictation
  startSession(ws: WebSocket, language?: string): DictationSession
  appendAudio(ws: WebSocket, pcmData: Buffer): void
  async processUpdate(ws: WebSocket): Promise<DictationResult>
  async finalize(ws: WebSocket): Promise<DictationResult>
  cancelSession(ws: WebSocket): void
}

interface DictationSession {
  audioBuffer: Buffer[];        // Growing list of PCM chunks
  totalSamples: number;
  language: string | null;
  lastTranscript: string;       // For LocalAgreement
  prevTranscript: string;       // For LocalAgreement
  processingTimer: NodeJS.Timeout | null;
  startedAt: number;
}
```

**Processing loop:** Every 2 seconds (or when audio accumulates past a threshold), concatenate all audio chunks, base64-encode, send to sidecar, return result. Timer-based, not chunk-triggered.

### 3. WebSocket Message Types

Add to existing `/stream` WS protocol:

**Client → Server:**
```typescript
// Start dictation (generates internal session)
| { type: "dictation_start"; language?: string }

// Binary frame — raw PCM audio (16-bit, 16kHz, mono)
// Sent as WebSocket binary message (not JSON)

// Stop dictation gracefully (final transcription)
| { type: "dictation_stop" }

// Cancel dictation (discard)
| { type: "dictation_cancel" }
```

**Server → Client:**
```typescript
// Interim transcription result (may change)
| { type: "dictation_result"; text: string; confirmed?: string; tentative?: string }

// Final transcription (won't change)
| { type: "dictation_final"; text: string }

// Error
| { type: "dictation_error"; error: string }

// Ready acknowledgment
| { type: "dictation_ready" }
```

### 4. WS Handler Integration

In `server.ts` `handleUpgrade` or `ws-message-handler.ts`:

```typescript
// Binary messages → dictation audio
ws.on("message", (data, isBinary) => {
  if (isBinary) {
    dictationManager.appendAudio(ws, data as Buffer);
    return;
  }
  // Existing JSON message handling...
  const msg = JSON.parse(data.toString());
  if (msg.type === "dictation_start") { ... }
  if (msg.type === "dictation_stop") { ... }
  if (msg.type === "dictation_cancel") { ... }
});
```

## iOS Client Changes

### RemoteASRTranscriber → OppiDictationTranscriber

Replace the HTTP-based `RemoteASRTranscriber` with a WS-based transcriber that uses the existing Oppi server connection:

```swift
final class OppiDictationTranscriber {
    private let ws: WebSocket  // Existing Oppi server connection

    func start(language: String?) {
        ws.send(json: ["type": "dictation_start", "language": language])
    }

    func appendAudio(buffer: AVAudioPCMBuffer) {
        // Convert to 16-bit PCM, send as binary WS frame
        let pcmData = buffer.toPCM16Data()
        ws.send(binary: pcmData)
    }

    func stop() async -> String {
        ws.send(json: ["type": "dictation_stop"])
        // Wait for dictation_final message
    }
}
```

### VoiceInputManager

- Remove `remoteASREndpoint` configuration (no separate URL needed)
- Dictation available whenever Oppi server is connected
- Route indicator: `.remote` when using Oppi server dictation

### Settings

- Remove "Remote ASR Endpoint" setting
- Add "Dictation Engine" toggle: On-Device / Server
- Server option automatically uses connected Oppi server

## Phase Plan

### Phase 1: Sidecar + HTTP accumulate (1-2 days)

Before touching the WS protocol, prove the accumulate-and-retranscribe approach works:

1. Build the Python sidecar worker
2. Build DictationManager with HTTP endpoint (temporary, for testing)
3. Add `session_id` to mlx_server's existing `/v1/audio/transcriptions`
4. Benchmark: should see WER drop from 22.87% to ~3-5%

### Phase 2: WS integration (2-3 days)

1. Add dictation message types to Oppi WS protocol
2. Binary audio frame handling in WS handler
3. DictationManager processes on timer (every 2s)
4. Server → client interim/final results

### Phase 3: iOS client (2-3 days)

1. OppiDictationTranscriber using existing WS
2. Wire into VoiceInputManager as a new provider
3. Remove separate endpoint configuration
4. UI for confirmed/tentative text display

### Phase 4: LocalAgreement + polish (1 day)

1. Compare consecutive transcriptions
2. Split into confirmed/tentative
3. VAD-based utterance segmentation (auto-finalize on silence)
4. Session timeout / max duration handling

## Open Questions

1. **Sidecar vs HTTP to mlx_server**: Phase 1 could use either. Sidecar is cleaner (no mlx_server dependency) but more code. HTTP to mlx_server reuses existing infrastructure. Both are valid starting points.

2. **Binary WS frames**: The existing WS protocol is JSON-only. Binary frames for audio are a new pattern. Need to ensure the WS handler correctly distinguishes binary vs text frames.

3. **Concurrency**: MLX inference is single-threaded. If a TTS request arrives during dictation transcription, it queues. Acceptable? Or should dictation have priority?

4. **Model preloading**: First transcription after sidecar spawn takes ~3s (model load). Should the sidecar preload at server start? Or lazy-load on first dictation?

5. **Fallback**: If sidecar isn't available (Python not installed, model not downloaded), should it fall back to Apple on-device dictation? Yes — the VoiceInputRouting already handles this.

## Benchmark Validation

Use `~/workspace/mlx_server/scripts/benchmark_dictation.py` during Phase 1:

```bash
# Batch baseline (target quality)
uv run scripts/benchmark_dictation.py --full-audio --samples 50

# Accumulate mode (after Phase 1)
uv run scripts/benchmark_dictation.py --samples 50 --profile dictation

# Current chunked mode (baseline to beat)
uv run scripts/benchmark_dictation.py --samples 50
```

| Metric | Good | Excellent |
|---|---|---|
| WER (clean) | <6% | <4% |
| TTFT | <2s | <1s |
| Update latency | <1s | <500ms |
| RTFx | >15× | >25× |
| Max session | >60s | >120s |

## References

- Research: `/tmp/dictation-chunking-research.md`
- Benchmark script: `~/workspace/mlx_server/scripts/benchmark_dictation.py`
- iOS voice pipeline: `oppi/clients/apple/Oppi/Core/Services/RemoteASR*.swift`
- Oppi WS protocol: `oppi/server/src/types.ts` (ClientMessage/ServerMessage)
- Oppi WS handler: `oppi/server/src/ws-message-handler.ts`
- Qwen3-ASR mlx-audio: `mlx_audio/stt/models/qwen3_asr/qwen3_asr.py`
- Whisper-Streaming (LocalAgreement): https://github.com/ufal/whisper_streaming
