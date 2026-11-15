#!/usr/bin/env python3
"""Windows VM: Wintun packet round trip using a local synthetic UDP core.

Runs only in an elevated disposable Windows VM. Uses an isolated APPDATA,
proxy mode and a temporary host route; no real VPN or credentials are used.
"""
import json
import http.client
import os
from pathlib import Path
import shutil
import socket
import struct
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
    interface_default = False
    try:
        wait_for(lambda: api('/ping'))
        api('/settings', {'desktopSocks5Mode': True}, method='PATCH')
        previous_session = ''
        for protocol in ('CSQTT', 'CSQTTR'):
            config = api('/configs', {'name': 'local fixture', 'protocol': protocol,
                'peer': '192.0.2.1:46000', 'password': 'local-test', 'hashes': 'local-test'})
            api('/vpn/connect', {'configId': config['id']})
            wait_for(lambda: api('/vpn/status')['connected'])
            session_id = wait_for(lambda: api('/vpn/stats').get('sessionId'))
            assert api('/vpn/stats')['configId'] == config['id']
            assert session_id != previous_session
            previous_session = session_id
            other = api('/configs', {'name': 'other fixture', 'protocol': protocol,
                'peer': '192.0.2.1:46000', 'password': 'local-test', 'hashes': 'local-test'})
            api('/configs/selected', {'id': other['id']}, method='PUT')
            assert api('/vpn/status')['configId'] == config['id']
            assert api('/vpn/stats')['configId'] == config['id']
            # A newly configured address may be Tentative while Windows runs
            # duplicate-address detection; binding to it is not yet possible.
            wait_for(lambda: powershell("if (Get-NetIPAddress -InterfaceAlias 'CSQTT' -AddressFamily IPv4 -IPAddress '10.66.67.2' -ErrorAction SilentlyContinue | Where-Object AddressState -eq Preferred) { exit 0 } else { exit 1 }", False).returncode == 0)
            powershell("New-NetRoute -DestinationPrefix '198.18.0.1/32' -InterfaceAlias 'CSQTT' -NextHop '0.0.0.0' -PolicyStore ActiveStore -ErrorAction Stop | Out-Null")
            route = True
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(5)
                sock.bind(('10.66.67.2', 0))
                sock.sendto(b'lalune-windows-tun-test', ('198.18.0.1', 23456))
                assert sock.recv(128) == b'lalune-windows-tun-test'
            powershell("Remove-NetRoute -DestinationPrefix '198.18.0.1/32' -InterfaceAlias 'CSQTT' -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop")
            route = False
            # Probe whether an interface-bound socket can use a low-priority
            # tunnel default without installing global per-destination routes.
            # This runs only in the disposable Windows test VM.
            powershell("New-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceAlias 'CSQTT' -NextHop '0.0.0.0' -RouteMetric 9000 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null")
            interface_default = True
            index = int(powershell("(Get-NetAdapter -Name 'CSQTT').ifIndex").stdout.strip())
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(5)
                # IP_UNICAST_IF takes a Windows interface index in network byte order.
                sock.bind(('10.66.67.2', 0))
                sock.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I', index))
                sock.sendto(b'lalune-interface-bound-test', ('198.18.0.1', 23456))
                assert sock.recv(128) == b'lalune-interface-bound-test'
            powershell("Remove-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceAlias 'CSQTT' -NextHop '0.0.0.0' -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop")
            interface_default = False
            api('/vpn/disconnect', {})
            wait_for(lambda: not api('/vpn/status')['connected'])
            assert api('/vpn/stats')['sessionId'] == ''
            print(json.dumps({'protocol': protocol, 'wintun_packet': 'passed'}), flush=True)
        # Full integration: sing-box classifies the Python process, LaLune's
        # SOCKS server binds to Wintun, and the synthetic core echoes packets.
        for mode, expected_echo in [('whitelist', True), ('blacklist', False)]:
            api('/settings', {'desktopSocks5Mode': False, 'windowsSplitEnabled': True,
                'windowsSplitMode': mode, 'windowsSplitPrograms': str(Path(sys.executable).resolve()),
                'windowsSplitDomains': '', 'ipRoutingIps': ''}, method='PATCH')
            api('/vpn/connect', {'configId': config['id']})
            wait_for(lambda: api('/vpn/status')['connected'], timeout=45)
            time.sleep(2)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(4)
                sock.sendto(b'lalune-split-process-test', ('1.1.1.1', 23456))
                try:
                    got_echo = sock.recv(128) == b'lalune-split-process-test'
                except socket.timeout:
                    got_echo = False
                assert got_echo == expected_echo, f'{mode}: expected echo={expected_echo}, got {got_echo}'
            if expected_echo:
                connection = http.client.HTTPConnection('1.1.1.1', 23457, timeout=8)
                connection.request('GET', '/', headers={'Host': 'process.lalune.test'})
                assert connection.getresponse().read() == b'lalune-tunnel'
                connection.close()
            api('/vpn/disconnect', {})
            wait_for(lambda: not api('/vpn/status')['connected'])
            wait_for(lambda: powershell("if (Get-NetRoute -InterfaceAlias 'LaLune-Routing' -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }", False).returncode == 0)
            assert powershell("if (Get-NetRoute -InterfaceAlias 'CSQTT' -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }", False).returncode == 0
            print(json.dumps({'mode': mode, 'process_udp': 'passed'}), flush=True)
        for mode, expected_echo in [('whitelist', True), ('blacklist', False)]:
            api('/settings', {'windowsSplitEnabled': True, 'windowsSplitMode': mode,
                'windowsSplitPrograms': '', 'windowsSplitDomains': 'selected.lalune.test'}, method='PATCH')
            api('/vpn/connect', {'configId': config['id']})
            wait_for(lambda: api('/vpn/status')['connected'], timeout=45)
            time.sleep(2)
            query = (b'\x72\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00'
                     b'\x08selected\x06lalune\x04test\x00\x00\x01\x00\x01')
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns:
                dns.settimeout(8)
                dns.sendto(query, ('172.29.252.2', 53))
                response, _ = dns.recvfrom(512)
                assert response[:2] == query[:2] and b'\x01\x01\x01\x01' in response
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(4)
                sock.sendto(b'lalune-split-domain-test', ('1.1.1.1', 23456))
                try:
                    got_echo = sock.recv(128) == b'lalune-split-domain-test'
                except socket.timeout:
                    got_echo = False
                assert got_echo == expected_echo, f'{mode}/domain: expected echo={expected_echo}, got {got_echo}'
            if expected_echo:
                connection = http.client.HTTPConnection('1.1.1.1', 23457, timeout=8)
                connection.request('GET', '/', headers={'Host': 'selected.lalune.test'})
                assert connection.getresponse().read() == b'lalune-tunnel'
                connection.close()
            api('/vpn/disconnect', {})
            wait_for(lambda: not api('/vpn/status')['connected'])
            wait_for(lambda: powershell("if (Get-NetRoute -InterfaceAlias 'LaLune-Routing' -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }", False).returncode == 0)
            print(json.dumps({'mode': mode, 'domain_dns_udp': 'passed'}), flush=True)
        # Abruptly terminating the backend must also terminate its router
        # process and remove the test router's system routes.
        api('/settings', {'windowsSplitEnabled': True, 'windowsSplitMode': 'whitelist',
            'windowsSplitPrograms': str(Path(sys.executable).resolve()), 'windowsSplitDomains': ''}, method='PATCH')
        api('/vpn/connect', {'configId': config['id']})
        wait_for(lambda: api('/vpn/status')['connected'], timeout=45)
        def child_pid(name):
            result = powershell(f"(Get-CimInstance Win32_Process -Filter 'ParentProcessId={process.pid}' | Where-Object Name -eq '{name}' | Select-Object -First 1 -ExpandProperty ProcessId)", False)
            return int(result.stdout.strip()) if result.stdout.strip().isdigit() else None
        router = wait_for(lambda: child_pid('sing-box.exe'))
        core_pid = wait_for(lambda: child_pid('csqttr-core.exe'))
        process.kill()
        process.wait(timeout=10)
        for pid in (router, core_pid):
            wait_for(lambda: powershell(f"if (Get-Process -Id {pid} -ErrorAction SilentlyContinue) {{ exit 1 }} else {{ exit 0 }}", False).returncode == 0)
        wait_for(lambda: powershell("if (Get-NetRoute -InterfaceAlias 'LaLune-Routing' -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }", False).returncode == 0)
        print(json.dumps({'backend_crash_cleanup': 'passed'}), flush=True)
    finally:
        if interface_default:
            powershell("Remove-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceAlias 'CSQTT' -NextHop '0.0.0.0' -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue", False)
        if route:
            powershell("Remove-NetRoute -DestinationPrefix '198.18.0.1/32' -InterfaceAlias 'CSQTT' -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue", False)
        try:
            api('/vpn/disconnect', {})
        except Exception:
            pass
        if process.poll() is None:
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
