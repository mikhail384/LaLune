#!/usr/bin/env python3
"""Disposable Windows VM: test a privately supplied CSQTTR profile."""
import json
import os
import subprocess
import time
import urllib.request


def api(path, body=None, method=None):
    request = urllib.request.Request('http://127.0.0.1:1062' + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'}, method=method)
    with urllib.request.urlopen(request, timeout=8) as response:
        return json.load(response)


def wait_for(predicate, timeout=110):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except (OSError, ValueError):
            pass
        time.sleep(2)
    raise RuntimeError('connection timeout')


def powershell(command):
    return subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', command],
                          text=True, capture_output=True, check=True, timeout=20).stdout.strip()


def dns_snapshot():
    return powershell("Get-DnsClientServerAddress -AddressFamily IPv4 | "
        "Where-Object InterfaceAlias -ne 'CSQTT' | Sort-Object InterfaceAlias | "
        "Select-Object InterfaceAlias,ServerAddresses | ConvertTo-Json -Compress -Depth 4")


def exercise(config_id, label):
    api('/vpn/connect', {'configId': config_id})
    wait_for(lambda: api('/vpn/status').get('connected'))
    print('Windows backend reports connected:', label, flush=True)
    wait_for(lambda: powershell("if (Get-NetIPAddress -InterfaceAlias 'CSQTT' "
        "-AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq Preferred) "
        "{ 'ready' }") == 'ready', timeout=30)
    print('Windows Wintun address ready:', label, flush=True)
    route = powershell("Find-NetRoute -RemoteIPAddress '1.1.1.1' | "
                       "Select-Object -ExpandProperty InterfaceAlias -ErrorAction SilentlyContinue")
    if 'CSQTT' not in route.splitlines():
        raise RuntimeError('test route does not use Wintun')
    before = api('/vpn/stats')
    result = subprocess.run(['curl.exe', '-4', '--noproxy', '*', '-sS', '-o', 'NUL',
                             '-w', '%{http_code}', '--max-time', '30', 'https://example.com'],
                            capture_output=True, text=True, timeout=35)
    after = api('/vpn/stats')
    if result.returncode or result.stdout.strip() != '200':
        raise RuntimeError('HTTPS data test failed')
    if not (after.get('rxBytes', 0) > before.get('rxBytes', 0) and
            after.get('txBytes', 0) > before.get('txBytes', 0)):
        raise RuntimeError('Wintun traffic counters did not increase')
    print('Windows CSQTTR:', label, 'Wintun route, HTTPS 200, RX/TX increased', flush=True)
    api('/vpn/disconnect', {})
    wait_for(lambda: not api('/vpn/status').get('connected'), timeout=15)


def public_address():
    result = subprocess.run(['curl.exe', '-4', '--noproxy', '*', '-fsS',
                             '--max-time', '30', 'https://api.ipify.org'],
                            capture_output=True, text=True, timeout=35)
    if result.returncode:
        raise RuntimeError('public address check failed')
    import ipaddress
    return str(ipaddress.IPv4Address(result.stdout.strip()))


def exercise_split(config_id, baseline, mode, kind):
    curl = os.path.join(os.environ['SystemRoot'], 'System32', 'curl.exe')
    settings = {
        'windowsSplitEnabled': True, 'windowsSplitMode': mode,
        'windowsSplitPrograms': curl if kind == 'process' else '',
        'windowsSplitDomains': 'api.ipify.org' if kind == 'domain' else '',
        'ipRoutingIps': '', 'desktopSocks5Mode': False,
    }
    api('/settings', settings, method='PATCH')
    api('/vpn/connect', {'configId': config_id})
    wait_for(lambda: api('/vpn/status').get('connected'))
    before = api('/vpn/stats')
    actual = public_address()
    after = api('/vpn/stats')
    should_use_tunnel = mode == 'whitelist'
    if should_use_tunnel:
        if actual == baseline:
            raise RuntimeError('selected traffic did not change public address')
        if not (after.get('rxBytes', 0) > before.get('rxBytes', 0) and
                after.get('txBytes', 0) > before.get('txBytes', 0)):
            raise RuntimeError('split tunnel counters did not increase')
    elif actual != baseline:
        raise RuntimeError('excluded traffic did not use the original route')
    print('Windows split routing:', mode, kind, 'public route and HTTPS passed', flush=True)
    api('/vpn/disconnect', {})
    wait_for(lambda: not api('/vpn/status').get('connected'), timeout=20)


secret = os.environ.get('LALUNE_WINDOWS_TEST_LINK', '')
if not secret:
    raise SystemExit('Missing private test profile')
initial_dns = dns_snapshot()
try:
    config = api('/configs', {'name': 'Temporary CSQTTR test',
                              'protocol': 'CSQTTR', 'link': secret})
    if not config.get('id'):
        raise RuntimeError('test profile import failed')
    print('Windows test profile imported', flush=True)
    exercise(config['id'], 'initial')
    time.sleep(3)
    exercise(config['id'], 'reconnect')
    baseline = public_address()
    for mode in ('whitelist', 'blacklist'):
        for kind in ('process', 'domain'):
            exercise_split(config['id'], baseline, mode, kind)
except Exception as error:
    print('Windows CSQTTR test failed:', type(error).__name__, flush=True)
    allowed = {'connection timeout', 'test profile import failed',
               'test route does not use Wintun', 'HTTPS data test failed',
               'Wintun traffic counters did not increase', 'public address check failed',
               'selected traffic did not change public address',
               'split tunnel counters did not increase',
               'excluded traffic did not use the original route'}
    if type(error) is RuntimeError and str(error) in allowed:
        print('Windows test stage:', str(error), flush=True)
    try:
        print('Windows backend state:', api('/vpn/status').get('state'), flush=True)
        logs = json.dumps(api('/logs'), ensure_ascii=False).lower()
        print('Windows diagnostic markers:', {word: word in logs for word in
            ('getconf', 'dtls', 'timeout', 'wintun', 'tun start failed')}, flush=True)
    except Exception:
        pass
    raise SystemExit(1)
finally:
    try:
        api('/vpn/disconnect', {})
        wait_for(lambda: not api('/vpn/status').get('connected'), timeout=15)
        restored = initial_dns == dns_snapshot()
        print('Windows other-interface DNS unchanged:', restored, flush=True)
        if not restored:
            raise SystemExit(1)
    except Exception:
        print('Windows cleanup could not be verified', flush=True)
        raise SystemExit(1)
