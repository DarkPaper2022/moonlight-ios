#!/usr/bin/env python3
"""USB-only development control. Token is read from a private file, never argv."""
import argparse
import json
from pathlib import Path
import time
import urllib.request


def request(token_file, path, method='GET', port=9537):
    token = Path(token_file).read_text().strip()
    req = urllib.request.Request(f'http://127.0.0.1:{port}'+path, method=method,
                                 headers={'Authorization':'Bearer '+token})
    with urllib.request.urlopen(req, timeout=8) as response:
        return json.load(response)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--token-file', type=Path, required=True)
    parser.add_argument('--port', type=int, default=9537)
    parser.add_argument('action', choices=['status','ui','activate','resume','pause-output','rebuild','observe'])
    parser.add_argument('value', nargs='?')
    parser.add_argument('--seconds', type=int, default=190)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.action == 'observe':
        if not args.output:
            parser.error('observe requires --output (persistent JSONL)')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        deadline = time.monotonic() + args.seconds
        with args.output.open('a') as output:
            while time.monotonic() < deadline:
                try:
                    state = request(args.token_file, '/status', port=args.port)
                except Exception as error:
                    state = {'error':str(error)}
                state['observed_wall_time'] = time.time()
                output.write(json.dumps(state,separators=(',',':'))+'\n')
                output.flush()
                time.sleep(2)
    else:
        if args.action == 'activate':
            if not args.value or not args.value.isdigit():
                parser.error('activate requires a control id from the latest ui response')
            path, method = '/ui/activate/'+args.value, 'POST'
        elif args.action == 'resume':
            path, method = '/stream/resume', 'POST'
        elif args.action in ('pause-output','rebuild'):
            path, method = '/audio/'+args.action, 'POST'
        else:
            path, method = '/'+args.action, 'GET'
        print(json.dumps(request(args.token_file,path,method,args.port),ensure_ascii=False,indent=2))
