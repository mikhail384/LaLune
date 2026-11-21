import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/theme/ui_effects.dart';
import 'package:lalune/widgets/glass_card.dart';
import 'package:lalune/widgets/glass_dialog.dart';
import 'package:lalune/widgets/navbar.dart';

void main() {
  testWidgets('Android keeps glass blur on cards and the navigation bar',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      home: Scaffold(
        body: Column(children: [
          const GlassCard(child: Text('Card')),
          NavBar(currentIndex: 0, onSelect: (_) {}),
        ]),
      ),
    ));

    expect(
        find.descendant(
            of: find.byType(GlassCard), matching: find.byType(BackdropFilter)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(NavBar), matching: find.byType(BackdropFilter)),
        findsOneWidget);
  });

  testWidgets('cards share a blur only inside an explicit group',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          BackdropGroup(
            child: const Column(children: [
              GlassCard(child: Text('First')),
              GlassCard(child: Text('Second')),
            ]),
          ),
          const GlassCard(child: Text('Independent')),
        ]),
      ),
    ));

    final filters = find.byType(BackdropFilter);
    final first = tester.renderObject<RenderBackdropFilter>(filters.at(0));
    final second = tester.renderObject<RenderBackdropFilter>(filters.at(1));
    final independent =
        tester.renderObject<RenderBackdropFilter>(filters.at(2));
    expect(first.backdropKey, isNotNull);
    expect(second.backdropKey, same(first.backdropKey));
    expect(independent.backdropKey, isNull);
  });

  testWidgets('reduced effects keep surfaces and actions without live blur',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => UiEffects(
        reduceEffects: true,
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(children: [
            GlassCard(onTap: () => taps++, child: const Text('Card')),
            NavBar(
              currentIndex: 0,
              onSelect: (_) => showDialog<void>(
                context: context,
                builder: (context) => const GlassAlertDialog(
                  title: Text('Modal'),
                  content: Text('Content'),
                ),
              ),
            ),
          ]),
        ),
      ),
    ));

    await tester.tap(find.text('Card'));
    expect(taps, 1);
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Modal'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('modal glass stays independent from the app backdrop group',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackdropGroup(
            child: const GlassAlertDialog(
              title: Text('Modal'),
              content: Text('Content'),
            ),
          ),
        ),
      ),
    );

    final filter = tester.renderObject<RenderBackdropFilter>(
      find.descendant(
        of: find.byType(GlassAlertDialog),
        matching: find.byType(BackdropFilter),
      ),
    );
    expect(filter.backdropKey, isNull);
  });

}
