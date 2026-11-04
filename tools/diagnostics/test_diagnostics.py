import gzip
from http.client import HTTPConnection
import json
from pathlib import Path
import tempfile
import threading
import unittest
from protocol import decode_batch, HEADER, EVENT, MAX_RAW
from receiver import TraceServer
from analyze import analyze, missing_batches, plc_bursts

SESSION = '00000000-0000-0000-0000-000000000001'
PREFIX = '/moonlight-diagnostics/v1/sessions/' + SESSION


def batch(sequences=(65534, 0, 65535, 0, 2), dropped=3, start=100000):
    events = [EVENT.pack(start + i*5000, 0, 0, 0, seq, 120, 1, 1, 97, 0) for i, seq in enumerate(sequences)]
    return gzip.compress(HEADER.pack(b'MLTRACE1', 1, 32, len(events), 0, dropped) + b''.join(events))


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.server = TraceServer(('127.0.0.1', 0), self.directory.name, 'x'*64)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def post(self, path, data, token='x'*64, encoding='gzip'):
        connection = HTTPConnection(*self.server.server_address, timeout=3)
        connection.request('POST', PREFIX + path, data,
                           {'Authorization':'Bearer '+token,'Content-Encoding':encoding})
        response = connection.getresponse()
        status, body = response.status, response.read()
        connection.close()
        return status, json.loads(body)

    def test_health_through_http(self):
        connection = HTTPConnection(*self.server.server_address, timeout=3)
        connection.request('GET', '/moonlight-diagnostics/v1/health')
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(response.read())['status'], 'ready')
        connection.close()

    def test_auth_validation_and_idempotence(self):
        self.assertEqual(self.post('/batches/0000000000', batch(), token='bad')[0], 401)
        self.assertEqual(self.post('/batches/0000000000', b'bad')[0], 400)
        self.assertEqual(self.post('/../../bad', batch())[0], 404)
        self.assertEqual(self.post('/batches/0000000000', batch())[0], 201)
        self.assertEqual(self.post('/batches/0000000000', batch())[0], 200)
        self.assertEqual(self.post('/batches/0000000000', batch((10,)))[0], 409)
        self.assertEqual(self.post('/manifest', json.dumps(dict(session=SESSION,schema=1,record_bytes=32)).encode())[0], 201)

    def test_bounded_decompression_and_quota(self):
        with self.assertRaises(ValueError):
            decode_batch(gzip.compress(b'0'*(MAX_RAW+1)))
        corrupt = gzip.compress(HEADER.pack(b'MLTRACE1',1,32,100,0,0))
        self.assertEqual(self.post('/batches/0000000000',corrupt)[0],400)
        self.server.quota = 10
        self.assertEqual(self.post('/batches/0000000000',batch())[0],507)
        self.assertEqual(list(Path(self.directory.name).glob('*/*')), [])

    def test_wrap_reorder_and_capture_loss_remain_distinct(self):
        self.assertEqual(self.post('/batches/0000000000',batch())[0],201)
        self.assertEqual(self.post('/batches/0000000002',batch((3,4), start=150000))[0],201)
        report = analyze(Path(self.directory.name)/SESSION)
        self.assertEqual(report['trace_dropped_records'],3)
        self.assertEqual(report['missing_trace_batches'],[1])
        self.assertEqual(report['audio']['duplicates'],1)
        self.assertEqual(report['audio']['reordered'],1)
        self.assertEqual(report['audio']['unresolved_sequence_holes'],1)

    def test_bounded_batch_gaps_and_wrapped_plc_burst(self):
        count, sample = missing_batches([0, 9999999999])
        self.assertEqual(count,9999999998)
        self.assertEqual(len(sample),1000)
        events = [(i*5000, status, 0, 0, seq, 0, 3, 1, 0, 0)
                  for i, (seq,status) in enumerate([(65535,4),(0,4),(1,1),(2,4)])]
        bursts = plc_bursts(events)
        self.assertEqual(bursts['count'],2)
        self.assertEqual(bursts['largest'][0]['frames'],2)


if __name__ == '__main__':
    unittest.main()
