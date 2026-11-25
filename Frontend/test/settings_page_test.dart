import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/api/api_client.dart';
import 'package:lalune/models/settings.dart';
import 'package:lalune/pages/settings_page.dart';
import 'package:lalune/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    testWidgets('manual VK sign-in and advanced options on $platform',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final client = MockClient((request) async {
        return http.Response(
          switch (request.url.path) {
            '/settings' => jsonEncode(Settings().toJson()),
            '/configs' => '[]',
            '/vk/token/state' => '{"hasToken":false}',
            _ => '{}',
          },
          200,
        );
      });
      addTearDown(client.close);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ));
      await tester.pumpAndSettle();

      final hashes = find.text('Хеши (через запятую или +)');
      final login = find.widgetWithText(OutlinedButton, 'Войти');
      expect(hashes, findsOneWidget);
      expect(login, findsOneWidget);
      expect(tester.getTopLeft(login).dy,
          greaterThan(tester.getBottomLeft(hashes).dy));

      // The page is a single ListView; a nested TextField must not make the
      // scroll target ambiguous.
      final list = find.byType(Scrollable).first;
      final sleep = find.text('Auto-sleep tunnel');
      if (platform == TargetPlatform.android) {
        await tester.scrollUntilVisible(sleep, 280, scrollable: list);
        expect(sleep, findsOneWidget);
      } else {
        await tester.scrollUntilVisible(find.text('Сохранить настройки'), 280,
            scrollable: list);
        expect(sleep, findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant({platform}));
  }
}
