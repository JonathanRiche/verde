#!/usr/bin/env python3
"""Record real daemon + gateway delta traffic for K-16 in isolated state.

Usage: record.py /absolute/verde-daemon /absolute/verde-web leased-loopback-port

Owns a temporary daemon (private Unix socket, TemporaryDirectory data and
isolated HOME/XDG) and a gateway bound to 127.0.0.1 only. Seeds one synthetic
thread; no providers, desktop, network or user daemon. Every socket read has a
five-second deadline and both children are stopped and awaited in `finally`.
"""
import base64, hashlib, importlib.util, json, os, pathlib, socket, subprocess, sys, tempfile, time

out = pathlib.Path(__file__).resolve().parent
root = out.parents[4]
spec = importlib.util.spec_from_file_location('delta_feed', root / 'packages/web_app/tests/delta_feed.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
daemon, gateway = map(lambda s: pathlib.Path(s).resolve(), sys.argv[1:3])
port = int(sys.argv[3])
SCOPES = ['workspaces', 'registry', 'sessions', 'turns', 'config']
# The core's scoped read for chat.thread entries (sync_delta.zig).
THREAD_SCOPES = ['workspaces', 'config']


def save(name, value):
    (out / (name + '.json')).write_text(json.dumps(value, indent=2) + '\n')


def stop(child):
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=5)
        raise RuntimeError('child exceeded shutdown deadline')
    assert child.returncode in (0, -15), child.returncode


with tempfile.TemporaryDirectory(prefix='verde-k16-') as temp:
    directory = pathlib.Path(temp)
    env = {k: v for k, v in os.environ.items() if not k.startswith('VERDE_')}
    env.update(XDG_CONFIG_HOME=temp + '/config', XDG_DATA_HOME=temp + '/data', HOME=temp)
    endpoint = directory / 'verde-sessionizer.sock'
    with (directory / 'daemon.log').open('wb') as log:
        child = subprocess.Popen([str(daemon), 'serve', '--data-dir', temp], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while not endpoint.exists():
                assert child.poll() is None and time.monotonic() < deadline, 'daemon startup failed'
                time.sleep(.05)
            serial, target = 0, None

            def call(method, params):
                global serial
                serial += 1
                request = dict(id=serial, method=method, params=params)
                if target:
                    request['target'] = target
                with socket.socket(socket.AF_UNIX) as conn:
                    conn.settimeout(5)
                    conn.connect(str(endpoint))
                    conn.sendall(json.dumps(request).encode() + b'\n')
                    with conn.makefile('rb') as stream:
                        response = json.loads(stream.readline())
                assert 'error' not in response, response.get('error')
                return response['result']

            status = call('core.status', {})
            target = {k: status[k] for k in ('runtime_id', 'instance_id')}
            client = call('daemon.client.register', {'persistent': False})['client_id']

            def mutation(key):
                return dict(client_id=client, request_key=key)

            def rename(key, title):
                call('chat.thread.upsert', dict(mutation=mutation(key), workspace_id='delta-ws',
                                                thread=dict(local_thread_id='delta-thread', title=title, provider='codex')))

            call('state.snapshot.replace', dict(mutation=mutation('seed'), bootstrap=True, snapshot=dict(workspaces=[dict(
                workspace_id='delta-ws', label='Delta fixture', path='/tmp/k16-fixture',
                threads=[dict(local_thread_id='delta-thread', title='Before', provider='codex')])])))
            initial = call('core.snapshot', dict(scopes=SCOPES))
            save('initial', initial)
            save('initial-threads', call('chat.thread.list', dict(workspace_id='', limit=100)))
            token = base64.b64encode(os.urandom(32)).decode()
            token_file = directory / 'token'
            token_file.write_text(token)
            token_file.chmod(0o600)

            def opt_in(ws, cursor, request_id):
                """Send core.changes.mode; pre-ack frames are legacy-mode pushes."""
                ws.send('core.changes.mode', dict(mode='delta', cursor=cursor), request_id=request_id, target=target)
                deadline = time.monotonic() + 5
                while True:
                    frame = ws.receive()
                    if frame.get('id') == request_id:
                        assert frame['result'] == dict(mode='delta', cursor=cursor), frame
                        return frame
                    assert frame.get('method') in ('core.changes', 'core.snapshot'), frame
                    assert time.monotonic() < deadline, 'no delta acknowledgement'

            def next_change(ws):
                """After the ack only core.changes frames may arrive (no full snapshots)."""
                deadline = time.monotonic() + 10
                while True:
                    frame = ws.receive()
                    assert frame.get('method') == 'core.changes', 'full snapshot after delta acknowledgement'
                    if frame['params']['result']['entries']:
                        return frame
                    assert time.monotonic() < deadline, 'no delta change'

            with (directory / 'gateway.log').open('wb') as gateway_log:
                web = subprocess.Popen([str(gateway), '--host', '127.0.0.1', '--port', str(port), '--token-file', str(token_file),
                                        '--sessionizer', str(endpoint), '--pref-path', temp], env=env, stdout=gateway_log, stderr=gateway_log)
                try:
                    deadline = time.monotonic() + 10
                    while True:
                        assert web.poll() is None and time.monotonic() < deadline, 'gateway startup failed'
                        try:
                            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                                pass
                            break
                        except OSError:
                            time.sleep(.05)
                    ws = helper.WebSocket(port, token)
                    try:
                        hello = ws.receive()
                        assert hello['method'] == 'core.hello'
                        assert 'core.changes.delta.v1' in hello['params']['status_envelope']['result']['runtime_capabilities']
                        save('hello', hello)
                        bootstrap = ws.receive()
                        assert bootstrap['method'] == 'core.snapshot'
                        save('bootstrap', bootstrap)
                        save('ack', opt_in(ws, initial['change_cursor'], 11))
                        rename('update', 'After delta')
                        change = next_change(ws)
                        save('change', change)
                        save('scoped', call('core.snapshot', dict(scopes=THREAD_SCOPES)))
                        save('threads', call('chat.thread.list', dict(workspace_id='', limit=100)))
                        save('after-change', call('core.snapshot', dict(scopes=SCOPES)))
                    finally:
                        ws.close()
                    # Reconnect resume: an edit while disconnected is replayed
                    # from the saved cursor on a fresh socket.
                    rename('offline', 'Offline edit')
                    ws = helper.WebSocket(port, token)
                    try:
                        assert ws.receive()['method'] == 'core.hello'
                        assert ws.receive()['method'] == 'core.snapshot'
                        save('resume-ack', opt_in(ws, change['params']['result']['next_cursor'], 12))
                        save('resume-change', next_change(ws))
                        save('resume-scoped', call('core.snapshot', dict(scopes=THREAD_SCOPES)))
                        save('final', call('core.snapshot', dict(scopes=SCOPES)))
                        save('final-threads', call('chat.thread.list', dict(workspace_id='', limit=100)))
                    finally:
                        ws.close()
                finally:
                    stop(web)
            save('provenance', dict(
                daemon_sha256=hashlib.sha256(daemon.read_bytes()).hexdigest(),
                gateway_sha256=hashlib.sha256(gateway.read_bytes()).hexdigest(),
                protocol_version=status['protocol_version'],
                isolation='TemporaryDirectory; private Unix socket; 127.0.0.1 gateway on a leased port; '
                          'isolated HOME/XDG config/data; synthetic thread only; no providers'))
        finally:
            stop(child)
print('PASS: recorded delta opt-in, scoped refresh and reconnect resume; owned processes stopped')
