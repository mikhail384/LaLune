import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/widgets/glass_card.dart';
import 'package:lalune/widgets/glass_dialog.dart';
import 'package:lalune/widgets/navbar.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android uses blur-free glass surfaces for smooth scrolling',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          const GlassCard(child: Text('Card')),
          const GlassAlertDialog(title: Text('Modal'), content: Text('Body')),
          NavBar(currentIndex: 0, onSelect: (_) {}),
        ]),
      ),
    ));

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('desktop cards share a blur only inside an explicit group',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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

  testWidgets('desktop modal glass stays independent from app backdrop group',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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
