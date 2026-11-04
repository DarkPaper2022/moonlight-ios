#!/usr/bin/env python3
"""Authenticated, bounded loopback receiver behind the existing HTTPS gateway."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from protocol import decode_batch, MAX_COMPRESSED

ROUTE = re.compile(r'/moonlight-diagnostics/v1/sessions/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})/(manifest|batches/([0-9]{10}))$')


class TraceServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 8

    def __init__(self, address, root, token, quota=1024**3, days=7):
        super().__init__(address, Handler)
        self.root, self.token, self.quota, self.days = Path(root), token, quota, days
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.storage_lock = threading.Lock()
        self.slots = threading.BoundedSemaphore(8)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def prune(self, needed):
        files = sorted((p for p in self.root.glob('*/*') if p.is_file()), key=lambda p: p.stat().st_mtime)
        used = sum(p.stat().st_size for p in files)
        expiry = time.time() - self.days * 86400
        for path in files:
            stat = path.stat()
            if used + needed <= self.quota and stat.st_mtime >= expiry:
                break
            used -= stat.st_size
            path.unlink()
        return used + needed <= self.quota


class Handler(BaseHTTPRequestHandler):
    server_version = 'MoonlightTrace/1'

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, format, *args):
        # Never log Authorization, URIs, device addresses, or manifest contents.
        pass

    def reply(self, code, **body):
        data = json.dumps(body, separators=(',', ':')).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == '/moonlight-diagnostics/v1/health':
            self.reply(200, status='ready', schema=1)
        else:
            self.reply(404, error='not found')

    def do_POST(self):
        if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + self.server.token):
            self.reply(401, error='unauthorized')
            return
        route = ROUTE.fullmatch(self.path)
        if not route:
            self.reply(404, error='not found')
            return
        if self.headers.get('Transfer-Encoding'):
            self.reply(400, error='Content-Length required')
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            length = 0
        if not 0 < length <= MAX_COMPRESSED:
            self.reply(413, error='body limit')
            return
        try:
            body = self.rfile.read(length)
            if len(body) != length:
                raise ValueError('incomplete body')
            session, item, batch = route.groups()
            if item == 'manifest':
                if length > 16384:
                    raise ValueError('manifest limit')
                manifest = json.loads(body)
                if manifest.get('session') != session or manifest.get('schema') != 1 or manifest.get('record_bytes') != 32:
                    raise ValueError('invalid manifest')
                name = 'manifest.json'
            else:
                if self.headers.get('Content-Encoding') != 'gzip':
                    raise ValueError('gzip required')
                decode_batch(body)
                name = batch + '.mtrace.gz'
        except (ValueError, TypeError, AttributeError, UnicodeError):
            self.reply(400, error='invalid trace')
            return
        digest = hashlib.sha256(body).hexdigest()
        with self.server.storage_lock:
            directory = self.server.root / session
            path = directory / name
            if path.exists():
                if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                    self.reply(409, error='batch already has different contents')
                else:
                    self.reply(200, sha256=digest, duplicate=True)
                return
            if not self.server.prune(length):
                self.reply(507, error='storage limit')
                return
            directory.mkdir(mode=0o700, exist_ok=True)
            temporary = path.with_suffix(path.suffix + '.partial')
            with temporary.open('wb') as output:
                os.chmod(temporary, 0o600)
                output.write(body)
            temporary.replace(path)
        self.reply(201, sha256=digest, bytes=length)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--token-file', type=Path, required=True)
    parser.add_argument('--port', type=int, default=21847)
    args = parser.parse_args()
    os.umask(0o077)
    token = args.token_file.read_text().strip()
    if len(token) < 32:
        parser.error('token must contain at least 32 characters')
    TraceServer(('127.0.0.1', args.port), args.root, token).serve_forever()
