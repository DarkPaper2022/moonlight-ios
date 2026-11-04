"""Moonlight metadata-only trace, schema 1. No audio/video/input payloads."""
import gzip
import io
import struct

HEADER = struct.Struct('<8sIIIIQ')
EVENT = struct.Struct('<QIIIHHBBHI')
MAX_COMPRESSED = 3 * 1024 * 1024
MAX_RAW = HEADER.size + 65536 * EVENT.size
KINDS = {1: 'audio_rx', 2: 'audio_ingest', 3: 'audio_playout', 4: 'video_rx',
         5: 'video_drop', 6: 'audio_output', 7: 'session', 8: 'timeout',
         9: 'decode_error', 10: 'route', 11: 'video_frame', 12: 'network_path',
         13: 'marker', 14: 'audio_resync'}


def decode_batch(data):
    if len(data) > MAX_COMPRESSED:
        raise ValueError('compressed limit exceeded')
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(data)) as zipped:
            raw = zipped.read(MAX_RAW + 1)
    except (OSError, EOFError) as error:
        raise ValueError('invalid gzip') from error
    if len(raw) < HEADER.size or len(raw) > MAX_RAW:
        raise ValueError('raw size outside limit')
    magic, version, record_bytes, count, reserved, dropped = HEADER.unpack_from(raw)
    if (magic, version, record_bytes, reserved) != (b'MLTRACE1', 1, EVENT.size, 0):
        raise ValueError('unsupported trace header')
    if len(raw) != HEADER.size + count * EVENT.size:
        raise ValueError('record count mismatch')
    records = list(EVENT.iter_unpack(raw[HEADER.size:]))
    if any(e[6] not in KINDS or e[7] not in (1, 2, 3) for e in records):
        raise ValueError('invalid event kind or stream')
    return dropped, records
