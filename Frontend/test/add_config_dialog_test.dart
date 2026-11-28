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

  testWidgets('does not cover the page with a modal scrim', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return TextButton(
        onPressed: () => showAddConfigDialog(context),
        child: const Text('open-no-scrim'),
      );
    })));

    await tester.tap(find.text('open-no-scrim'));
    // Один pump только запускает переход маршрута: ModalBarrier появляется на
    // следующем кадре, поэтому прокручиваем анимацию открытия.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final barriers = tester.widgetList<ModalBarrier>(find.byType(ModalBarrier));
    expect(barriers, isNotEmpty, reason: 'the dialog route must own a barrier');
    // Замысел теста: диалог не затемняет страницу. Flutter представляет это
    // по-разному — barrierColor может быть null или прозрачным цветом, —
    // поэтому проверяем именно отсутствие видимой заливки.
    expect(
      barriers.every((barrier) {
        final color = barrier.color;
        return color == null || color.alpha == 0;
      }),
      isTrue,
      reason: 'the barrier must not darken the page',
    );
  });

}
