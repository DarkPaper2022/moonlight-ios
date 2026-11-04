# Personal development diagnostics

Capture is enabled only when a private `MoonlightDiagnostics.plist` is present
in the application bundle. Normal published 9.0.17 has no collector credentials.
Never commit that plist, signing material, session tokens, or device backups.

The private plist contains `Enabled`, `ControlEnabled`, `BearerToken` (at least
32 characters), and `EndpointURLs` (HTTPS URLs ending in
`/moonlight-diagnostics/v1`). The installed personal build uses the developer's
existing IPA gateway host and its IPv6 alternative. Failed uploads alternate
endpoints and back off up to 30 seconds. Successful uploads catch up immediately.
A missing/invalid configuration starts neither capture nor the control listener.

## Data path and schema

The receive/playout threads emit metadata into two fixed 65,536-record buffers.
Producers use `pthread_mutex_trylock`: contention or capacity exhaustion drops
trace records, with an explicit cumulative counter, instead of waiting for disk
or networking. A serial utility queue swaps buffers every two seconds, gzip
compresses them, and spools at most 32 MiB in `Caches/MoonlightDiagnostics`.
Authentication and HTTPS are required for uploads. Audio/video payloads, user
input and encryption keys are never trace fields.

Each gzip batch has a 32-byte little-endian header `<8sIIIIQ>`:
`MLTRACE1`, schema 1, record size 32, record count, reserved 0, dropped-record total.
The event layout is `<QIIIHHBBHI>`:

| Field | Meaning |
| --- | --- |
| timeUs | common-c monotonic microseconds; receive timestamp immediately after recv |
| value / aux / detail | event-specific integers; detail is currently reserved |
| sequence / bytes | RTP sequence and wire length, or event-specific zero |
| kind / stream | event type; stream 1 audio, 2 video, 3 system |
| flags / reserved | event-specific flags; reserved is zero |

`tools/diagnostics/protocol.py` enumerates all event kinds. Important events:

- audio/video receive: `value` is RTP timestamp, flags contain RTP payload type.
- audio ingest: low eight flag bits are payload type; `0x100` accepted,
  `0x200` discarded late, `0x400` duplicate of a pending frame.
- audio playout: value 1 original, 2 delayed/duplicate classification, 3 FEC,
  4 PLC. Classification 2 uses arrival delay; it is not proof of transmitter copy identity.
- audio resync: value is the resync count; sequence is the new expected sequence.
- output: value queued PCM bytes, aux output repair count, flags SDL status.
- video drop: flags 1 runt, 2 stale encrypted frame, 3 decryption failure.
- path: value interface (1 Wi-Fi, 2 cellular, 3 wired), aux Network path status;
  flags IPv4 1, IPv6 2, expensive 4, constrained 8. Availability is not proof of
  the address family actually used by the GameStream connection.
- marker: value 1 injected output pause; value 2 flush with aux spool-drop count.

Manifests correlate monotonic and wall time and include stream dimensions,
bitrate, frame rate, selected audio delay, OS/app versions and path state.
Only one active stream may own the common-c callback. Register before connection
start; stop connection workers before clearing/replacing callback context.

## Collector and analysis

The Python standard-library receiver binds loopback only, behind an existing
HTTPS Nginx gateway. It validates bearer auth, UUID/batch paths, gzip/schema and
size limits; limits concurrency and applies a 1 GiB / seven-day storage budget.
Repeated uploads are accepted only when their hashes match. Configuration:

```sh
python3 tools/diagnostics/receiver.py --root /private/path/traces \
  --token-file /private/path/upload-token --port 21847
python3 tools/diagnostics/analyze.py /private/path/traces/SESSION \
  --csv /private/path/session.csv
python3 -m unittest discover -s tools/diagnostics -p 'test_*.py'
```

The local deployment is a user service, `moonlight-diagnostics.service`;
its persistent traces are `~/.local/share/moonlight-diagnostics/SESSION`.
The gateway route `/moonlight-diagnostics/v1/` proxies loopback 21847 with a 3 MiB
body limit. `/health` is read-only and unauthenticated; uploads require auth.

