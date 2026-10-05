# Moonlight Audio Burst Guard Baseline

Date: 2026-10-05
Specification: `MOONLIGHT_AUDIO_BURST_GUARD_SPEC.md`

## 1. Repository Commit Baseline
* **moonlight-ios**: `38f5fa6ebeb1ce36f7fd5f88a494132401d341a0` (branch `master`)
  - Remote origin: `https://github.com/DarkPaper2022/moonlight-ios.git`
  - Remote upstream: `https://github.com/moonlight-stream/moonlight-ios.git`
* **moonlight-common-c**: `bfebc42e99a78458beb9d395458a952240aaeda0` (branch `master`)
  - Remote origin: `https://github.com/DarkPaper2022/moonlight-common-c.git`
  - Submodules:
    - `enet`: `aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1`
    - `nanors`: `b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a`
* **Sunshine Host**:
  - Version: `2026.914.233613` (package `sunshine-bin 2026.914.233613-1`)
  - Git Commit: `63d35f702ee9e362e43263742981836ec0710384`

## 2. Review Findings & Regressions to Address
1. **Unit bug in legacy wait time**:
   `RtpAudioQueue.c::handleMissingPackets()` had `AudioPacketDuration * RTPA_DATA_SHARDS` without converting ms to us.
2. **Whole block skipping**:
   When packets from an entire FEC block are missing due to an 80ms AWDL blackout, `handleMissingPackets()` or sequential packet ingest can skip ahead and discard future duplicates.
3. **Playout Scheduler & FEC Separation**:
   In previous implementation, fixed playout scheduler was placed downstream of `RtpaAddPacket`. Packets rejected early by `RtpaAddPacket` could not be rescued regardless of downstream playout delay.
4. **SDL Queue Metric Semantics**:
   `SDL_GetQueuedAudioSize() == 0` is an observation of SDL audio queue fullness, not direct proof of DAC hardware underrun.
