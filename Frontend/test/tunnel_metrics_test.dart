import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/models/vpn_status.dart';
import 'package:lalune/widgets/tunnel_metrics.dart';

void main() {
  Future<void> showMetrics(WidgetTester tester, VpnStatus status) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 280,
            child: TunnelMetrics(status: status, isTots: true),
          ),
        ),
      ),
    ));
  }

  testWidgets('shows the actual counters, RTT and capped worker plan',
      (tester) async {
    final status = VpnStatus.fromJson({
      'workersRequested': 30,
      'workersTarget': 2,
      'workers': 2,
      'workerTargets': {'vk': 1, 'jazz': 1},
      'workersVk': 1,
      'workersJazz': 1,
      'tunnelRttMs': 47,
      'rxBytes': 2048,
      'rxRate': 256,
    });
    await showMetrics(tester, status);
    expect(find.text('256 Б/с'), findsOneWidget);
    expect(find.text('Всего 2.0 КиБ'), findsOneWidget);
    expect(find.text('47 мс'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('Запрошено 30 · доступно по профилю 2'), findsOneWidget);
    expect(find.text('VK 1 / 1'), findsOneWidget);
    expect(find.text('Jazz 1 / 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows pending counters independently of worker status',
      (tester) async {
    await showMetrics(tester, const VpnStatus(trafficAvailable: false));
    expect(find.text('Ожидание данных ToTS'), findsOneWidget);
    expect(find.text('Согласование'), findsOneWidget);
    expect(find.text('0 Б/с'), findsNothing);

    await showMetrics(
      tester,
      const VpnStatus(trafficRatesAvailable: false, rxBytes: 120),
    );
    expect(find.text('Замер…'), findsNWidgets(2));
    expect(find.text('Всего 120 Б'), findsOneWidget);
  });
}
