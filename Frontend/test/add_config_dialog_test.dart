import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/pages/add_config_dialog.dart';

void main() {
  testWidgets('keeps the link field visible above a landscape keyboard',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return TextButton(
        onPressed: () => showAddConfigDialog(context),
        child: const Text('open'),
      );
    })));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(TextField));
    final viewport = tester.getRect(find.byType(SingleChildScrollView).last);
    expect(rect.bottom, lessThanOrEqualTo(370));
    expect(rect.top, greaterThanOrEqualTo(viewport.top));
    expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
  });
}
