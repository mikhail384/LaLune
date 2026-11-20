// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import 'dart:convert';
import 'dart:io';

import '../models/config_item.dart';
import '../models/subscription.dart';

String configPingKey(int id) => 'config:$id';
String subConfigPingKey(String subId, SubConfig config) =>
    'sub:$subId:${config.key}';

class _ProbeEndpoint {
  final String host;
  final int port;
  const _ProbeEndpoint(this.host, this.port);
}

/// Измеряет реальный RTT (round-trip time) через активный VPN-туннель:
/// первый запрос прогревает TCP+TLS, второй по тому же keep-alive соединению
/// замеряет чистую сетевую задержку HTTP 204.
Future<int?> probeActiveTunnel({
  Duration timeout = const Duration(seconds: 5),
}) async {
  const probeUrls = [
    'https://cp.cloudflare.com/generate_204',
    'https://www.gstatic.com/generate_204',
  ];

  for (final rawUrl in probeUrls) {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.parse(rawUrl);

      // Прогрев DNS + TCP + TLS (не входит в чистый RTT).
      final warmReq = await client.getUrl(uri).timeout(timeout);
      warmReq.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
      final warmResp = await warmReq.close().timeout(timeout);
      await warmResp.drain<void>().timeout(timeout);
      if (warmResp.statusCode < 200 || warmResp.statusCode >= 400) {
        continue;
      }

      // Чистый 1x RTT запрос поверх уже открытого keep-alive соединения.
      final watch = Stopwatch()..start();
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
      final resp = await req.close().timeout(timeout);
      watch.stop();
      await resp.drain<void>().timeout(timeout);

      if (resp.statusCode >= 200 && resp.statusCode < 400) {
        return watch.elapsedMilliseconds.clamp(1, 60000).toInt();
      }
    } catch (_) {
      // Пробуем следующий endpoint.
    } finally {
      client.close(force: true);
    }
  }
  return null;
}

/// Измеряет реальную сетевую задержку до сервера профиля без создания TUN.
/// 1) Реальный ICMP ping с явным таймаутом и точным парсингом RTT.
/// 2) TCP-проба (включая SYN->RST для UDP-only CSQTT портов, если сервер
///    ответил ECONNREFUSED за реальное сетевое время).
Future<int?> probeProfile(
  ConfigItem config, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final endpoints = _endpointsFor(config);
  final host = _hostFor(config, endpoints);
  if (host == null) return null;

  final icmp = await _icmpPing(host, timeout: timeout);
  if (icmp != null) return icmp;

  int? best;
  for (final endpoint in endpoints) {
    final watch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        endpoint.host,
        endpoint.port,
        timeout: timeout,
      );
      watch.stop();
      final ms = watch.elapsedMilliseconds.clamp(1, 60000).toInt();
      if (best == null || ms < best) best = ms;
    } on SocketException catch (e) {
      watch.stop();
      // Для UDP-only серверов CSQTT удалённый хост отвечает TCP RST
      // (ECONNREFUSED: 111 Linux/Android, 61 macOS/iOS, 10061 Windows) —
      // время до получения RST равно реальному 1x сетевому RTT.
      final code = e.osError?.errorCode;
      final isRefused = code == 111 || code == 61 || code == 10061;
      final ms = watch.elapsedMilliseconds;
      if (isRefused && ms >= 2 && ms <= 15000) {
        if (best == null || ms < best) best = ms;
      }
    } catch (_) {
      // Пробуем следующий endpoint.
    } finally {
      socket?.destroy();
    }
  }
  return best;
}

String? _hostFor(ConfigItem config, List<_ProbeEndpoint> endpoints) {
  if (endpoints.isNotEmpty) return endpoints.first.host;
  if (config.isTots && config.rawLink.trim().isNotEmpty) {
    final decoded = _decodeTots(config.rawLink);
    final host = decoded?['peer']?.toString().trim() ?? '';
    if (host.isNotEmpty) return host;
  }
  final raw = config.peer.trim();
  if (raw.isEmpty) return null;
  if (raw.startsWith('[')) {
    final end = raw.indexOf(']');
    if (end > 1) return raw.substring(1, end);
  }
  final colon = raw.lastIndexOf(':');
  if (colon > 0 && raw.indexOf(':') == colon) return raw.substring(0, colon);
  return raw;
}

Future<int?> _icmpPing(String host, {required Duration timeout}) async {
  final secs = timeout.inSeconds.clamp(1, 10);
  final args = Platform.isWindows
      ? <String>['-n', '1', '-w', '${timeout.inMilliseconds}', host]
      : (Platform.isMacOS || Platform.isIOS)
          ? <String>['-c', '1', '-t', '$secs', host]
          : <String>['-c', '1', '-W', '$secs', host];
  try {
    final result = await Process.run('ping', args)
        .timeout(timeout + const Duration(seconds: 1));
    if (result.exitCode != 0) return null;
    final output = '${result.stdout}\n${result.stderr}';
    final match = RegExp(
      r'(?:time|время)\s*[=<]\s*([0-9]+(?:[.,][0-9]+)?)\s*(?:ms|мс)',
      caseSensitive: false,
    ).firstMatch(output);
    if (match != null) {
      final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
      if (value != null) return value.ceil().clamp(1, 60000).toInt();
    }
    return null;
  } catch (_) {
    return null;
  }
}

List<_ProbeEndpoint> _endpointsFor(ConfigItem config) {
  final out = <_ProbeEndpoint>[];
  final direct = _parseHostPort(config.peer);
  if (direct != null) out.add(direct);
  if (config.isTots && config.rawLink.trim().isNotEmpty) {
    final decoded = _decodeTots(config.rawLink);
    if (decoded != null) {
      final host = (decoded['peer'] ?? config.peer).toString().trim();
      final webRtc = _asPort(decoded['webrtc_port']);
      final turn = _asPort(decoded['turn_port']);
      if (host.isNotEmpty && webRtc != null) {
        out.add(_ProbeEndpoint(host, webRtc));
      }
      if (host.isNotEmpty && turn != null && turn != webRtc) {
        out.add(_ProbeEndpoint(host, turn));
      }
    }
  }
  final seen = <String>{};
  return out.where((e) => seen.add('${e.host}:${e.port}')).toList();
}

_ProbeEndpoint? _parseHostPort(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end > 1 && end + 2 < s.length && s[end + 1] == ':') {
      final port = int.tryParse(s.substring(end + 2));
      if (port != null && port > 0 && port <= 65535) {
        return _ProbeEndpoint(s.substring(1, end), port);
      }
    }
    return null;
  }
  final colon = s.lastIndexOf(':');
  if (colon <= 0 || colon == s.length - 1) return null;
  final port = int.tryParse(s.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  return _ProbeEndpoint(s.substring(0, colon), port);
}

int? _asPort(Object? value) {
  final n =
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  return n != null && n > 0 && n <= 65535 ? n : null;
}

Map<String, dynamic>? _decodeTots(String raw) {
  final s = raw.trim();
  final idx = s.indexOf('://');
  if (idx < 0 || s.substring(0, idx).toLowerCase() != 'tots') return null;
  final payload = s.substring(idx + 3).trim();
  if (payload.isEmpty) return null;
  try {
    final normalized = base64Url.normalize(payload);
    final bytes = base64Url.decode(normalized);
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}
