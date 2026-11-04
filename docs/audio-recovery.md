# Audio recovery — 9.0.17

Base: portrait keyboard 9.0.16, retaining its UI and resolution behavior. This
release repairs audio timeline/output liveness while keeping the existing
recovery-delay setting and redundancy design. No host configuration is changed.

## Report and diagnosis

The user reports spontaneous persistent silence while video and input remain
normal. There was no preceding headset/output change or other deliberate action.
Backgrounding Moonlight and reconnecting restores sound. No iPad log from the
failure is available, so the precise trigger on the device remains unconfirmed.

Three concrete defects were found: the fixed RTP anchor wraps after 32768 frames;
receive/decode/statistics access shared guard slots without synchronization;
and SDL output backpressure loops forever when a device stops consuming PCM.
The host log confirms several reconnects and successful Opus initialization,
but does not establish which of these caused the reported device failure.

## Changes

- A moving RTP anchor prevents half-range/wrap errors. Bounded clock tracking
  follows drift; stale-source and decoder-pause recovery restore the timeline.
- Shared ring/FEC state is locked, and workers finish before guard cleanup.
- The decoder no longer waits indefinitely for SDL queue space. PCM storage is
  bounded; stale excess output is dropped while the media pipeline keeps moving.
- If started output is unexpectedly paused/stopped, or its queue does not drain
  for 250ms, the decoder thread recreates only the SDL playback device and
  explicitly activates AVAudioSession. It refills the normal startup cushion.
  Failed repairs retry at most once per second. Video/Opus/network state remains
  live through this output repair.
- Audio interruption, route change, media-services loss/reset and app activation
  notifications request recovery atomically. Active interruptions defer playback
  and discard stale PCM. System notification callbacks never close SDL directly.
- Output-repair/drop counts join the periodic `[AudioScheduler]` log; notification
  and reopen diagnostics use `[AudioRecovery]`. Common-c logs hard re-anchors.

The notification handling follows Apple's
[interruption guidance](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)
and [media-services reset guidance](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification).
The output-device progress check also covers silence without an observed system
notification. Detecting host-supplied silent samples is outside this watchdog.

## Verification records

### R1 — failing old pipeline

Method: drive the original common-c guard with sequential 5ms packets and a
simulated monotonic clock, bounding outputs per arrival. At packet 32768
(163.840s), old code generates over 1000 outputs and leaves its deadline
322.525s behind. The repaired code completes the same 70000-frame reproduction.
This establishes a real pipeline defect; it does not prove the actual iPad
failure occurred at that boundary.

### R2 — timeline stability and resumed input

Method: common-c `tests/run_audio_recovery.sh`, also with ASan/UBSan. Three
400000-frame streams cover 0/+400/-400 ppm drift, multiple sequence wraps and
late copies. Additional cases stop network media or the host's sequence clock
for three seconds, and suspend decoder progress for ten seconds.

Results: all long-run originals delivered without PLC/resync, both outages
recover continuously, pause catch-up is bounded. The original 80-phase AWDL
suite and loss counters still pass with test assertions enabled.

### R3 — frozen output and interruption recovery

Method: `tests/test_audio_output_recovery.c` drives the same production output
controller through injected device operations. Cases include healthy drain,
PLAYING status with a frozen queue, explicit interruption, reopen failures,
cooldown, failed queue submission, and an undersized configured queue limit.

```sh
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  tests/test_audio_output_recovery.c -o /tmp/test_audio_output_recovery
/tmp/test_audio_output_recovery
```

Results: the frozen device is recreated, queue size remains bounded, active
interruptions do not force playback, failed opens retry no faster than once per
second, and recovered output starts with fresh buffered PCM. Tests pass under
ASan/UBSan. These are failure-injected device operations; actual CoreAudio
interruption/reset delivery and physical sound have not been tested.

### R4 — Apple builds and publication

Pending.

## Device acceptance

Update to 9.0.17 and reconnect once. Keep a stream with continuous host audio
running well beyond several minutes. If silence recurs, retain Moonlight logs
around `[AudioRecovery]`, `[AudioScheduler]` and `AudioBurstGuard`, and note the
audio loss statistics before reconnecting. Confirm that video/input continue,
whether output-repair counts increase, and whether audio returns by itself.
Also test a real audio interruption, output route change, foreground return,
and a media-services reset where available. Physical device acceptance remains
pending; a simulator build alone does not establish successful audible recovery.
