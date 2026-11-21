import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/theme/cached_glass.dart';
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

  testWidgets('cached glass keeps its wallpaper aligned during scrolling', (
    tester,
  ) async {
    final wallpaper = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..drawRect(
          const Rect.fromLTWH(0, 0, 160, 120),
          Paint()..color = const Color(0xFFFF0000),
        )
        ..drawRect(
          const Rect.fromLTWH(0, 120, 160, 120),
          Paint()..color = const Color(0xFF0000FF),
        );
      final picture = recorder.endRecording();
      final image = await picture.toImage(160, 240);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      image.dispose();
      picture.dispose();
      return MemoryImage(png.buffer.asUint8List());
    });
    final boundaryKey = GlobalKey();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 160,
            height: 240,
            child: RepaintBoundary(
              key: boundaryKey,
              child: CachedGlassBackdrop(
                wallpaper: wallpaper!,
                tint: const LinearGradient(
                  colors: [Colors.transparent, Colors.transparent],
                ),
                child: ColoredBox(
                  color: Colors.green,
                  child: SingleChildScrollView(
                    controller: controller,
                    child: Column(
                      children: [
                        const SizedBox(height: 160),
                        Builder(
                          builder:
                              (context) => RepaintBoundary(
                                child: SizedBox(
                                  width: 80,
                                  height: 40,
                                  child: ClipRect(
                                    child: CachedGlassBackdrop.sample(
                                      context,
                                      14,
                                    ),
                                  ),
                                ),
                              ),
                        ),
                        const SizedBox(height: 180),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final follower = find.byType(CompositedTransformFollower);
    for (var i = 0; i < 50 && follower.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(follower, findsOneWidget);

    Future<void> expectPixel(int y, int red, int blue) async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final channels = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData())!;
        final index = (y * image.width + 80) * 4;
        final channels = [bytes.getUint8(index), bytes.getUint8(index + 2)];
        image.dispose();
        return channels;
      });
      expect(channels, [closeTo(red, 4), closeTo(blue, 4)]);
    }

    await expectPixel(180, 0, 255);
    controller.jumpTo(120);
    await tester.pump();
    await expectPixel(60, 255, 0);
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
