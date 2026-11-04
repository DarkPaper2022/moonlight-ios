#!/usr/bin/env python3
"""Join existing send-attempt metadata with device traces; no media or live control.

Host wall time is used only to select a session, never as synchronized latency.
Deadline-budget models are counterfactual and include capture uncertainty.
"""
import argparse
from bisect import bisect_right
from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import re
from protocol import decode_batch
from analyze import missing_batches


class Sequence:
    def __init__(self):
        self.high = None

    def extend(self, seq):
        extended = seq if self.high is None else self.high + ((seq-self.high+32768) % 65536-32768)
        self.high = extended if self.high is None else max(self.high, extended)
        return extended


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered)-1, int(p*len(ordered)))]


def distribution(values):
    return dict(count=len(values), p50=percentile(values,.5), p95=percentile(values,.95),
                p99=percentile(values,.99), maximum=max(values) if values else None)


def load_audio(directory, last_batches=None, max_events=None):
    events, batches, dropped, trimmed = [], [], 0, 0
    first_dropped = None
    files = sorted(Path(directory).glob('*.mtrace.gz'))
    if last_batches:
        files = files[-last_batches:]
    # One batch is bounded at 65,536 records; discard video before retaining data.
    for file in files:
        try:
            lost, rows = decode_batch(file.read_bytes())
        except FileNotFoundError: # Receiver retention may prune an old batch.
            continue
        if first_dropped is None:
            first_dropped = lost
        dropped = max(dropped,lost)
        batches.append(int(file.name.split('.')[0]))
        events.extend(e for e in rows if e[6] in (1,2,3,6,7,9,11,12,13,14))
        if max_events and len(events)>max_events:
            count=len(events)-max_events
            del events[:count]
            trimmed+=count
    events.sort(key=lambda e:e[0])
    missing, sample = missing_batches(batches)
    before = None
    if batches:
        if min(batches)==0:
            before=0
        else:
            previous=Path(directory)/f'{min(batches)-1:010}.mtrace.gz'
            try:
                before,_=decode_batch(previous.read_bytes())
            except FileNotFoundError:
                pass
    return events, dict(trace_dropped_records=dropped, missing_batch_count=missing,
                        trace_dropped_in_selected_batches=dropped-before if before is not None else None,
                        trace_drop_lower_bound_in_selected_batches=dropped-(first_dropped or 0),
                        missing_batch_sample=sample, batches=len(batches),
                        first_batch=min(batches) if batches else None,
                        last_batch=max(batches) if batches else None,
                        omitted_old_events=trimmed)


