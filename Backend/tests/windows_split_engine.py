#!/usr/bin/env python3
"""Exercise sing-box process/domain rules without changing host routing.

This only tests the routing engine over a local HTTP proxy inbound; it does not
prove Windows TUN interception or integration with the LaLune VPN tunnel.
"""
import http.client
import json
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


class Direct(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.recv(8192)
        self.request.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\ndirect')


def read_exact(sock, length):
    data = b''
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise EOFError('truncated SOCKS message')
        data += part
    return data


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        header = read_exact(sock, 2)
        read_exact(sock, header[1])
        sock.sendall(b'\x05\x00')
        header = read_exact(sock, 4)
        if header[3] == 1:
            read_exact(sock, 4)
        elif header[3] == 3:
            read_exact(sock, read_exact(sock, 1)[0])
        elif header[3] == 4:
            read_exact(sock, 16)
        else:
            raise ValueError('unexpected SOCKS address')
        read_exact(sock, 2)
        sock.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x01')
        sock.recv(8192)
        sock.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\ntunnel')


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def run_case(binary, direct_port, socks_port, mode, kind, matches):
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    selected, fallback = ('direct', 'tunnel') if mode == 'blacklist' else ('tunnel', 'direct')
    rule = {'domain_suffix': ['localhost' if matches else 'unselected.invalid']} if kind == 'domain' else {'process_path': [str(Path(sys.executable).resolve()) if matches else r'C:\unselected.exe']}
    rule.update({'action': 'route', 'outbound': selected})
    config = {
        'log': {'level': 'debug'},
        'inbounds': [{'type': 'http', 'listen': '127.0.0.1', 'listen_port': port}],
        'dns': {'servers': [{'type': 'hosts', 'tag': 'local', 'predefined': {'localhost': '127.0.0.1'}}], 'final': 'local', 'strategy': 'ipv4_only'},
        'outbounds': [{'type': 'direct', 'tag': 'direct'}, {'type': 'socks', 'tag': 'tunnel', 'server': '127.0.0.1', 'server_port': socks_port}],
        'route': {'rules': [rule], 'final': fallback},
    }
    with tempfile.TemporaryDirectory(prefix='lalune-split-engine-') as tmp:
        path = Path(tmp) / 'config.json'
        path.write_text(json.dumps(config), encoding='utf-8')
        subprocess.run([binary, 'check', '-c', str(path)], check=True, capture_output=True, timeout=20)
        process = subprocess.Popen([binary, 'run', '-c', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            import time
            for _ in range(100):
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.1)
            host = 'localhost' if kind == 'domain' else '127.0.0.1'
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=12)
            connection.request('GET', f'http://{host}:{direct_port}/')
            result = connection.getresponse().read().decode()
            connection.close()
            expected = selected if matches else fallback
            if result != expected:
                raise AssertionError(f'{mode}/{kind}: expected {expected}, got {result}')
            print(json.dumps({'mode': mode, 'rule': kind, 'matches': matches, 'result': result}), flush=True)
        finally:
            process.terminate()
            process.wait(timeout=5)
            if sys.exc_info()[0]:
                print(process.stderr.read().decode(errors='replace'), file=sys.stderr)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: windows_split_engine.py path/to/sing-box.exe')
    with Server(('127.0.0.1', 0), Direct) as direct, Server(('127.0.0.1', 0), Proxy) as proxy:
        threading.Thread(target=direct.serve_forever, daemon=True).start()
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        try:
            for mode in ('blacklist', 'whitelist'):
                for kind in ('domain', 'process'):
                    for matches in (True, False):
                        run_case(sys.argv[1], direct.server_address[1], proxy.server_address[1], mode, kind, matches)
        finally:
            direct.shutdown()
            proxy.shutdown()
