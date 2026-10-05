# Audio Burst Guard — iOS client integration notes

This fork of Moonlight iOS integrates the
[AudioBurstGuard](https://github.com/DarkPaper2022/moonlight-common-c/blob/master/docs/AudioBurstGuard.md)
audio recovery engine from our `moonlight-common-c` fork. See that
document for the full design; this page covers the client integration
and observable behavior.

## Why

Apple Wi-Fi stacks coexist with AWDL (AirDrop/Sidecar) by leaving the
BSS channel for ~80ms every ~400ms. With a Sunshine host streaming
5ms Opus frames, those blackouts appear as bursts of 1-17 lost audio
frames — audible as cracks/pops that plain jitter buffers cannot hide.

## What changed

- `Connection.m` enables `LiSetAudioBurstGuardEnabled(true)` for every
  stream, with a 150ms recovery window and a 20ms SDL output cushion.
- The audio path uses a fixed-delay playout scheduler (150ms default)
  paced on a monotonic clock; the reservoir size remains tunable
  in-app (`targetAudioBufferMs`).
- Missing frames synthesize a single PLC frame each, keeping the
  decoder timeline continuous through bursts.
- The stats overlay renders live audio loss rate: lost vs recovered
  (temporal duplicate / FEC) frame counts via `LiGetAudioStats()`.

For the loss rate to drop to zero, the host must also send temporal
redundancy (every audio datagram re-sent +120ms). With a plain host the
guard still prevents pipeline stalls but the physical losses surface as
PLC frames.

## Validation

- Deterministic unit tests in moonlight-common-c sweep all 80 phase
  alignments of the 400ms/80ms pattern: 0 PLC with duplicates enabled.
- A real-network UDP harness (`tests/e2e` in moonlight-common-c)
  reproduces the result over live Wi-Fi: 0 PLC, 0 starvation,
  1-2 rescued frames per second.
