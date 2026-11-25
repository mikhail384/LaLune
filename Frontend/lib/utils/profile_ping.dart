// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import '../models/subscription.dart';

String configPingKey(int id) => 'config:$id';
String subConfigPingKey(String subId, SubConfig config) =>
    'sub:$subId:${config.key}';

/// A stored VPN profile or a subscription link that need not be persisted.
class PingProfile {
  final String key;
  final int? configId;
  final String? link;
  final String? protocol;

  const PingProfile(this.key, this.configId, {this.link, this.protocol});

  Map<String, dynamic> request({required bool temporary}) => {
    'temporary': temporary,
    if (!temporary || link == null) 'configId': configId,
    if (temporary && link != null) 'link': link,
    if (temporary && protocol != null) 'protocol': protocol,
  };
}

class PingResults {
  final Set<String> attempted = {};
  final Map<String, int> latencies = {};
}

/// A connected profile is the sole target, even if it differs from selection.
/// Temporary probes are strictly sequential; their API responses arrive only
/// after backend cleanup. Stop on transport errors (cleanup is not yet known)
/// or if a user/system connection takes over between probes.
Future<PingResults> measurePings({
  required Iterable<PingProfile> profiles,
  required bool connected,
  required int activeId,
  required Future<int?> Function(Map<String, dynamic>) measure,
  required bool Function() canContinue,
}) async {
  final result = PingResults();
  for (final profile in profiles) {
    if (connected && (profile.configId != activeId || activeId == 0)) continue;
    if (!canContinue()) break;
    result.attempted.add(profile.key);
    final latency = await measure(profile.request(temporary: !connected));
    if (latency != null) result.latencies[profile.key] = latency;
    if (connected) break;
  }
  return result;
}
