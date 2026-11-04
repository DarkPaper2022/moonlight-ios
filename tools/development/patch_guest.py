#!/usr/bin/env python3
"""Apply the thin arm64 guest transformations from LiveContainer LCPatchExecSlice.

Run BEFORE signing; never use this to re-sign/reinstall a LiveContainer host.
"""
import argparse
from pathlib import Path
import struct


def patch(path):
    data = bytearray(Path(path).read_bytes())
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from('<8I', data)
    if magic != 0xfeedfacf or cpu != 0x100000c or kind not in (2, 6):
        raise ValueError('expected a thin arm64 executable or patched dylib')
    cursor, text_offset, names = 32, None, set()
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, cursor)
        if length < 8 or cursor + length > 32 + size:
            raise ValueError('invalid load command')
        if cmd == 0x19:
            name = bytes(data[cursor+8:cursor+24]).rstrip(b'\0')
            vmaddr, vmsize = struct.unpack_from('<QQ', data, cursor+24)
            if name == b'__PAGEZERO' and vmaddr == 0:
                struct.pack_into('<QQ', data, cursor+24, 0x100000000-0x4000, 0x4000)
            sections = struct.unpack_from('<I', data, cursor+64)[0]
            for index in range(sections):
                section = cursor + 72 + index*80
                if bytes(data[section:section+16]).rstrip(b'\0') == b'__text':
                    text_offset = struct.unpack_from('<I',data,section+48)[0]
        if cmd in (0xd, 0xc):
            offset = struct.unpack_from('<I', data, cursor+8)[0]
            name = bytes(data[cursor+offset:cursor+length]).split(b'\0')[0]
            names.add((cmd, name))
        cursor += length
    if cursor != size+32 or text_offset is None:
        raise ValueError('missing text section or invalid command size')
    commands = []
    for cmd, name in ((0xd, Path(path).name.encode()), (0xc,b'@loader_path/../../Tweaks/TweakLoader.dylib')):
        if (cmd, name) in names:
            continue
        length = (24 + len(name) + 1 + 7) & ~7
        command = struct.pack('<6I', cmd, length, 24, 0, 0, 0) + name + b'\0'
        commands.append(command.ljust(length, b'\0'))
    extra = b''.join(commands)
    # Leave room for lc_zsign to append a missing LC_CODE_SIGNATURE command.
    if cursor + len(extra) + 16 > text_offset or any(data[cursor:cursor+len(extra)]):
        raise ValueError('insufficient zero-filled load-command padding')
    data[cursor:cursor+len(extra)] = extra
    struct.pack_into('<I', data, 12, 6)
    struct.pack_into('<III',data,16,count+len(commands),size+len(extra),(flags|0x100000)&~0x200000)
    Path(path).write_bytes(data)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('executable', type=Path)
    patch(parser.parse_args().executable)
