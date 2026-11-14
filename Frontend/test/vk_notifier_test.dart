import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/api/api_client.dart';
import 'package:lalune/state/providers.dart';
import 'package:lalune/state/vk_notifier.dart';

void main() {
  test('polls slowly when idle and promptly during login', () async {
    var requests = 0;
    var fetching = false;
    final client = MockClient((request) async {
      if (request.url.path == '/vk/token/login') {
        fetching = true;
        return http.Response('{"ok":true}', 200);
      }
      expect(request.url.path, '/vk/token/state');
      requests++;
      return http.Response(jsonEncode({'fetching': fetching}), 200);
    });
    final api = ApiClient(httpClient: client);
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
    ]);
    addTearDown(container.dispose);
    addTearDown(client.close);
    final notifier = container.read(vkProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, 1);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(requests, 1);
    api.setBaseUrl('192.0.2.10');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, 2);

    expect(await notifier.login(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, 3);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(requests, 4);
  });

  test('a stale idle response cannot overwrite a newly started login', () async {
    final first = Completer<http.Response>();
    var requests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/vk/token/login') {
        return http.Response('{"ok":true}', 200);
      }
      requests++;
      if (requests == 1) return first.future;
      return http.Response('{"fetching":true,"progress":25}', 200);
    });
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
    ]);
    addTearDown(container.dispose);
    addTearDown(client.close);
    final notifier = container.read(vkProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await notifier.login(), isTrue);
    first.complete(http.Response('{"fetching":false}', 200));
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(container.read(vkProvider).fetching, isTrue);
    expect(requests, greaterThanOrEqualTo(2));
  });
}
