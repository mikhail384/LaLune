import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/utils/config_input.dart';

void main() {
  group('detectConfigInput', () {
    test('detects VPN protocols by scheme', () {
      final csqttr = detectConfigInput('csqttr://abc');
      expect(csqttr?.protocol, 'CSQTTR');
      expect(csqttr?.payload, 'csqtt://abc');
      expect(detectConfigInput('tots://abc')?.protocol, 'ToTS');
      expect(detectConfigInput('csqtt://connect?v=2')?.protocol,
          'CSQTT 2.1.9');
      expect(detectConfigInput('csqtt://opaque-payload')?.protocol,
          'CSQTT 2.5.1');
    });

    test('keeps protocol captions used by existing backends', () {
      final latest =
          detectConfigInput('CSQTT 2.5.1: csqtt://opaque-payload');
      expect(latest?.protocol, 'CSQTT 2.5.1');
      expect(latest?.payload, 'csqtt://opaque-payload');

      final relay = detectConfigInput('csqttr:csqtt://connect?v=2&host=x');
      expect(relay?.protocol, 'CSQTTR');
      expect(relay?.payload, 'csqtt://connect?v=2&host=x');
    });

    test('detects HTTP and HTTPS subscriptions', () {
      for (final link in [
        'http://example.test/sub',
        'https://example.test/sub',
        'LaLuneSUB:http://example.test/sub',
      ]) {
        final detected = detectConfigInput(link);
        expect(detected?.isSubscription, isTrue);
        expect(detected?.protocol, 'LaLuneSUB');
      }
    });

    test('rejects unrelated QR text', () {
      expect(detectConfigInput('hello world'), isNull);
      expect(detectConfigInput('ftp://example.test/sub'), isNull);
    });
  });
}
