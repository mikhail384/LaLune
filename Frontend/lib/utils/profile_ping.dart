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

/// Measures direct transport reachability without creating a TUN interface.
/// Uses ICMP RTT when available, or TCP connection time as a fallback.
/// This does not measure latency or throughput through a LaLune tunnel.
Future<int?> probeProfile(
  ConfigItem config, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final endpoints = _endpointsFor(config);
  final host = _hostFor(config, endpoints);
  if (host == null || !_validHost(host)) return null;
  final deadline = Stopwatch()..start();

  // Prefer a real one-shot ICMP ping. CSQTT/ToTS transports are commonly UDP,
  // so TCP-only probing would incorrectly mark reachable profiles as offline.
  const icmpBudget = Duration(milliseconds: 1500);
  final icmp = await _icmpPing(
    host,
    timeout: timeout < icmpBudget ? timeout : icmpBudget,
  );
  if (icmp != null) return icmp;

  // Some mobile/sandboxed systems do not expose the ping executable. In that
  // case try known TCP endpoints without ever creating a TUN.
  final remaining = timeout - deadline.elapsed;
  if (remaining <= Duration.zero) return null;
  final times = await Future.wait(
    endpoints.where((e) => _validHost(e.host)).map((endpoint) async {
      final watch = Stopwatch()..start();
      Socket? socket;
      try {
        socket = await Socket.connect(
          endpoint.host,
          endpoint.port,
          timeout: remaining,
        );
        return watch.elapsedMilliseconds.clamp(1, 60000).toInt();
      } catch (_) {
        return null;
      } finally {
        socket?.destroy();
      }
    }),
  );
  int? best;
  for (final ms in times.whereType<int>()) {
    if (best == null || ms < best) best = ms;
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
  if (timeout <= Duration.zero) return null;
  final args =
      Platform.isWindows
          ? <String>['-n', '1', '-w', '${timeout.inMilliseconds}', host]
          : <String>['-c', '1', host];
  Process? process;
  try {
    process = await Process.start(
      Platform.isAndroid ? '/system/bin/ping' : 'ping',
      args,
    );
    final output = await Future.wait([
      process.exitCode,
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join(),
      process.stderr.drain(),
    ]).timeout(timeout);
    if (output[0] != 0) return null;
    final match = RegExp(
      r'(?:time|время)\s*[=<]\s*([0-9]+(?:[.,][0-9]+)?)\s*ms',
      caseSensitive: false,
    ).firstMatch(output[1] as String);
    if (match != null) {
      final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
      if (value != null) return value.ceil().clamp(1, 60000).toInt();
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    process?.kill();
  }
}

bool _validHost(String host) =>
    InternetAddress.tryParse(host) != null ||
    RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.-]*$').hasMatch(host);

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
      if (host.isNotEmpty && webRtc != null)
        out.add(_ProbeEndpoint(host, webRtc));
      if (host.isNotEmpty && turn != null && turn != webRtc) {
        out.add(_ProbeEndpoint(host, turn));
      }
    }
  }

  // Keep the order stable while removing duplicates.
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
  if (colon <= 0 || colon == s.length - 1 || s.indexOf(':') != colon)
    return null;
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
