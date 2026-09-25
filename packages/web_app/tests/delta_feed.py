#!/usr/bin/env python3
"""Hermetic WS regression: python3 packages/web_app/tests/delta_feed.py.

Run after mise run web-app. Uses a temporary Unix daemon, an ephemeral loopback
port, finite socket/queue deadlines, and terminates only its own gateway.
"""
import base64
import contextlib
import http.client
import json
import os
from pathlib import Path
import queue
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time

TARGET = {"runtime_id": "a" * 32, "instance_id": "b" * 32}
CAPABILITY = "core.changes.delta.v1"


def read_exact(stream, size):
    data = stream.read(size)
    assert len(data) == size, "unexpected EOF"
    return data


class WebSocket:
    def __init__(self, port, token):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.stream = self.socket.makefile("rb")
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall((f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                             f"Authorization: Bearer {token}\r\nUpgrade: websocket\r\n"
                             f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                             "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        assert b"101" in self.stream.readline()
        while True:
            header = self.stream.readline()
            assert header, "EOF in upgrade headers"
            if header == b"\r\n":
                break

    def receive(self):
        opcode, length = read_exact(self.stream, 2)
        assert opcode == 0x81, (opcode, length)
        assert not length & 0x80
        if length == 126:
            length = struct.unpack("!H", read_exact(self.stream, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read_exact(self.stream, 8))[0]
        return json.loads(read_exact(self.stream, length))

    def send(self, method, params, request_id=11, target=TARGET):
        request = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        if target is not None:
            request["target"] = target
        data = json.dumps(request, separators=(",", ":")).encode()
        mask = os.urandom(4)
        length = bytes([len(data) | 0x80]) if len(data) < 126 else b"\xfe" + struct.pack("!H", len(data))
        self.socket.sendall(b"\x81" + length + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def close(self):
        self.socket.close()
        self.stream.close()


class Fixture:
    def __init__(self, directory):
        self.polls = queue.Queue()
        self.replies = queue.Queue()
        self.nonce = "nonce-a"
        self.snapshot_cursor = 100
        self.snapshots = 0
        self.errors = queue.Queue()
        fixture = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                self.request.settimeout(5)
                try:
                    request = json.loads(self.rfile.readline())
                    method = request["method"]
                    if method in ("core.status", "core.capabilities"):
                        result = {**TARGET, "runtime_capabilities": ["rpc.target.v1"],
                                  "mobile": {"min_client": 1}, "future": "preserved"}
                    elif method == "core.snapshot":
                        fixture.snapshots += 1
                        result = {"snapshot": {}, "store_revision": 1,
                                  "change_cursor": fixture.snapshot_cursor,
                                  "envelope": {"instance_nonce": fixture.nonce}}
                    elif method == "core.changes":
                        fixture.polls.put(request["params"].get("cursor"))
                        result = fixture.replies.get(timeout=5)
                        if result is None:
                            return
                    else:
                        raise AssertionError(f"unexpected daemon RPC {method}")
                    self.wfile.write(json.dumps({"jsonrpc": "2.0", "id": request["id"], "ok": True, "result": result},
                                                separators=(",", ":")).encode() + b"\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as error:
                    fixture.errors.put(error)

        self.server = socketserver.ThreadingUnixStreamServer(str(directory / "daemon.sock"), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": .05})
        self.thread.start()

    def reply(self, cursor, *, expired=False, heartbeat=False):
        self.replies.put({"entries": [] if heartbeat or expired else [{"change_seq": cursor, "topic": "workspace", "resource_id": "w1"}],
                          "next_cursor": cursor, "expired": expired, "heartbeat": heartbeat,
                          "envelope": {"instance_nonce": self.nonce}})

    def close(self):
        self.replies.put(None)
        self.server.shutdown()
        self.thread.join(timeout=5)
        self.server.server_close()
        assert not self.thread.is_alive()
        if not self.errors.empty():
            raise self.errors.get()


@contextlib.contextmanager
def gateway():
    binary = Path(__file__).resolve().parents[1] / "zig-out/bin/verde-web"
    with tempfile.TemporaryDirectory(prefix="verde-a11-") as temp:
        directory = Path(temp)
        fixture = Fixture(directory)
        token = base64.b64encode(os.urandom(32)).decode()
        token_file = directory / "token"
        token_file.write_text(token)
        token_file.chmod(0o600)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        with (directory / "gateway.log").open("wb") as log:
            process = subprocess.Popen([str(binary), "--host", "127.0.0.1", "--port", str(port),
                                        "--token-file", str(token_file), "--sessionizer", str(directory / "daemon.sock"),
                                        "--pref-path", str(directory)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                while True:
                    assert process.poll() is None, (directory / "gateway.log").read_text()
                    try:
                        connection = socket.create_connection(("127.0.0.1", port), timeout=.1)
                        connection.close()
                        break
                    except OSError:
                        assert time.monotonic() < deadline, "gateway startup deadline"
                        time.sleep(.02)
                ws = WebSocket(port, token)
                try:
                    hello = ws.receive()
                    assert hello["method"] == "core.hello"
                    status = hello["params"]["status_envelope"]["result"]
                    assert CAPABILITY in status["runtime_capabilities"]
                    assert status["future"] == "preserved"
                    assert ws.receive()["method"] == "core.snapshot"
                    yield fixture, ws, port, token
                finally:
                    ws.close()
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                fixture.close()


def test_delta():
    with gateway() as (fixture, ws, port, token):
        assert fixture.polls.get(timeout=5) is None
        # Opt-in while the legacy poll is parked: its eventual reply must not
        # overwrite the requested cursor or produce a post-ack snapshot.
        ws.send("core.changes.mode", {"mode": "delta", "cursor": 7})
        ack = ws.receive()
        assert ack["id"] == 11 and ack["result"] == {"mode": "delta", "cursor": 7}
        fixture.reply(101)
        assert fixture.polls.get(timeout=5) == 7
        fixture.reply(8)
        assert ws.receive()["method"] == "core.changes"
        assert fixture.polls.get(timeout=5) == 8
        assert fixture.snapshots == 1

        fixture.snapshot_cursor = 2**63 + 150
        fixture.reply(120, expired=True)
        assert ws.receive()["method"] == "core.changes"
        assert ws.receive()["params"]["result"]["change_cursor"] == 2**63 + 150
        assert fixture.polls.get(timeout=5) == 2**63 + 150
        assert fixture.snapshots == 2

        fixture.nonce = "nonce-b"
        fixture.snapshot_cursor = 200
        fixture.reply(160, heartbeat=True)
        assert ws.receive()["method"] == "core.changes"
        assert ws.receive()["method"] == "core.snapshot"
        assert fixture.polls.get(timeout=5) == 200
        fixture.reply(201, heartbeat=True)
        assert ws.receive()["method"] == "core.changes"
        assert fixture.polls.get(timeout=5) == 201
        assert fixture.snapshots == 3

        ws.send("core.changes.mode", {"mode": "delta", "cursor": -1}, request_id=12)
        assert ws.receive()["error"]["code"] == "invalid_params"
        ws.send("core.changes.mode", {"mode": "delta"}, request_id=13, target={**TARGET, "instance_id": "c" * 32})
        assert ws.receive()["error"]["code"] == "runtime_identity_mismatch"
        ws.send("core.changes.mode", {"mode": "delta", "cursor": "7"}, request_id=16)
        assert ws.receive()["error"]["code"] == "invalid_params"
        ws.send("core.changes.mode", {"mode": "delta"}, request_id=17, target=None)
        assert ws.receive()["error"]["code"] == "runtime_identity_missing"
        ws.send("core.capabilities", {}, request_id=14)
        assert CAPABILITY in ws.receive()["result"]["runtime_capabilities"]
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        try:
            connection.request("POST", "/api/rpc", json.dumps({"jsonrpc": "2.0", "id": 15, "method": "core.capabilities", "params": {}, "target": TARGET}),
                         {"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
            response = connection.getresponse()
            assert response.status == 200
            assert CAPABILITY in json.load(response)["result"]["runtime_capabilities"]
        finally:
            connection.close()


def test_legacy():
    with gateway() as (fixture, ws, _, _):
        assert fixture.polls.get(timeout=5) is None
        fixture.reply(101)
        assert ws.receive()["method"] == "core.changes"
        assert ws.receive()["method"] == "core.snapshot"
        assert fixture.polls.get(timeout=5) == 101
        fixture.reply(102, heartbeat=True)
        assert ws.receive()["method"] == "core.changes"
        assert fixture.polls.get(timeout=5) == 102
        assert fixture.snapshots == 2
        fixture.reply(103, expired=True)
        assert ws.receive()["method"] == "core.changes"
        assert ws.receive()["method"] == "core.snapshot"
        assert fixture.polls.get(timeout=5) == 103
        assert fixture.snapshots == 3


if __name__ == "__main__":
    test_delta()
    test_legacy()
    print("PASS: delta/resume, stale poll, expiry/nonce resync, capability forwarding, legacy snapshots")
