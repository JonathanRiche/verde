#!/usr/bin/env python3
"""Isolated browser smoke test with a synthetic RFB desktop, never user pixels.
Requires a built web app and agent-browser on PATH. Run under a browser lease.
"""
import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import threading
import time
import uuid

spec = importlib.util.spec_from_file_location('gateway_test', Path(__file__).with_name('gateway-test.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
session = 'verde-desktop-test-' + uuid.uuid4().hex[:10]
base_command = ['agent-browser', '--session', session]


def browser(*args, script=None):
    result = subprocess.run(base_command + list(args), input=script, text=True,
                            capture_output=True, timeout=30)
    if result.returncode:
        # Never echo a script which might contain a temporary authentication token.
        raise AssertionError('browser command failed: ' + result.stderr[:1500])
    return result.stdout


def button(name):
    browser('find', 'role', 'button', 'click', '--name', name, '--exact')


host = fixture.GatewayDesktopTest()
stop = threading.Event()
keys = []
errors = []
thread = None


def desktop():
    try:
        connection, _ = host.backend.accept()
        with connection:
            connection.settimeout(5)
            connection.sendall(b'RFB 003.008\n')
            assert fixture.receive(connection, 12) == b'RFB 003.008\n'
            connection.sendall(b'\x01\x01')  # Security: None, private test Unix socket.
            assert fixture.receive(connection, 1) == b'\x01'
            connection.sendall(b'\0\0\0\0')
            fixture.receive(connection, 1)  # Shared flag.
            title = b'Synthetic desktop - no host capture'
            pixel_format = struct.pack('!BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
            connection.sendall(struct.pack('!HH', 640, 360) + pixel_format + struct.pack('!I', len(title)) + title)
            sent = False
            connection.settimeout(0.25)
            while not stop.is_set():
                try:
                    kind = fixture.receive(connection, 1)[0]
                except socket.timeout:
                    continue
                if kind == 0:
                    fixture.receive(connection, 19)
                elif kind == 2:
                    data = fixture.receive(connection, 3)
                    fixture.receive(connection, struct.unpack('!H', data[1:])[0] * 4)
                elif kind == 3:
                    fixture.receive(connection, 9)
                    if not sent:
                        pixels = bytes(v for y in range(360) for x in range(640)
                                       for v in (50 + x // 8, 70 + y // 3, 25, 0))
                        connection.sendall(b'\0\0\0\1' + struct.pack('!HHHHi', 0, 0, 640, 360, 0) + pixels)
                        sent = True
                elif kind == 4:
                    keys.append(fixture.receive(connection, 7))
                elif kind == 5:
                    fixture.receive(connection, 5)
                elif kind == 6:
                    data = fixture.receive(connection, 7)
                    fixture.receive(connection, struct.unpack('!I', data[3:])[0])
                else:
                    raise AssertionError('unexpected synthetic RFB message')
    except (EOFError, ConnectionResetError, BrokenPipeError):
        pass
    except Exception as error:
        errors.append(repr(error))


try:
    host.setUp()
    thread = threading.Thread(target=desktop, name='synthetic-vnc')
    thread.start()
    browser('open', host.origin + '/login')
    # Pass the ephemeral test token over stdin, never process arguments or output.
    browser('eval', '--stdin', script='''(async () => {
      const response = await fetch('/auth/session', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({token:''' + json.dumps(host.token) + '''})});
      return response.ok;
    })()''')
    browser('open', host.origin + '/')
    button('Host desktop')
    browser('wait', '--text', 'Control starts paused.')
    button('Connect')
    browser('wait', '--text', 'Enable control')
    browser('wait', '--text', 'Synthetic desktop')
    browser('screenshot', '/tmp/verde-desktop-review.png')
    button('Enable control')
    browser('press', 'a')
    deadline = time.monotonic() + 3
    while not keys and time.monotonic() < deadline:
        time.sleep(0.025)
    assert keys, 'keyboard input did not reach the synthetic server'
    button('Stop control')
    browser('wait', '--text', 'Control stopped.')
    button('Close')
    # Check the compact layout independently, without another desktop connection.
    browser('set', 'viewport', '390', '844')
    button('Open workspaces')
    browser('wait', '350')  # Let the drawer's entrance animation finish.
    button('Host desktop')
    browser('wait', '--text', 'Control starts paused.')
    browser('screenshot', '/tmp/verde-desktop-mobile-review.png')
    button('Close')
    assert not errors, errors
    print('Browser desktop smoke passed: real noVNC handshake/framebuffer, input, stop, close, mobile layout.')
except Exception:
    print(browser('snapshot', '-i'))
    print(browser('eval', '--stdin', script='document.body.innerText'))
    raise
finally:
    stop.set()
    try:
        browser('close')
    finally:
        host.doCleanups()
        if thread is not None:
            thread.join(timeout=5)
            if thread.is_alive():
                raise AssertionError('synthetic desktop thread did not stop')
