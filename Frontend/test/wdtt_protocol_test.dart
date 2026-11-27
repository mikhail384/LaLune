// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// WDTToR — обратно совместимый с WDTT протокол. Проверяем то, что видит
// пользователь: распознавание ссылки, подпись «WDTToR (WDTT)» в списке
// профилей и сериализацию настроек.

import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/models/config_item.dart';
import 'package:lalune/models/settings.dart';
import 'package:lalune/models/subscription.dart';
import 'package:lalune/utils/config_input.dart';

void main() {
  const realLink =
      'wdtt://82.40.38.237:56005:56006:9000:uVCF2Nf6dZK8hEKe:'
      'sBvxpZXkz_CAoAstXFslhAZmukJ8rI54l8sJDEbQOO4,'
      'BRtpXEy74qSrZ-6A6QS5THpi9qoQx7-4JzBRWU4f9Q0,'
      'Yb_jusGtRZxh3MFVSmbOqVb6cZm5McRKzrH4YPWE_xM';

  group('detectConfigInput', () {
    test('detects a wdtt:// link as WDTToR', () {
      final detected = detectConfigInput(realLink);
      expect(detected, isNotNull);
      expect(detected!.protocol, 'WDTToR');
      expect(detected.isSubscription, isFalse);
      expect(detected.payload, realLink);
    });

    test('accepts a captioned link', () {
      final detected = detectConfigInput('WDTToR (WDTT): $realLink');
      expect(detected?.protocol, 'WDTToR');
      expect(detected?.payload, realLink);
    });

    test('does not confuse wdtt:// with csqtt://', () {
      expect(detectConfigInput('csqtt://connect?v=2')?.protocol, isNot('WDTToR'));
    });
  });

  group('ConfigItem', () {
    ConfigItem item(String protocol) =>
        ConfigItem(id: 1, protocol: protocol, rawLink: realLink);

    test('recognizes WDTToR ids', () {
      for (final id in ['WDTToR', 'wdtto', 'WDTT', 'WDTToR (WDTT)']) {
        expect(item(id).isWdtt, isTrue, reason: id);
      }
      expect(item('ToTS').isWdtt, isFalse);
      expect(item('CSQTT 2.5.1').isWdtt, isFalse);
    });

    test('shows the WDTToR (WDTT) label', () {
      expect(item('WDTToR').protocolLabel, 'WDTToR (WDTT)');
      // Other protocols keep their id as the label.
      expect(item('ToTS').protocolLabel, 'ToTS');
      expect(item('CSQTT 2.5.1').protocolLabel, 'CSQTT 2.5.1');
    });
  });

  group('subscriptions', () {
    test('normalizes WDTToR aliases', () {
      for (final raw in ['WDTToR', 'wdtt', 'WDTT', 'WDTToR (WDTT)', 'wdtto']) {
        expect(normalizeSubProtocol(raw), 'WDTToR', reason: raw);
      }
    });

    test('keeps ToTS and CSQTT untouched', () {
      expect(normalizeSubProtocol('ToTS'), 'ToTS');
      expect(normalizeSubProtocol('CSQTTR'), 'CSQTTR');
    });
  });

  group('Settings', () {
    test('has WDTToR defaults', () {
      final s = Settings();
      expect(s.wdttWorkers, 9);
      expect(s.wdttObfs, 'audio');
      expect(s.wdttVkAuthMode, 'manual');
      expect(s.wdttLocalPort, 9000);
      expect(s.wdttDeviceId, isEmpty);
    });

    test('round-trips WDTToR fields through JSON', () {
      final original = Settings().copyWith(
        wdttWorkers: 18,
        wdttObfs: 'video',
        wdttVkAuthMode: 'autoApi',
        wdttLocalPort: 9100,
        wdttDeviceId: 'device-42',
      );
      final restored = Settings.fromJson(original.toJson());
      expect(restored.wdttWorkers, 18);
      expect(restored.wdttObfs, 'video');
      expect(restored.wdttVkAuthMode, 'autoApi');
      expect(restored.wdttLocalPort, 9100);
      expect(restored.wdttDeviceId, 'device-42');
    });

    test('clamps out-of-range values from the backend', () {
      final json = Settings().toJson()
        ..['wdttWorkers'] = 5
        ..['wdttLocalPort'] = 1;
      final restored = Settings.fromJson(json);
      expect(restored.wdttWorkers, 9, reason: 'minimum is one group of 9');
      expect(restored.wdttLocalPort, 1, reason: 'port 1 is valid');
    });

    test('rejects absurd worker counts', () {
      final json = Settings().toJson()..['wdttWorkers'] = 100000;
      expect(Settings.fromJson(json).wdttWorkers, 108);
    });
  });
}
