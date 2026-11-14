#!/usr/bin/env python3
"""Exercise a real macOS utun with a local synthetic core on an ephemeral runner.

No production credentials or external VPN service are used. Proxy mode avoids
changing global DNS or default routes; a single test route is removed in finally.
"""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

from linux_tun import CORE


def api(path, body=None, method=None):
    request = urllib.request.Request('http://127.0.0.1:1062' + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'}, method=method)
    with urllib.request.urlopen(request, timeout=3) as response:
        return json.load(response)


def wait_for(predicate, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except (OSError, ValueError):
            pass
        time.sleep(.2)
    raise AssertionError('Timed out waiting for macOS TUN')


def interface():
    output = subprocess.check_output(['ifconfig'], text=True)
    for block in re.split(r'(?=^\S+:)', output, flags=re.M):
        if 'inet 10.66.67.2 ' in block:
            return block.split(':', 1)[0]
    return None


assert sys.platform == 'darwin' and os.geteuid() == 0
binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='lalune-macos-tun-') as temporary:
    root = Path(temporary)
    app = root / '.la-lune'
    app.mkdir()
    for name in ('csqtt-core', 'csqttr-core'):
        core = app / name
        core.write_text(CORE.replace('#!/usr/bin/python3', '#!/usr/bin/env python3'))
        core.chmod(0o755)
    log = (root / 'backend.log').open('w+')
    process = subprocess.Popen([binary], env={**os.environ, 'HOME': str(root)},
                               stdout=log, stderr=log)
    target = '198.18.0.1'
    installed_route = False
    try:
        wait_for(lambda: api('/ping'))
        api('/settings', {'desktopSocks5Mode': True}, method='PATCH')
        for protocol in ('CSQTT', 'CSQTTR'):
            config = api('/configs', {'name': 'local fixture', 'protocol': protocol,
                'peer': '192.0.2.1:46000', 'password': 'local-test', 'hashes': 'local-test'})
            api('/vpn/connect', {'configId': config['id']})
            wait_for(lambda: api('/vpn/status')['connected'])
            tun = wait_for(interface)
            subprocess.run(['route', '-n', 'add', '-host', target, '-interface', tun],
                           check=True, capture_output=True)
            installed_route = True
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(3)
                sock.sendto(b'lalune-macos-tun-test', (target, 23456))
                assert sock.recv(128) == b'lalune-macos-tun-test'
            subprocess.run(['route', '-n', 'delete', '-host', target, '-interface', tun],
                           check=True, capture_output=True)
            installed_route = False
            api('/vpn/disconnect', {})
            wait_for(lambda: not api('/vpn/status')['connected'])
            wait_for(lambda: interface() is None)
            print(json.dumps({'protocol': protocol, 'utun_packet': 'passed'}), flush=True)
    finally:
        if installed_route:
            subprocess.run(['route', '-n', 'delete', '-host', target], capture_output=True)
        try:
            api('/vpn/disconnect', {})
        except Exception:
            pass
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.seek(0)
        if sys.exc_info()[0]:
            print(log.read(), file=sys.stderr)
        log.close()
