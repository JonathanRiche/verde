#!/usr/bin/env python3
"""Record K-10 fixtures from an owned temporary daemon, never a user endpoint.
Usage: python3 record.py /absolute/path/to/verde-daemon
"""
import hashlib, json, os, pathlib, socket, subprocess, sys, tempfile, time
out = pathlib.Path(__file__).parent
binary = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='verde-k10-record-') as directory:
    endpoint = pathlib.Path(directory) / 'verde-sessionizer.sock'
    env = {k:v for k,v in os.environ.items() if not k.startswith('VERDE_')}
    env['VERDE_SESSION_DAEMON_CHAT_STUB'] = '1'
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
        def save(name, data): (out/name).write_text(json.dumps(data,indent=2)+'\n')
        ws='chat-fixture-ws'; thread='chat-fixture-thread'
        path=directory+'/project'; pathlib.Path(path).mkdir()
        snapshot=dict(workspaces=[dict(workspace_id=ws,label='Chat fixture',path=path,threads=[dict(local_thread_id=thread,title='Chat fixture',provider='codex')])])
        call('state.snapshot.replace',dict(mutation=mutation('seed'),bootstrap=True,snapshot=snapshot))
        # Seed enough durable rows for a real opaque backward cursor.
        for index in range(45):
            call('chat.message.append',dict(mutation=mutation(f'message-{index}'),workspace_id=ws,thread_id=thread,message=dict(message_id=f'old-{index}',role='system',author='Fixture',body=f'History {index}')))
        first=call('chat.message.list',dict(workspace_id=ws,local_thread_id=thread,direction='backward',limit=40))
        save('page-0.json',first)
        save('page-1.json',call('chat.message.list',dict(workspace_id=ws,local_thread_id=thread,direction='backward',limit=40,cursor=first['next_cursor'])))
        start=call('chat.turn.start',dict(turn_id='fixture-turn',workspace_id=ws,local_thread_id=thread,project_path=path,prompt='Fixture prompt',thread_title='Chat fixture',provider='codex',harness='local_cli',message_id='fixture-user',test_stub=True))
        save('start.json',start)
        after=0; tails=[]; deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            tail=call('chat.turn.tail',dict(turn_id='fixture-turn',after_seq=after,wait_ms=0))
            tails.append(tail)
            after=max([after]+[event['seq'] for event in tail['events']])
            if tail['status'] in ('completed','failed','aborted'): break
            time.sleep(.02)
        else: raise RuntimeError('stub turn did not finish')
        save('tails.json',tails)
        # The cap is a durable system message written by the gateway (A-09).
        call('chat.message.append',dict(mutation=mutation('cap-notice'),workspace_id=ws,thread_id=thread,message=dict(message_id='access-cap:fixture',role='system',author='Verde',body='This device is limited to approval-required access. The request was clamped to supervised mode; shell commands require explicit approval.')))
        save('committed.json',call('chat.message.list',dict(workspace_id=ws,local_thread_id=thread,direction='backward',limit=40)))
        save('thread.json',call('chat.thread.get',dict(workspace_id=ws,local_thread_id=thread)))
        save('provenance.json',dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),server_version=status['server_version'],protocol_version=status['protocol_version'],recorded_at='2026-09-25',transport='private Unix socket; temporary state/config; hermetic built-in stub; no providers, network, or desktop',cap_notice='seeded via real chat.message.append using A-09 gateway text; not a gateway recording'))
    finally:
        process.terminate()
        try: process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill(); process.communicate(); raise RuntimeError('temporary daemon did not stop gracefully')
        if process.returncode not in (0, -15): raise RuntimeError(f'temporary daemon exit {process.returncode}')
