#!/usr/bin/env python3
"""Windows VM: Wintun packet round trip using a local synthetic UDP core.

Runs only in an elevated disposable Windows VM. Uses an isolated APPDATA,
proxy mode and a temporary host route; no real VPN or credentials are used.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request


def api(path, body=None, method=None):
    request = urllib.request.Request('http://127.0.0.1:1062' + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'}, method=method)
    with urllib.request.urlopen(request, timeout=3) as response:
        return json.load(response)


def wait_for(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except (OSError, ValueError):
            pass
        time.sleep(.2)
    raise AssertionError('Timed out waiting for Windows TUN')


def powershell(command, check=True):
    return subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', command],
                          capture_output=True, text=True, check=check, timeout=20)


assert sys.platform == 'win32'
backend, core, wintun = map(lambda p: Path(p).resolve(), sys.argv[1:4])
with tempfile.TemporaryDirectory(prefix='lalune-windows-tun-') as temporary:
    root = Path(temporary)
    app = root / '.la-lune'
    app.mkdir()
    shutil.copy2(core, app / 'csqtt-core.exe')
    shutil.copy2(core, app / 'csqttr-core.exe')
    shutil.copy2(wintun, app / 'wintun.dll')
    log = (root / 'backend.log').open('w+', encoding='utf-8')
    process = subprocess.Popen([str(backend)], env={**os.environ, 'APPDATA': str(root)},
                               stdout=log, stderr=log)
    route = False
    try:
        wait_for(lambda: api('/ping'))
        api('/settings', {'desktopSocks5Mode': True}, method='PATCH')
        for protocol in ('CSQTT', 'CSQTTR'):
            config = api('/configs', {'name': 'local fixture', 'protocol': protocol,
                'peer': '192.0.2.1:46000', 'password': 'local-test', 'hashes': 'local-test'})
            api('/vpn/connect', {'configId': config['id']})
            wait_for(lambda: api('/vpn/status')['connected'])
            wait_for(lambda: powershell("if (Get-NetIPAddress -InterfaceAlias 'CSQTT' -AddressFamily IPv4 -IPAddress '10.66.67.2' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }", False).returncode == 0)
            powershell("New-NetRoute -DestinationPrefix '198.18.0.1/32' -InterfaceAlias 'CSQTT' -NextHop '0.0.0.0' -PolicyStore ActiveStore -ErrorAction Stop | Out-Null")
            route = True
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(5)
                sock.bind(('10.66.67.2', 0))
                sock.sendto(b'lalune-windows-tun-test', ('198.18.0.1', 23456))
                assert sock.recv(128) == b'lalune-windows-tun-test'
            powershell("Remove-NetRoute -DestinationPrefix '198.18.0.1/32' -InterfaceAlias 'CSQTT' -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop")
            route = False
            api('/vpn/disconnect', {})
            wait_for(lambda: not api('/vpn/status')['connected'])
            print(json.dumps({'protocol': protocol, 'wintun_packet': 'passed'}), flush=True)
    finally:
        if route:
            powershell("Remove-NetRoute -DestinationPrefix '198.18.0.1/32' -InterfaceAlias 'CSQTT' -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue", False)
        try:
            api('/vpn/disconnect', {})
        except Exception:
            pass
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.seek(0)
        if sys.exc_info()[0]:
            print(log.read(), file=sys.stderr)
        log.close()
