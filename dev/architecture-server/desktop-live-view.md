# Desktop live-view lane

Part of [Oppi server architecture](../architecture-server.md). Experimental Mac → Node H.264 relay (`experimental.desktopLiveView`, default off). Slice 1: companion capture/encode, Node rate control, shaped-link bench. Slice 2 adds the iPhone viewer.

## Owners

| Fact | Owner |
| --- | --- |
| View grant, selected surface, NV12 capture, H.264 encode | OppiMac (`clients/apple/OppiMac/Capture`) |
| Device auth, experiment flag, in-flight window, quality ladder | Node (`server/src/desktop-view-stream.ts`, `desktop-view-rate-controller.ts`) |
| Phone-wire media bytes | Mac writes them; Node forwards the companion media payload unchanged |

Newest captured pixel buffer wins before encode. Encoded frames are not dropped mid-relay. Exceeding the hard in-flight cap closes the stream.

## Topology

```mermaid
sequenceDiagram
  participant P as Phone / bench client
  participant N as Node relay
  participant M as OppiMac
  P->>N: WSS /desktop/view/stream (device at_)
  N->>M: companion.sock GET /view/stream Upgrade 101
  M-->>N: hello JSON
  N-->>P: hello JSON
  N-->>P: ping
  P->>N: pong
  N->>M: encode JSON
  M-->>N: media companion frame
  N-->>P: same media bytes on WS binary
  P->>N: ack
```

Flag off or an owner principal is HTTP 404 before upgrade (network owner `sk_` is still 401). Connect requires the Mac grant bound to this device. One live stream per process. Grant revoke/expiry, surface loss, and device revoke close the socket.

## Wire

Control is JSON. Video is a 24-byte header plus AVCC H.264 (4-byte NAL lengths). SPS/PPS are prepended as length-prefixed NALUs on every IDR. Feature string `h264-avcc`. Companion unix frames are `u32be length | u8 type | payload` (`type` 1 = JSON, 2 = media). Media payloads are the phone binary frame. Phone binary frames are sent with `compress: false`.

| Offset | Field |
| --- | --- |
| 0 | version u8 = 1 |
| 1 | flags u8 (bit 0 = keyframe) |
| 2 | header size u8 = 24 |
| 3 | reserved |
| 4 | frameId u32be |
| 8 | capturedAtMs u64be |
| 16 | width u16be |
| 18 | height u16be |
| 20 | payloadBytes u32be |
| 24 | AVCC H.264 |

Fatal application codes **4100–4199** must not reconnect. A companion hello with missing `features` or `version !== 1` closes with 4100. Fixture: `protocol/desktop-view-stream.json`.

## Rate control

Clock-injected. Window = `max(2 × frameBytes, 1.5 × commandedBitrate/8 × baseRTT)`. Ack rate is not used for the window. Base RTT is ping-only, windowed min over 10 s. Before the first real down-step, `shouldEncode` wakes every `max(50 ms, baseRTT)` and raises one rung even during the fps wait. A full window does not reset that clock. Down-step only when the **minimum** frame RTT over `max(1 s, 2 × baseRTT)` exceeds `base + max(50 ms, 0.5·base)`, at most once per base RTT. Hold starts at 1 s and doubles only when the level actually decreases (cap 8 s), then resets after 5 s clean. Ladder drops fps before scale. Hard cap 2 MiB: companion reader max is the cap; Node closes if a companion payload exceeds it or if `ws.bufferedAmount + payload` would exceed it. Not a second pacer.

## Encoder

Hardware + low-latency (`RequireHardwareAcceleratedVideoEncoder`, `EnableLowLatencyRateControl`). Low-latency documents High profile only; this Mac uses `H264_High_AutoLevel`. Output callback is a retained per-frame box (`sourceFrameRefcon`); no VideoToolbox call runs under the encoder lock. A generation checked under that lock is required before installing a new VT session: `invalidate` bumps it and sticks, `attach` starts a new generation. Companion writes drop unless the generation matches the one captured when `encode` started. `fail` only `shutdown`s the fd; the read thread closes after `read` returns. Every ScreenCaptureKit live-view terminal path (`didStopWithError` any error, failed `startCapture`) ends the stream with `surfaceGone` and does not idle-encode after the producer stops.

## Bench

Userspace FIFO shaper: shared per-direction `nextFreeAt` serialization, pipelined one-way delay (deliverAt from arrival, not serial await), jitter, stalls. Not a token bucket. Not real packet loss. Fake companion, no Screen Recording. Payloads are random; keyframes ~6× P-frame size. Runs are ≥30 s. fps/kbps are over first→last arrival. Ladder is a time-weighted level histogram plus down-step count. Post-ramp dwell starts at the first down-step, or at first reaching the run's max level.

Command: `cd server && npm run bench:desktop-live-view`

Bench date: 2026-10-11 (30 s runs, pipelined shaper). The harness exits non-zero when a preset misses a target. Targets unchanged: LAN reaches L7 ≤ 1 s after first frame; tailscale-wan majority at L6–L7; LTE settles L5–L6; bad-cell settles L2–L4; no preset spends > 20% of post-ramp time at L0; a single stall does not cascade 3+ rungs within 2 s. Post-ramp starts at the first down-step, or at first reaching the run's max level.

| preset | ttff_ms | fps | age_p50 | age_p95 | age_max | gaps>100ms | kbps | ladder | ctrl_p50 | ctrl_p95 | revoke_ms | targets |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| lan | 21 | 29.17 | 2 | 3 | 18 | 1 | 7831.7 | L7:99% down=0 | 3 | 4 | 3 | PASS |
| tailscale-wan | 281 | 25.95 | 45 | 51 | 121 | 2 | 7111.9 | L7:82% down=0 | 93 | 104 | — | PASS |
| lte | 470 | 21.63 | 72 | 199 | 303 | 7 | 5697.9 | L7:70% down=0 | 146 | 215 | — | FAIL L5–L6 (post-ramp is L7) |
| bad-cell | 863 | 7.56 | 150 | 2025 | 2054 | 8 | 1444.8 | L6:20% L7:44% down=1 | 311 | 838 | — | FAIL L2–L4 (post-ramp is L7) |

The earlier WAN miss was the shaper: each chunk awaited the previous chunk's full one-way delay, so fps could not exceed ~1000/(delay+jitter) and the byte-rate controller looked app-limited. After pipelining deliverAt from arrival, LAN and tailscale-wan pass. LTE stays at L7 (8 Mbit/s commanded on 8 Mbit/s) so L5–L6 post-ramp is 0% once post-ramp starts at first L7. bad-cell still climbs to L7 with one down-step; L2–L4 post-ramp is 0%. IDR bytes no longer update the window or min-RTT set. Targets not loosened. Userspace shaper cannot emulate real packet loss.

VideoToolbox: hardware + low-latency High profile on this Mac. OppiMacTests decode real AVCC output (SPS/PPS+IDR, P-frame, forced IDR, AverageBitRate readback) via `completeFrames()`.

Chen's leftover: real ScreenCaptureKit through OppiMac once slice 2 shows it on the phone.
