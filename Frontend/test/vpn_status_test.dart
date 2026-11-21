import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/models/vpn_status.dart';

void main() {
  test('reads ToTS worker and traffic counters from backend status', () {
    final status = VpnStatus.fromJson({
      'state': 'connected',
      'connected': true,
      'uptimeSec': 42,
      'configId': 9,
      'rxBytes': 2048,
      'txBytes': 1024,
      'rxRate': 512,
      'txRate': 256,
      'workers': 8,
      'workersTarget': 10,
      'tunnelRttMs': 67,
      'workersVk': 3,
      'workersJazz': 2,
      'workersYaDocs': 1,
      'workersMailDocs': 1,
      'workersCups': 1,
      'activeSessions': 8,
    });

    expect(status.connected, isTrue);
    expect(status.rxBytes, 2048);
    expect(status.txBytes, 1024);
    expect(status.rxRate, 512);
    expect(status.txRate, 256);
    expect(status.workers, 8);
    expect(status.workersTarget, 10);
    expect(status.tunnelRttMs, 67);
    expect(VpnStatus.fromJson({}).tunnelRttMs, 0);
    expect(status.workersVk, 3);
    expect(status.workersJazz, 2);
    expect(status.workersYaDocs, 1);
    expect(status.workersMailDocs, 1);
    expect(status.workersCups, 1);
  });
}
