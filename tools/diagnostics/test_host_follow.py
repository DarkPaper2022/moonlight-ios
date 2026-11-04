import gzip
import json
from pathlib import Path
import tempfile
import unittest
from host_follow import parse_line,flush


class SenderMetadataTests(unittest.TestCase):
    def test_ignores_unneeded_hashes_and_keeps_only_metadata(self):
        row=parse_line('12345 EV=ORIG seq=4 len=348 h=abcdef01 (sendmsg)')
        self.assertEqual(row,dict(monotonic_us=12345,kind='ORIG',sequence=4,bytes=348))
        self.assertEqual(parse_line('12346 EV=DUP seq=4 len=348 wake_delay_us=71')['wake_delay_us'],71)
        self.assertIsNone(parse_line('-- LOG WRAPPED --'))

    def test_complete_gzip_chunks_and_owned_data_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            original=root/'unrelated.log';original.write_text('preserve')
            rows=[dict(monotonic_us=123,kind='ORIG',sequence=1)]
            flush(root,rows)
            self.assertEqual(rows,[])
            files=list(root.glob('*.host.jsonl.gz'))
            self.assertEqual(len(files),1)
            self.assertEqual(json.loads(gzip.decompress(files[0].read_bytes())),dict(monotonic_us=123,kind='ORIG',sequence=1))
            self.assertEqual(original.read_text(),'preserve')
