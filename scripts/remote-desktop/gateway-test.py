#!/usr/bin/env python3
"""Hermetic desktop gateway integration: no real daemon, VNC, or user state."""
import base64
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = Path(__file__).resolve().parents[2] / 'packages/web_app/zig-out/bin/verde-web'


def receive(sock, count):
    data = b''
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part:
            raise EOFError('peer closed')
        data += part
    return data


def send_frame(sock, payload, opcode=2):
    mask = b'\x13\x24\x35\x46'
    length = len(payload)
    header = bytes([0x80 | opcode])
    if length < 126:
        header += bytes([0x80 | length])
    elif length <= 65535:
        header += bytes([0x80 | 126]) + struct.pack('!H', length)
    else:
        header += bytes([0x80 | 127]) + struct.pack('!Q', length)
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def read_frame(sock):
    first, second = receive(sock, 2)
    if second & 0x80:
        raise AssertionError('server frame is masked')
    length = second & 0x7f
    if length == 126:
        length = struct.unpack('!H', receive(sock, 2))[0]
    elif length == 127:
        length = struct.unpack('!Q', receive(sock, 8))[0]
    return first & 15, receive(sock, length)


class GatewayDesktopTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='verde-desktop-test-')
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        root.chmod(0o700)
        self.backend = socket.socket(socket.AF_UNIX)
        self.backend.settimeout(3)
        self.backend.bind(str(root / 'vnc.sock'))
        (root / 'vnc.sock').chmod(0o600)
        self.backend.listen(2)
        self.addCleanup(self.backend.close)
        self.token = secrets.token_hex(32)
        token_path = root / 'token'
        token_path.write_text(self.token)
        token_path.chmod(0o600)
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0))
            self.port = reserve.getsockname()[1]
        self.origin = f'http://127.0.0.1:{self.port}'
        env = {key: value for key, value in os.environ.items() if not key.startswith('VERDE_')}
        self.process = subprocess.Popen([
            str(BINARY), '--token-file', str(token_path), '--port', str(self.port),
            '--pref-path', str(root), '--sessionizer', str(root / 'absent-daemon.sock'),
            '--desktop-socket', str(root / 'vnc.sock'), '--static', str(BINARY.parents[2] / 'dist'),
        ], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(self.stop)
        deadline = time.monotonic() + 5
        while True:
            try:
                status, _, _ = self.http('GET', '/healthz')
                self.assertEqual(status, 200)
                break
            except OSError:
                if self.process.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError('fixture gateway did not start')
                time.sleep(0.025)
        status, headers, _ = self.http('POST', '/auth/session', json.dumps({'token': self.token}),
                                     {'Content-Type': 'application/json', 'Origin': self.origin})
        self.assertEqual(status, 200)
        self.cookie = headers['set-cookie'].split(';', 1)[0]

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.communicate(timeout=3)
            raise AssertionError('fixture gateway did not stop')

    def http(self, method, path, body=None, headers=None):
        client = http.client.HTTPConnection('127.0.0.1', self.port, timeout=3)
        try:
            client.request(method, path, body, headers or {})
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            client.close()

    def upgrade(self, *, path='/ws/desktop', authenticated=True, origin=None):
        peer = socket.create_connection(('127.0.0.1', self.port), timeout=3)
        self.addCleanup(peer.close)
        headers = [f'GET {path} HTTP/1.1', f'Host: 127.0.0.1:{self.port}',
                   'Upgrade: websocket', 'Connection: Upgrade', 'Sec-WebSocket-Version: 13',
                   'Sec-WebSocket-Key: ' + base64.b64encode(secrets.token_bytes(16)).decode(),
                   'Origin: ' + (origin or self.origin)]
        if authenticated:
            headers.append('Cookie: ' + self.cookie)
        peer.sendall(('\r\n'.join(headers) + '\r\n\r\n').encode())
        head = b''
        while not head.endswith(b'\r\n\r\n'):
            head += receive(peer, 1)
            self.assertLess(len(head), 8192)
        return peer, int(head.split(b' ')[1])

    def test_authorization_origin_and_exact_route_before_backend_connect(self):
        self.assertEqual(self.http('GET', '/api/desktop')[0], 401)
        status, _, body = self.http('GET', '/api/desktop', headers={'Cookie': self.cookie})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {'enabled': True, 'target': 'gateway_host'})
        for options, expected in [({'authenticated': False}, 401),
                                  ({'origin': 'https://untrusted.example'}, 403),
                                  ({'path': '/ws/desktop?token=x'}, 400),
                                  ({'path': '/ws/desktop/'}, 404)]:
            peer, status = self.upgrade(**options)
            self.assertEqual(status, expected)
            peer.close()
        self.backend.settimeout(0.1)
        with self.assertRaises(socket.timeout):
            self.backend.accept()

    def test_binary_relay_ping_exclusion_and_reconnect(self):
        peer, status = self.upgrade()
        self.assertEqual(status, 101)
        backend, _ = self.backend.accept()
        backend.settimeout(3)
        self.addCleanup(backend.close)
        # A short banner must flush immediately; do not wait for a full buffer.
        backend.sendall(b'RFB 003.008\n')
        self.assertEqual(read_frame(peer), (2, b'RFB 003.008\n'))
        payload = bytes(range(256)) * 1000
        send_frame(peer, payload)
        self.assertEqual(receive(backend, len(payload)), payload)
        send_frame(peer, b'ping', 9)
        self.assertEqual(read_frame(peer), (10, b'ping'))
        second, status = self.upgrade()
        self.assertEqual(status, 409)
        second.close()
        # Backend EOF must cancel the browser reader and release the session slot.
        backend.close()
        self.assertEqual(peer.recv(1), b'')
        peer.close()
        next_peer, status = self.upgrade()
        self.assertEqual(status, 101)
        next_backend, _ = self.backend.accept()
        next_backend.settimeout(3)
        self.addCleanup(next_backend.close)
        next_peer.close()
        self.assertEqual(next_backend.recv(1), b'')

    def test_text_frame_rejected_and_private_socket_required(self):
        peer, status = self.upgrade()
        self.assertEqual(status, 101)
        backend, _ = self.backend.accept()
        backend.settimeout(3)
        self.addCleanup(backend.close)
        send_frame(peer, b'not RFB', 1)
        self.assertEqual(peer.recv(1), b'')
        self.assertEqual(backend.recv(1), b'')
        (Path(self.temp.name) / 'vnc.sock').chmod(0o666)
        rejected, status = self.upgrade()
        self.assertEqual(status, 503)
        rejected.close()


if __name__ == '__main__':
    unittest.main()
