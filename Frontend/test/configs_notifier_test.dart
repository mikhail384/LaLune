import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/api/api_client.dart';
import 'package:lalune/state/configs_notifier.dart';
import 'package:lalune/state/providers.dart';

void main() {
  test('restores the backend-selected profile after a cold start', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/configs') {
        return http.Response(
          jsonEncode([
            {'id': 4, 'protocol': 'CSQTT 2.1.9'},
            {'id': 7, 'protocol': 'CSQTT 2.5.1'},
          ]),
          200,
        );
      }
      if (request.url.path == '/configs/selected') {
        return http.Response('{"id":7}', 200);
      }
      return http.Response('{"error":"unexpected request"}', 404);
    });
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
    ]);
    addTearDown(container.dispose);
    addTearDown(client.close);

    await container.read(configsProvider.notifier).reload();

    expect(container.read(configsProvider).selectedId, 7);
    expect(requests.map((request) => request.method), ['GET', 'GET']);
  });

  test('selects and persists the first profile if saved selection is missing',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/configs') {
        return http.Response(
          jsonEncode([
            {'id': 4, 'protocol': 'CSQTT 2.1.9'},
          ]),
          200,
        );
      }
      if (request.url.path == '/configs/selected' && request.method == 'GET') {
        return http.Response('{}', 200);
      }
      if (request.url.path == '/configs/selected' && request.method == 'PUT') {
        expect(jsonDecode(request.body), {'id': 4});
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('{"error":"unexpected request"}', 404);
    });
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
    ]);
    addTearDown(container.dispose);
    addTearDown(client.close);

    await container.read(configsProvider.notifier).reload();

    expect(container.read(configsProvider).selectedId, 4);
    expect(
      requests.map((request) => '${request.method} ${request.url.path}'),
      [
        'GET /configs',
        'GET /configs/selected',
        'PUT /configs/selected',
      ],
    );
  });

  test('treats a persisted profile as added if the response is lost', () async {
    const link = 'csqtt219://synthetic.invalid/test';
    final client = MockClient((request) async {
      if (request.url.path == '/configs' && request.method == 'POST') {
        return http.Response('{"error":"response lost"}', 500);
      }
      if (request.url.path == '/configs') {
        return http.Response(
          jsonEncode([
            {
              'id': 11,
              'protocol': 'CSQTT 2.1.9',
              'rawLink': link,
            },
          ]),
          200,
        );
      }
      if (request.url.path == '/configs/selected' && request.method == 'GET') {
        return http.Response('{}', 200);
      }
      if (request.url.path == '/configs/selected' && request.method == 'PUT') {
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('{"error":"unexpected request"}', 404);
    });
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(ApiClient(httpClient: client)),
    ]);
    addTearDown(container.dispose);
    addTearDown(client.close);

    final added =
        await container.read(configsProvider.notifier).add(link, 'CSQTT 2.1.9');

    expect(added, isTrue);
    expect(container.read(configsProvider).items.single.rawLink, link);
  });
}
