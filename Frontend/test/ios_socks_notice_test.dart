// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/widgets/ios_socks_notice.dart';

void main() {
  testWidgets('notice explains socks5 -> incy and closes with the button',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showIosSocksNotice(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Как работает VPN на iOS'), findsOneWidget);
    expect(find.textContaining('SOCKS5 → incy'), findsOneWidget);
    // Mentioned twice: why there is no system tunnel, and the call for help.
    expect(find.textContaining('Apple Developer'), findsNWidgets(2));
    expect(find.textContaining('incy'), findsWidgets);
    expect(find.textContaining('напишите в сообщения'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('Как работает VPN на iOS'), findsNothing);
  });

  testWidgets('exclamation button opens the notice', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: IosSocksNoticeButton())),
    ));

    await tester.tap(find.byType(IosSocksNoticeButton));
    await tester.pumpAndSettle();
    expect(find.text('Как работает VPN на iOS'), findsOneWidget);
  });
}
