#!/usr/bin/env python3
"""Passively retain sanitized metadata from an already-running sender logger."""
import argparse
from datetime import datetime, timezone
import gzip
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import time

LINE=re.compile(r'^(\d+) EV=(ORIG|DUP|QFULL) seq=(\d+)(?: len=(\d+))?(?: wake_delay_us=(\d+))?')


def parse_line(line):
    match=LINE.match(line)
    if not match:return None
    when,kind,seq,size,wake=match.groups()
    result=dict(monotonic_us=int(when),kind=kind,sequence=int(seq))
    if size is not None:result['bytes']=int(size)
    if wake is not None:result['wake_delay_us']=int(wake)
    return result


def flush(root,rows):
    if not rows:return
    root.mkdir(parents=True,exist_ok=True,mode=0o700)
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')+'-'+str(time.time_ns())
    path=root/(stamp+'.host.jsonl.gz')
    temporary=path.with_suffix(path.suffix+'.partial')
    data=b''.join(json.dumps(row,separators=(',',':')).encode()+b'\n' for row in rows)
    temporary.write_bytes(gzip.compress(data,compresslevel=1))
    temporary.chmod(0o600);temporary.replace(path)
    rows.clear()
    files=sorted(root.glob('*.host.jsonl.gz'))
    used=sum(p.stat().st_size for p in files)
    expiry=time.time()-7*86400
    # Only this sidecar's generated metadata chunks may expire.
    for item in files:
        size=item.stat().st_size
        if used<=128*1024*1024 and item.stat().st_mtime>=expiry:break
        item.unlink();used-=size


def follow(source,output):
    running=True
    def stop(signum,frame):
        nonlocal running
        running=False
    signal.signal(signal.SIGTERM,stop)
    signal.signal(signal.SIGINT,stop)
    # GNU tail follows existing append/truncate behavior. No instrumentation,
    # attach, privileges, media capture, or writes to the source are involved.
    process=subprocess.Popen(['tail','-n','0','-F','-s','0.2',str(source)],stdout=subprocess.PIPE)
    pending=b'';rows=[];deadline=time.monotonic()+60
    try:
        while running:
            ready,_,_=select.select([process.stdout],[],[],1)
            if ready:
                data=os.read(process.stdout.fileno(),65536)
                if not data:raise RuntimeError('sender metadata reader exited')
                pending+=data
                while b'\n' in pending:
                    line,pending=pending.split(b'\n',1)
                    row=parse_line(line.decode(errors='replace'))
                    if row:rows.append(row)
            if time.monotonic()>=deadline or len(rows)>=100000:
                flush(output,rows);deadline=time.monotonic()+60
    finally:
        flush(output,rows)
        process.terminate() # Only the child tail process created above.
        process.wait(timeout=5)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    os.umask(0o077)
    follow(args.source,args.output)
