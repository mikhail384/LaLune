// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/utils/profile_ping.dart';

void main() {
  const profiles = [
    PingProfile('config:1', 1),
    PingProfile('sub:2', 2, link: 'csqtt://example', protocol: 'CSQTT'),
    PingProfile('config:3', 3),
  ];

  test(
    'idle VPN measures sequentially and continues after a failed probe',
    () async {
      final first = Completer<int?>();
      final requests = <Map<String, dynamic>>[];
      final batch = measurePings(
        profiles: profiles,
        connected: false,
        activeId: 0,
        canContinue: () => true,
        measure: (body) async {
          requests.add(body);
          return requests.length == 1 ? first.future : 30;
        },
      );
      expect(requests, [
        {'configId': 1, 'temporary': true},
      ]);
      first.complete(null);
      final result = await batch;
      expect(requests, [
        {'configId': 1, 'temporary': true},
        {'link': 'csqtt://example', 'protocol': 'CSQTT', 'temporary': true},
        {'configId': 3, 'temporary': true},
      ]);
      expect(result.attempted, {'config:1', 'sub:2', 'config:3'});
      expect(result.latencies, {'sub:2': 30, 'config:3': 30});
    },
  );

  test('connected VPN sends only an active-profile probe', () async {
    final requests = <Map<String, dynamic>>[];
    final result = await measurePings(
      profiles: profiles,
      connected: true,
      activeId: 2,
      canContinue: () => true,
      measure: (body) async {
        requests.add(body);
        return 15;
      },
    );
    expect(requests, [
      {'configId': 2, 'temporary': false},
    ]);
    expect(result.attempted, {'sub:2'});
    expect(result.latencies, {'sub:2': 15});
  });

  test(
    'an unknown active profile never falls back to temporary probes',
    () async {
      for (final id in [0, 123]) {
        final result = await measurePings(
          profiles: profiles,
          connected: true,
          activeId: id,
          canContinue: () => true,
          measure: (_) async => throw StateError('unexpected probe'),
        );
        expect(result.attempted, isEmpty);
        expect(result.latencies, isEmpty);
      }
    },
  );

  test('backend switch stops the remaining queue', () async {
    var currentBackend = true;
    final result = await measurePings(
      profiles: profiles,
      connected: false,
      activeId: 0,
      canContinue: () => currentBackend,
      measure: (body) async {
        currentBackend = false;
        return null;
      },
    );
    expect(result.attempted, {'config:1'});
  });
}
