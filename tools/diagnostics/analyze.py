#!/usr/bin/env python3
"""Reproduce reception/playout timelines without claiming one-way latency."""
import argparse
from collections import Counter
import csv
import json
from pathlib import Path
from protocol import decode_batch, KINDS


def reception(events, kind):
    # Exclude audio FEC (PT 127): its sequence space is separate from PT 97.
    packets = [e for e in events if e[6] == kind and (kind != 1 or (e[8] & 127) == 97)]
    seen, high, duplicates, reordered = {}, None, 0, 0
    max_gap, previous = 0, None
    intervals, duplicate_delays, long_gaps = [], [], []
    for event in packets:
        timestamp, seq = event[0], event[4]
        if previous is not None:
            gap = max(0, timestamp - previous)
            intervals.append(gap)
            max_gap = max(max_gap, gap)
            if gap >= 20000:
                long_gaps.append(dict(time_us=timestamp, gap_us=gap, next_sequence=seq))
        previous = timestamp
        extended = seq if high is None else high + ((seq - high + 32768) % 65536 - 32768)
        if extended in seen:
            duplicates += 1
            duplicate_delays.append(timestamp - seen[extended])
        elif high is not None and extended < high:
            reordered += 1
        seen.setdefault(extended, timestamp)
        high = extended if high is None else max(high, extended)
    # Count unresolved interior holes after late copies; don't count unknown tails.
    holes = max(seen) - min(seen) + 1 - len(seen) if seen else 0
    intervals.sort()
    duplicate_delays.sort()
    percentile = lambda p: intervals[min(len(intervals)-1, int(p * len(intervals)))] if intervals else 0
    return dict(packets=len(packets), duplicates=duplicates, reordered=reordered,
                unresolved_sequence_holes=holes, max_interarrival_us=max_gap,
                p50_interarrival_us=percentile(.5), p99_interarrival_us=percentile(.99),
                duplicate_delay_p50_us=duplicate_delays[len(duplicate_delays)//2] if duplicate_delays else 0,
                gaps_at_least_20ms=len(long_gaps),
                largest_gaps=sorted(long_gaps, key=lambda g:g['gap_us'], reverse=True)[:20])


def missing_batches(batches):
    # Bound output even for a corrupt or discontinuous ten-digit batch index.
    ordered = sorted(set(batches))
    ranges = [(a+1, b-1) for a, b in zip(ordered, ordered[1:]) if b > a+1]
    count = sum(b-a+1 for a, b in ranges)
    sample = []
    for a, b in ranges:
        sample.extend(range(a, min(b+1, a+1000-len(sample))))
        if len(sample) == 1000:
            break
    return count, sample


def plc_bursts(events):
    bursts, current = [], None
    for event in events:
        if event[6] != 3:
            continue
        if event[1] != 4:
            current = None
            continue
        if current is None or (event[4] - current['last_sequence']) % 65536 != 1:
            current = dict(start_us=event[0], end_us=event[0], frames=0, last_sequence=event[4])
            bursts.append(current)
        current.update(end_us=event[0], frames=current['frames']+1, last_sequence=event[4])
    return dict(count=len(bursts), largest=sorted(bursts, key=lambda b:b['frames'], reverse=True)[:20])


def analyze(directory, csv_path=None):
    events, dropped, batches = [], 0, []
    for path in sorted(Path(directory).glob('*.mtrace.gz')):
        batch_dropped, batch = decode_batch(path.read_bytes())
        dropped = max(dropped, batch_dropped)
        events.extend(batch)
        batches.append(int(path.name.split('.')[0]))
    events.sort(key=lambda event: event[0])
    missing_count, missing = missing_batches(batches)
    if csv_path:
        with Path(csv_path).open('w', newline='') as output:
            writer = csv.writer(output)
            writer.writerow(['monotonic_us','value','aux','detail','sequence','bytes','kind','stream','flags','reserved'])
            writer.writerows(events)
    return dict(records=len(events), duration_seconds=(events[-1][0]-events[0][0])/1e6 if events else 0,
                trace_dropped_records=dropped, missing_trace_batches=missing,
                missing_trace_batch_count=missing_count,
                counts=dict(Counter(KINDS[e[6]] for e in events)),
                audio=reception(events, 1), video=reception(events, 4),
                audio_playout_status=dict(Counter(e[1] for e in events if e[6] == 3)),
                audio_plc_bursts=plc_bursts(events),
                audio_output_samples=[dict(time_us=e[0], queued_bytes=e[1], repairs=e[2], status=e[8]) for e in events if e[6] == 6],
                caveat='Sequence holes are observations at the receiver, not proof of network loss. '
                       'Capture overflow, missing batches, source pauses and upstream drops must be checked. '
                       'RTP timestamps do not establish synchronized one-way network latency.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('session', type=Path)
    parser.add_argument('--csv', type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.session, args.csv), indent=2))
