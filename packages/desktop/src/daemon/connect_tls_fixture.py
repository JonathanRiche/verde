"""Finite offline native TLS fixture. Generated certs and synthetic authority only."""
import gzip
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import threading
import time

root = Path(sys.argv[1])
def openssl(*args):
    subprocess.run(['openssl', *args], cwd=root, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '1', '-subj', '/CN=Connect-test-CA', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
openssl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'server.key', '-out', 'server.csr', '-subj', '/CN=localhost')
(root/'server.ext').write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nauthorityKeyIdentifier=keyid,issuer\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n')
openssl('x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'server.pem', '-days', '1', '-extfile', 'server.ext')
for p in root.glob('*.key'):p.chmod(0o600)

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, *_):pass
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):pass
    def do_POST(self):self.reply()
    def do_DELETE(self):self.reply()
    def reply(self):
        body=self.rfile.read(int(self.headers.get('Content-Length','0')))
        with (root/'requests.jsonl').open('a') as file:
            file.write(json.dumps(dict(method=self.command,path=self.path,headers=list(self.headers.items()),body=body.decode()))+'\n')
        status=200;result=b'{"ok":true}'
        if self.path=='/non200':status=403
        if self.path=='/delay':time.sleep(.3)
        if self.path=='/redirect':status=302
        if self.path=='/oversize':result=b'x'*(512*1024+1)
        if self.path.startswith('/v1/runtime-links/'):
            if (root/'refuse').exists():status=403
            identity=json.loads((root/'identity.json').read_text())
            result=json.dumps(dict(contract_version='1',link_id=self.path.rsplit('/',1)[1],runtime_id=identity['runtime_id'],instance_id=identity['instance_id'],runtime_key_thumbprint='A'*43,runtime_encryption_key_thumbprint='B'*43,status='unlinked',created_at='2026-09-01T00:00:00Z',unlinked_at='2026-09-30T00:00:00Z')).encode()
        compressed = self.path.startswith('/gzip-') or self.path.startswith('/v1/runtime-links/')
        chunked = self.path in ('/chunked','/gzip-chunked','/gzip-truncated-chunk','/gzip-delay-terminator') or self.path.startswith('/v1/runtime-links/')
        if compressed:result=gzip.compress(result)
        self.send_response(status)
        self.send_header('Content-Type','application/json')
        if compressed:self.send_header('Content-Encoding','gzip')
        if chunked:self.send_header('Transfer-Encoding','chunked')
        else:self.send_header('Content-Length',str(len(result)+(5 if self.path in ('/truncated','/gzip-truncated-length') else 0)))
        self.send_header('Connection','close')
        if status==302:self.send_header('Location','https://localhost:%d/ok'%self.server.server_port)
        self.end_headers()
        try:
            if chunked:
                self.wfile.write(('%x\r\n'%len(result)).encode()+result+b'\r\n')
                self.wfile.flush()
                if self.path=='/gzip-delay-terminator':time.sleep(.3)
                if self.path!='/gzip-truncated-chunk':self.wfile.write(b'0\r\nX-Fixture: complete\r\n\r\n')
            else:self.wfile.write(result)
        except (BrokenPipeError,ssl.SSLError):pass
        self.close_connection=True

server=Server(('127.0.0.1',0),Handler)
tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(root/'server.pem',root/'server.key')
server.socket=tls.wrap_socket(server.socket,server_side=True)
(root/'ready').write_text(str(server.server_port))
# Child kill/wait is deterministic; this timer also bounds orphan lifetime.
timer=threading.Timer(60,lambda:os._exit(0));timer.daemon=True;timer.start()
server.serve_forever(poll_interval=.05)
