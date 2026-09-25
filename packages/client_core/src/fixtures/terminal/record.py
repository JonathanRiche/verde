#!/usr/bin/env python3
"""Record synthetic PTY fixtures over a private Unix socket, never a user daemon."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
out = Path(__file__).parent
with tempfile.TemporaryDirectory(prefix='verde-k12-') as directory:
    endpoint = Path(directory) / 'verde-sessionizer.sock'
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VERDE_', 'XDG_'))}
    env.update(HOME=directory, XDG_CONFIG_HOME=directory+'/config', XDG_DATA_HOME=directory+'/data', SHELL='/bin/sh')
    process = subprocess.Popen([str(binary), 'serve', '--data-dir', directory], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    serial = 0
    target = None
    def call(method, params):
        global serial
        serial += 1
        request = dict(id=serial, method=method, params=params)
        if target:
            request['target'] = target
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(5)
            connection.connect(str(endpoint))
            connection.sendall(json.dumps(request).encode() + b'\n')
            response = json.loads(connection.makefile('rb').readline(1024*1024))
        if response.get('error'):
            raise RuntimeError('fixture RPC failed: ' + method)
        return response['result']
    def save(name, value):
        # Volatile process metadata is irrelevant to the wire contract.
        def normalize(item):
            if isinstance(item, dict):
                for key in ('pid', 'foreground_process_group', 'child_process_count', 'created_at_ms', 'last_attached_at_ms'):
                    item.pop(key, None)
                for nested in item.values(): normalize(nested)
            elif isinstance(item, list):
                for nested in item: normalize(nested)
        normalize(value)
        (out/name).write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')
    try:
        deadline = time.monotonic() + 10
        while not endpoint.exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('temporary daemon startup failed')
            time.sleep(.05)
        status = call('core.status', {})
        target = {key: status[key] for key in ('runtime_id', 'instance_id')}
        # No profiles, shell startup files, providers or network. Only synthetic data.
        command = ['/bin/sh', '-c', "printf '\033[2J\033[H\033]2;Fixture\007\033[1;31mRED\033[0m\r\nwide: 界 é\r\n\033[?1h\033[?2004h'; exec /bin/cat"]
        save('create.json', call('session.create', dict(id='k12-fixture', cwd=directory, command=command, cols=20, rows=4)))
        deadline = time.monotonic()+5
        while True:
            first = call('session.tail', dict(id='k12-fixture', max_bytes=262144))
            if '\x1b[?2004h' in first['text']:
                break
            if time.monotonic() > deadline:
                raise RuntimeError('synthetic PTY output deadline')
            time.sleep(.02)
        save('tail.json', first)
        save('resize.json', call('session.resize', dict(id='k12-fixture', cols=24, rows=6)))
        save('write.json', call('session.write', dict(id='k12-fixture', text='fixture-input\n')))
        save('screen.json', call('session.screen', dict(id='k12-fixture', max_bytes=262144)))
        save('kill.json', call('session.kill', dict(id='k12-fixture')))
        save('provenance.json', dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
             server_version=status['server_version'], protocol_version=status['protocol_version'],
             recorded_at='2026-09-25', transport='private Unix socket; isolated HOME/config/state; synthetic shell; no providers/network',
             normalization='volatile process metadata removed; temporary cwd replaced'))
        for path in out.glob('*.json'):
            path.write_text(path.read_text().replace(directory, '/tmp/k12-fixture'))
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            raise RuntimeError('temporary daemon shutdown deadline')
        if process.returncode not in (0, -15):
            raise RuntimeError('temporary daemon exit failure')
print('Recorded 7 synthetic terminal fixtures; temporary daemon and state cleaned up.')