Analysis reports receive interarrival percentiles, long-gap timestamps,
duplicate delays, rollover-aware duplicates/reordering/interior sequence holes,
PLC runs, output repair samples, trace drops and missing batches. CSV retains
individual events for finer timing analysis. Audio PT 127 is excluded from the
PT 97 sequence space. Holes are receiver observations, not proven network loss:
check trace drops, source pauses, missing batches and capture boundaries first.
This format cannot establish synchronized one-way latency.

## USB control and repeatable device tests

A configured development build listens on **127.0.0.1:9537 on the iPad**, requiring
the same token. Forward it using a USB `iproxy` bound to local loopback. The
host deployment uses `moonlight-debug-usb.service`; no LAN control port is open.

```sh
python3 tools/development/control.py --token-file /private/path/upload-token status
python3 tools/development/control.py --token-file /private/path/upload-token ui
python3 tools/development/control.py --token-file /private/path/upload-token resume
python3 tools/development/control.py --token-file /private/path/upload-token pause-output
python3 tools/development/control.py --token-file /private/path/upload-token rebuild
python3 tools/development/control.py --token-file /private/path/upload-token observe \
  --seconds 220 --output /private/path/observe.jsonl
```

`resume` resumes the selected host's already-running application using Moonlight's
normal stream setup. It does not quit host applications. UI activation dispatches
public UIKit control actions; it cannot activate every UIAlertController menu.
Output fault injection only sets an atomic request, applied on the decoder
thread. Device suspension makes USB control unavailable until the app returns
to the foreground. Keep LiveContainer main/LC2/LC3 ownership explicit.

For unsigned device builds, `tools/development/patch_guest.py` applies the thin
arm64 LC transformation before signing. Sign using the existing LC certificate
and host CodeDirectory identifier, not the guest identifier. Add a new uniquely
named application directory/executable; retain the original data namespace and
backup before modifying it. Never use CoreDevice `--remove-existing-content`:
it clears the entire selected domain, even with a destination subdirectory.
Do not re-sign/reinstall the native LC hosts or change their App Group rights.

## Experiments (2026-11-05)

### R1 — bounded capture, receiver and actual library

ASan/UBSan capture stress: three producers submit 600,000 records while a serial
consumer swaps buffers. Stored records plus explicit drops equal the input;
capacity and contended locks are covered. Receiver tests cover auth, path/schema,
gzip expansion, idempotence, quota, sequence rollover/reorder and bounded analysis
of a ten-digit batch-index discontinuity. All five Python cases pass. Existing
400,000-frame audio timing tests, output recovery tests and the actual shared
library's 500 concurrent statistics/teardown cycles also pass. Xcode 26.2 builds
the iOS Release integration successfully. tvOS build is not checked here.

### R2 — physical iPad, output repair and collector outage

Personal 9.0.18 in LC3, iOS 27.0.1, paired Sunshine desktop, 2388×1668, 60fps,
60,000 kbps, 300ms selected audio window. Approximately 298 seconds of uploaded
trace contains 851,152 records, 1,479 explicitly dropped capture records and no
missing batches. This is a local nonblocking capture tradeoff, not a lossless
wire capture. The audio decoder reaches 57,200 frames and keeps running across
the old 163.84-second failure boundary.

A USB output-pause injection triggers the existing watchdog: output repair count
0→1, SDL returns to PLAYING, fresh PCM queues and decoding continues without a
reconnect. Actual speaker sound cannot be verified remotely. Stopping only the
owned receiver for 39.7 seconds causes HTTP 502 and 19 pending files; restarting
it drains the queue to zero, without spool loss or missing uploaded batches.

The captured PT 97 duplicate delay median is about 119,973µs, matching the
configured temporal copy interval. It also contains 9,973 PLC outputs and many
re-anchors: some ten-second receive windows cover only about 8.2 seconds of RTP
sequence progression. This does not establish whether source pacing, network
queueing or clock tracking is responsible. Keep this distinction when using
these logs to investigate future spontaneous silence on changing networks.

Private evidence resides in the development workspace's
`artifacts/development-debugging/`: device console, status snapshots, collector
outage timestamps, JSONL observation, analysis JSON and per-event CSV. Private
configuration and raw app data remain outside the repository.