def arrival_patterns(paired, offset, host_start):
    bins, outcomes, episodes = {}, Counter(), []
    current, previous_seq = None, None
    for seq,tx,rx,copies in paired:
        relative = rx-(tx-host_start)-offset
        slow = relative>=60000
        outcomes[('delayed_first_' if slow else 'fast_first_')+('one_copy' if copies==1 else 'multiple_copies')] += 1
        index = (tx-host_start)//10000
        total,late = bins.get(index,(0,0))
        bins[index] = total+1,late+int(slow)
        if not slow:
            current = None
        else:
            if current is None or previous_seq!=seq-1:
                current = dict(first_send_us=tx,last_send_us=tx,frames=0)
                episodes.append(current)
            current.update(last_send_us=tx,frames=current['frames']+1)
        previous_seq = seq
    rates = {i:late/total for i,(total,late) in bins.items()}
    mean = sum(rates.values())/len(rates) if rates else 0
    correlation = []
    for lag in range(5,101):
        cross=left=right=0.0;count=0
        for i,value in rates.items():
            other=rates.get(i+lag)
            if other is None:continue
            a,b=value-mean,other-mean
            cross+=a*b;left+=a*a;right+=b*b;count+=1
        if left>0 and right>0:
            correlation.append(dict(lag_ms=lag*10,correlation=cross/(left*right)**.5,pairs=count))
    lengths = Counter(str((e['frames']*5//20)*20) for e in episodes)
    return dict(first_arrival_threshold_ms=60,outcomes=dict(outcomes),
                delayed_first_episodes=len(episodes),
                episode_media_length_ms_histogram_20ms_bins=dict(lengths),
                exploratory_autocorrelation=correlation,
                strongest_positive_lags=sorted(correlation,key=lambda r:r['correlation'],reverse=True)[:10],
                caveat='First-arrival delay is relative to minimum observed clock/path offset. A delayed first copy does not prove original-packet loss. Correlation is exploratory; it does not identify AWDL or a radio mechanism.')


def host_segments(path):
    if Path(path).stat().st_size > 64*1024*1024:
        raise ValueError('host log exceeds bounded snapshot limit')
    segments, previous = [], None
    expression = re.compile(r'^(\d+) EV=ORIG seq=(\d+) len=(\d+)')
    for line in Path(path).open():
        match = expression.match(line)
        if not match:
            continue
        when, seq, size = map(int,match.groups())
        if not segments or (seq == 0 and previous != 65535):
            segments.append(dict(first_us=when, first_seq=seq, packets={}))
            extend = Sequence()
        segment = segments[-1]
        extended = extend.extend(seq)
        segment['packets'][extended] = (when,size)
        segment['last_us'] = when
        previous = seq
    return segments


def receiver_metrics(events, frame_us=5000):
    received, ingested, playout, resyncs = {}, {}, [], []
    extenders = {k:Sequence() for k in (1,2,3)}
    for event in events:
        when,value,aux,detail,seq,size,kind,stream,flags,reserved = event
        if kind in (1,2) and flags & 127 != 97:
            continue
        if kind == 1:
            index = extenders[kind].extend(seq)
            received.setdefault(index,[]).append((when,size))
        elif kind == 2:
            index = extenders[kind].extend(seq)
            ingested.setdefault(index,[]).append((when,flags))
        elif kind == 3:
            playout.append((when,extenders[kind].extend(seq),value))
        elif kind == 14:
            resyncs.append(when)
    classified, delays, slack, accepted_wait = Counter(), [], [], []
    examples, played_before, replayed = [], set(), 0
    for when,seq,status in playout:
        if seq in played_before:
            replayed += 1
        played_before.add(seq)
        copies = received.get(seq,[])
        first = copies[0][0] if copies else None
        accepted = [t for t,flags in ingested.get(seq,[]) if flags & 0x100 and not flags & 0x400 and t<=when]
        if status != 4:
            if first is not None and first<=when:
                slack.append(when-first)
            continue
        if first is None:
            label = 'no_receive_record'
        elif first>when:
            label = 'first_received_after_playout'
            delays.append(first-when)
        elif accepted:
            i = bisect_right(resyncs,when)-1
            label = 'accepted_then_timeline_reset' if i>=0 and accepted[-1]<resyncs[i] else 'received_and_accepted_before_playout'
            accepted_wait.append(when-accepted[-1])
        else:
            label = 'received_but_not_accepted_before_playout'
        classified[label] += 1
        if len(examples)<20:
            examples.append(dict(time_us=when,extended_sequence=seq,classification=label,
                                 first_receive_us=first))
    late_unique = sum(any(flags & 0x200 for _,flags in records) for records in ingested.values())
    statuses = Counter(status for _,_,status in playout)
    result = dict(unique_received=len(received), received_copies=sum(map(len,received.values())),
                  observed_playout_frames=len(playout), repeated_playout_sequences=replayed,
                  playout_status=dict(statuses), plc_classification=dict(classified),
                  plc_first_arrival_lateness_us=distribution(delays),
                  successful_receive_to_playout_us=distribution(slack),
                  plc_previously_accepted_wait_us=distribution(accepted_wait),
                  sequences_with_a_late_discard=late_unique, timeline_resyncs=len(resyncs),
                  plc_examples=examples,
                  note='No-receive-record includes capture loss and boundaries. Received/accepted before PLC requires further state analysis; it is not a proven implementation defect.')
    return received, playout, result


def join_sender(segment, received, frame_us=5000):
    sent = segment['packets']
    first_key,last_key = min(sent),max(sent)
    first_host,last_host = sent[first_key][0],sent[last_key][0]
    paired = [(seq,sent[seq][0],copies[0][0],len(copies)) for seq,copies in received.items() if seq in sent]
    if not paired:
        raise ValueError('no matching sender/receiver sequences')
    paired.sort()
    host_start = segment['first_us']
    # This is a relative clock/path origin, NOT absolute one-way latency.
    offset = min(rx-(tx-host_start) for _,tx,rx,_ in paired)
    residuals = [rx-(tx-host_start)-offset for _,tx,rx,_ in paired]
    windows = []
    for start in range(0,int((last_host-first_host)/1e6),10):
        selected = [(seq,t) for seq,(t,size) in sent.items()
                    if first_host+start*1000000<=t<first_host+(start+10)*1000000]
        if len(selected)<2:
            continue
        a,b = selected[0],selected[-1]
        windows.append(dict(start_second=start,packets=len(selected),
                            wall_span_ms=(b[1]-a[1])/1000,
                            media_span_ms=(b[0]-a[0])*frame_us/1000))
    # Counterfactual: reference each deadline to the actual sender pacing. The
    # client does not currently have this oracle; this only budgets receive jitter.
    first_seq,_,first_rx,_ = paired[0]
    budgets = []
    for budget_ms in (20,50,100,150,200,300,450,600):
        paced_late = sum(rx>(tx-host_start)+offset+budget_ms*1000 for seq,tx,rx,_ in paired)
        fixed_late = sum(rx>first_rx+(seq-first_seq)*frame_us+budget_ms*1000 for seq,tx,rx,_ in paired)
        budgets.append(dict(window_ms=budget_ms,paired_sequences=len(paired),
                            late_against_sender_pacing_reference=paced_late,
                            late_against_fixed_5ms_rtp_reference=fixed_late))
    # Only count the observed interior, so the still-running sender tail does not
    # manufacture receiver losses. Send-attempt log does not record syscall success.
    lo,hi = paired[0][0],paired[-1][0]
    not_received = sum(lo<=seq<=hi and seq not in received for seq in sent)
    return dict(sender_original_attempts=len(sent), sequence_holes=max(sent)-min(sent)+1-len(sent),
                sender_wall_seconds=(last_host-first_host)/1e6,
                sender_media_seconds=(last_key-first_key)*frame_us/1e6,
                matched_sequences=len(paired), sent_attempts_without_receive_record_in_interior=not_received,
                relative_receive_delay_us=distribution(residuals), ten_second_sender_windows=windows,
                arrival_patterns=arrival_patterns(paired,offset,host_start),
                counterfactual_deadline_budgets=budgets,
                caveat='Sender timestamps precede the original send syscall; successful delivery is not recorded. Relative receive delay uses a minimum observed clock/path origin, assumes equal clock rates, and is not synchronized one-way latency. Buffer models omit FEC, output pacing, clock recovery and perceptual quality.')


def diagnose(directory, host_log=None, capture_info=None, host_segment=None):
    events,quality = load_audio(directory)
    received,playout,metrics = receiver_metrics(events)
    result = dict(session=Path(directory).name, capture=quality, receiver=metrics)
    if host_log:
        segments = host_segments(host_log)
        if host_segment is None:
            if capture_info is None:
                raise ValueError('automatic session selection needs capture-info')
            info = json.loads(Path(capture_info).read_text())
            manifest = json.loads((Path(directory)/'manifest.json').read_text())
            wall = datetime.fromisoformat(manifest['started_at'].replace('Z','+00:00')).timestamp()
            predicted = info['host_monotonic_us']+(wall-info['wall_time'])*1e6
            ranked = sorted((abs(s['first_us']-predicted),i) for i,s in enumerate(segments))
            if not ranked or ranked[0][0]>120000000 or (len(ranked)>1 and ranked[1][0]-ranked[0][0]<30000000):
                raise ValueError('ambiguous host session; select --host-segment explicitly')
            host_segment = ranked[0][1]
        result['host_segment'] = host_segment
        result['sender_receiver'] = join_sender(segments[host_segment],received)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session',type=Path)
    parser.add_argument('--host-log',type=Path)
    parser.add_argument('--capture-info',type=Path)
    parser.add_argument('--host-segment',type=int)
    parser.add_argument('--output',type=Path)
    args = parser.parse_args()
    report = diagnose(args.session,args.host_log,args.capture_info,args.host_segment)
    text = json.dumps(report,indent=2)
    if args.output:
        args.output.write_text(text+'\n')
    else:
        print(text)
