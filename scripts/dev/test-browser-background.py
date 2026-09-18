#!/usr/bin/env python3
"""Exercise the Linux offscreen helper without the user GUI or network services."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
from urllib.parse import quote


def run_scenario(helper, startup):
    fds = []
    with tempfile.TemporaryDirectory(prefix='verde-browser-background-') as tmp:
        env = dict(os.environ)
        for name in ('XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME'):
            env[name] = str(Path(tmp) / name)
        # These are the shared BGRA slots used by the real desktop/helper protocol.
        for index in range(3):
            fd = os.memfd_create('verde-background-test')
            fds.append(fd)
            os.ftruncate(fd, 4096 * 2160 * 4)
            env[f'VERDE_BROWSER_LINUX_FRAME{index}_FD'] = str(fd)
        process = None
        try:
            with open(Path(tmp) / 'stderr.log', 'w+') as stderr:
                process = subprocess.Popen([helper], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=stderr, env=env, pass_fds=fds)
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    pending = bytearray()

                    def send(kind, **fields):
                        process.stdin.write((json.dumps(dict(kind=kind, **fields))+'\n').encode())
                        process.stdin.flush()

                    def wait_for(predicate):
                        deadline = time.monotonic() + 20
                        while time.monotonic() < deadline:
                            if b'\n' not in pending:
                                if not selector.select(max(0, deadline-time.monotonic())):
                                    break
                                chunk = os.read(process.stdout.fileno(), 65536)
                                if not chunk:
                                    stderr.seek(0)
                                    raise RuntimeError('helper exited: '+stderr.read())
                                pending.extend(chunk)
                                continue
                            line, _, rest = pending.partition(b'\n')
                            pending[:] = rest
                            event = json.loads(line)
                            pixel = None
                            if event['kind'] == 'failed':
                                raise RuntimeError(event['payload'])
                            if event['kind'] == 'frame_ready':
                                offset = ((event['height']//2)*event['width']+event['width']//2)*4
                                pixel = tuple(os.pread(fds[event['frame_slot']], 4, offset))
                                send('frame_release', frame_slot=event['frame_slot'],
                                     frame_sequence=event['frame_sequence'])
                            if predicate(event, pixel):
                                return event
                        raise TimeoutError('offscreen browser did not produce the expected event/frame')

                    def loaded_once(url):
                        wait_for(lambda e,p: e['kind']=='document_loaded')
                        # The first evaluation after readiness must run exactly
                        # once in the requested document; never retry the script.
                        send('eval', payload="JSON.stringify({url:location.href,count:"
                             "(window.__readinessRuns=(window.__readinessRuns||0)+1)})")
                        result = wait_for(lambda e,p: e['kind']=='eval_result')
                        assert json.loads(result['payload']) == {'url': url, 'count': 1}, result

                    if startup == 'show':
                        send('show', width=1280, height=720)
                        loaded_once('about:blank')
                        print('PASS: lazy show creates a usable blank document', flush=True)
                        send('hide')
                        wait_for(lambda e,p: e['kind']=='closed')
                    elif startup == 'reset':
                        send('navigate', width=1280, height=720, payload='about:blank')
                        loaded_once('about:blank')
                        print('PASS: fresh reset is ready for its first evaluation', flush=True)

                    html = '<html style="background:rgb(17,34,51)"><body></body></html>'
                    target = 'data:text/html,'+quote(html)
                    if startup == 'show':
                        # Supersede an in-flight load before the helper pumps
                        # WebKit; cancelled completion must not signal readiness.
                        send('navigate', payload='data:text/html,'+quote('<p>superseded</p>'))
                        send('navigate', payload='about:blank')
                    send('navigate', width=1280, height=720, payload=target)
                    loaded_once(target)
                    print(f'PASS: {startup} startup/replacement evaluates the retained document once', flush=True)
                    frame = wait_for(lambda e,p: e['kind']=='frame_ready' and p==(51,34,17,255))
                    assert (frame['width'],frame['height']) == (1280,720), frame
                    print('PASS: never-selected browser produces a 1280x720 screenshot frame', flush=True)
                    send('show', width=1280, height=720)
                    wait_for(lambda e,p: e['kind']=='opened')
                    send('hide')
                    wait_for(lambda e,p: e['kind']=='closed')
                    send('eval', payload="document.documentElement.style.background='rgb(68,85,102)'; true")
                    wait_for(lambda e,p: e['kind']=='frame_ready' and p==(102,85,68,255))
                    print('PASS: hidden browser repaints after JavaScript without a focus command', flush=True)
                    send('quit')
                    process.stdin.close()
                    assert process.wait(timeout=5) == 0
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            for fd in fds:
                os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', default='zig-out/bin/verde-browser-linux')
    args = parser.parse_args()
    helper = str(Path(args.helper).resolve())
    # Recovery recreates the helper. Exercise cold navigate, cold reset, and
    # show-only initialization in separate, disposable processes/state dirs.
    for startup in ('navigate', 'reset', 'show'):
        run_scenario(helper, startup)


if __name__ == '__main__':
    main()
