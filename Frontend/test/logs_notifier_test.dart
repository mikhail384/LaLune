import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/api/api_client.dart';
import 'package:lalune/models/settings.dart';
import 'package:lalune/state/logs_notifier.dart';
import 'package:lalune/state/providers.dart';
import 'package:lalune/state/settings_notifier.dart';

void main() {
  test('clear() sends DELETE /logs and empties both views', () async {
    await HttpOverrides.runZoned(() async {
      var cleared = false;
      final client = MockClient((request) async {
        if (request.url.path == '/settings') {
          return http.Response(jsonEncode(Settings().toJson()), 200);
        }
        if (request.url.path == '/logs' && request.method == 'DELETE') {
          cleared = true;
          return http.Response('{"ok":true}', 200);
        }
        // After DELETE the backend has nothing left to return.
        return http.Response(jsonEncode(cleared ? [] : ['[INFO] old line']), 200);
      });
      final container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
      ]);
      try {
        container.read(logsProvider.notifier).activate();
        await Future<void>.delayed(Duration.zero);
        expect(container.read(logsProvider).allLines, ['[INFO] old line']);

        await container.read(logsProvider.notifier).clear();
        expect(cleared, isTrue);
        expect(container.read(logsProvider).lines, isEmpty);
        expect(container.read(logsProvider).allLines, isEmpty);
      } finally {
        container.dispose();
        client.close();
      }
    }, createHttpClient: (_) => throw const SocketException('offline fixture'));
  });

  // The notifier always reads ALL lines (the short log is built from them);
  // the core-log toggle only decides what the detailed view shows.
  test('core-log toggle filters the detailed view, short log keeps all lines',
      () async {
    await HttpOverrides.runZoned(() async {
      var settings = Settings().toJson();
      final client = MockClient((request) async {
        if (request.url.path == '/settings') {
          if (request.method == 'PUT') {
            settings = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('{"ok":true}', 200);
          }
          return http.Response(jsonEncode(settings), 200);
        }
        expect(request.url.path, '/logs/tail');
        expect(request.url.queryParameters['lines'], '1200');
        expect(request.url.queryParameters['source'], 'all');
        return http.Response(
            jsonEncode([
              '[INFO] backend',
              '[CORE] history from logs.log',
            ]),
            200);
      });
      final container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
      ]);
      try {
        container.read(logsProvider.notifier).activate();
        await Future<void>.delayed(Duration.zero);
        var logs = container.read(logsProvider);
        expect(logs.lines, ['[INFO] backend']);
        expect(logs.allLines,
            ['[INFO] backend', '[CORE] history from logs.log']);

        final notifier = container.read(settingsProvider.notifier);
        expect(await notifier.save(Settings(showCoreLogs: true)), isTrue);
        await Future<void>.delayed(Duration.zero);
        logs = container.read(logsProvider);
        expect(logs.lines, contains('[CORE] history from logs.log'));

        expect(await notifier.save(Settings(showCoreLogs: false)), isTrue);
        await Future<void>.delayed(Duration.zero);
        logs = container.read(logsProvider);
        expect(logs.lines, ['[INFO] backend']);
        expect(logs.allLines.length, 2);
      } finally {
        container.dispose();
        client.close();
      }
    }, createHttpClient: (_) => throw const SocketException('offline fixture'));
  });
}
