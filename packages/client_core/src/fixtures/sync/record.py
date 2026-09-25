#!/usr/bin/env python3
"""Record K-09 fixtures from an owned temporary daemon, never a user endpoint.
Usage: python3 record.py /absolute/path/to/verde-daemon
"""
import hashlib, json, os, pathlib, socket, subprocess, sys, tempfile, time
out = pathlib.Path(__file__).parent
binary = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='verde-k09-record-') as directory:
    endpoint = pathlib.Path(directory) / 'verde-sessionizer.sock'
    env = {k:v for k,v in os.environ.items() if not k.startswith('VERDE_')}
    env['XDG_CONFIG_HOME'] = directory + '/config'
    env['XDG_DATA_HOME'] = directory + '/data'
    process = subprocess.Popen([str(binary), 'serve', '--data-dir', directory], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while not endpoint.exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('temporary daemon failed to start')
            time.sleep(.05)
        serial = 0
        target = None
        def call(method, params):
            global serial
            serial += 1
            request = dict(id=serial, method=method, params=params)
            if target: request['target'] = target
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5)
                connection.connect(str(endpoint))
                connection.sendall(json.dumps(request).encode() + b'\n')
                response = json.loads(connection.makefile('rb').readline())
            if 'error' in response: raise RuntimeError(response['error'])
            return response['result']
        status = call('core.status', {})
        target = {k:status[k] for k in ('runtime_id','instance_id')}
        client = call('daemon.client.register', {'persistent':False})['client_id']
        def mutation(key): return dict(client_id=client, request_key=key)
        layout = dict(v=2, focused=1, panes=[dict(id=1,kind='chat',thread=0),dict(id=2,kind='chat',thread=0),dict(id=3,kind='terminal',dock=7),dict(id=4,kind='browser')])
        threads = [dict(local_thread_id='layout-thread',title='Layout chat',provider='codex',reasoning_effort='high',fast_mode='on',access_mode='full_access',last_activity_at=1700000000),dict(local_thread_id='web-thread-fixture',title='Web chat',provider='codex',last_activity_at=1700000010),dict(local_thread_id='subagent:fixture',title='Child',provider='codex',last_activity_at=1700000020)]
        snapshot = dict(workspaces=[dict(workspace_id='fixture-ws',label='Fixture workspace',path='/tmp/k09-fixture-project',workspace_layout_json=json.dumps(layout),threads=threads)])
        call('state.snapshot.replace',dict(mutation=mutation('seed'),bootstrap=True,snapshot=snapshot))
        scopes=['workspaces','registry','sessions','turns','config']
        def save(name, data): (out/name).write_text(json.dumps(data,indent=2)+'\n')
        save('snapshot.json',call('core.snapshot',dict(scopes=scopes)))
        save('snapshot-config.json',call('core.snapshot',dict(scopes=['config'])))
        cursor=None; page=0
        while True:
            params=dict(workspace_id='',limit=2)
            if cursor: params['cursor']=cursor
            result=call('chat.thread.list',params)
            save(f'threads-{page}.json',result)
            cursor=result.get('next_cursor'); page+=1
            if not cursor: break
        save('changes.json',call('core.changes',dict(cursor=0,wait_ms=0)))
        save('provenance.json',dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),server_version=status['server_version'],protocol_version=status['protocol_version'],recorded_at='2026-09-25',transport='private Unix socket; temporary state; no providers or desktop'))
    finally:
        process.terminate()
        try: process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill(); process.communicate(); raise RuntimeError('temporary daemon did not stop gracefully')
        if process.returncode not in (0, -15): raise RuntimeError(f'temporary daemon exit {process.returncode}')
