#!/usr/bin/env python3
"""Export actual ingest/playout metadata for a bounded, media-free C replay."""
import argparse
from pathlib import Path
from diagnose import load_audio

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session',type=Path)
    parser.add_argument('output',type=Path)
    args = parser.parse_args()
    events,quality=load_audio(args.session)
    with args.output.open('w') as output:
        for e in events:
            if e[6]==2 and e[8]&127==97:
                output.write(f'R {e[0]} {e[4]} {e[1]}\n')
            elif e[6]==3:
                output.write(f'P {e[0]} {e[4]} {e[1]}\n')
    print(quality)
