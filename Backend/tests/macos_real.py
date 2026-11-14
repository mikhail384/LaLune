#!/usr/bin/env python3
"""Disposable macOS runner: test a privately supplied CSQTTR profile.

The profile is read from an environment secret and never printed or persisted
by this test. The backend's temporary home belongs to the disposable runner.
"""
import json
import os
import subprocess
import time
import urllib.request


def api(path, body=None):
    request = urllib.request.Request('http://127.0.0.1:1062' + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'})
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


def dns_snapshot():
    result = subprocess.run(['networksetup', '-listallnetworkservices'],
                            capture_output=True, text=True, check=True)
    services = [line.strip() for line in result.stdout.splitlines()[1:]
                if line.strip() and not line.startswith('*')]
    return {name: subprocess.run(['networksetup', '-getdnsservers', name],
                                capture_output=True, text=True, check=True).stdout
            for name in services}


secret = os.environ.get('LALUNE_MACOS_TEST_LINK', '')
if not secret:
    raise SystemExit('Missing private test profile')
initial_dns = dns_snapshot()
try:
    config = api('/configs', {'name': 'Temporary CSQTTR test',
                              'protocol': 'CSQTTR', 'link': secret})
    if not config.get('id'):
        raise RuntimeError('test profile import failed')
    api('/vpn/connect', {'configId': config['id']})
    wait_for(lambda: api('/vpn/status').get('connected'))
    route = subprocess.run(['route', '-n', 'get', '1.1.1.1'],
                           text=True, capture_output=True, check=True).stdout
    if not any(line.strip().startswith('interface: utun') for line in route.splitlines()):
        raise RuntimeError('test route does not use utun')
    before = api('/vpn/stats')
    result = subprocess.run(['curl', '-4', '--noproxy', '*', '-sS', '-o', '/dev/null',
                             '-w', '%{http_code}', '--max-time', '30', 'https://example.com'],
                            capture_output=True, text=True, timeout=35)
    after = api('/vpn/stats')
    if result.returncode or result.stdout.strip() != '200':
        raise RuntimeError('HTTPS data test failed')
    if not (after.get('rxBytes', 0) > before.get('rxBytes', 0) and
            after.get('txBytes', 0) > before.get('txBytes', 0)):
        raise RuntimeError('utun traffic counters did not increase')
    print('macOS CSQTTR: connected, utun route, HTTPS 200, RX/TX increased', flush=True)
except Exception as error:
    print('macOS CSQTTR test failed:', type(error).__name__, flush=True)
    raise SystemExit(1)
finally:
    try:
        api('/vpn/disconnect', {})
        wait_for(lambda: not api('/vpn/status').get('connected'), timeout=15)
        restored = initial_dns == dns_snapshot()
        print('macOS DNS restored:', restored, flush=True)
        if not restored:
            raise SystemExit(1)
    except Exception:
        print('macOS cleanup could not be verified', flush=True)
        raise SystemExit(1)
