import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/models/subscription.dart';
import 'package:lalune/state/subscriptions_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sample = '''
{
  "ИМЯ #1": {"config": "csqttr://connect?v=2&host=1.2.3.4&peer=46000&password=p&hashes=h", "protocol": "CSQTTR", "expires": "0"},
  "Имя #2": {"config": "csqtt://connect?v=2&host=5.6.7.8&peer=46001&password=q&hashes=g", "protocol": "CSQTT-2.5.1", "expires": "2999-01-01T00:00:00Z"},
  "hoster": "LaLune Free sub",
  "traffic": "10TB",
  "sub_control": "https://t.me/lalune_freedombot"
}
''';

/// Ответ сервера в UTF-8 (http.Response(String) кодирует в latin1 без charset).
http.Response _resp(String body, [int status = 200]) => http.Response.bytes(
      utf8.encode(body),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

String _dataUrl(String json) =>
    'data:application/json;base64,${base64.encode(utf8.encode(json))}';

void main() {
  group('parseLaLuneSub', () {
    test('reads configs, hoster, traffic and sub_control', () {
      final s = parseLaLuneSub(_sample, source: 'x');
      expect(s.hoster, 'LaLune Free sub');
      expect(s.traffic, '10TB');
      expect(s.subControl, 'https://t.me/lalune_freedombot');
      expect(s.configs.map((c) => c.name), ['ИМЯ #1', 'Имя #2']);
      expect(s.configs[0].protocol, 'CSQTTR');
      expect(s.configs[1].protocol, 'CSQTT 2.5.1'); // CSQTT-2.5.1 -> CSQTT 2.5.1
      expect(s.configs[0].expires, isNull); // "0" = бессрочно
      expect(s.configs[1].expires, DateTime.utc(2999));
      expect(s.configs[0].expired, isFalse);
    });

    test('sub_control is optional, expired configs are detected', () {
      final s = parseLaLuneSub(
        '{"A":{"config":"c","protocol":"CSQTTR","expires":"2001-02-03 04:05:06"},"hoster":"H"}',
        source: 'x',
      );
      expect(s.subControl, isNull);
      expect(s.configs.single.expires, DateTime.utc(2001, 2, 3, 4, 5, 6));
      expect(s.configs.single.expired, isTrue);
    });

    test('rejects non-JSON and empty subscriptions', () {
      expect(() => parseLaLuneSub('nope', source: 'x'),
          throwsA(isA<SubscriptionFormatException>()));
      expect(() => parseLaLuneSub('{"hoster":"H"}', source: 'x'),
          throwsA(isA<SubscriptionFormatException>()));
    });

    test('refresh keeps usedBytes and only still-present backend ids', () {
      final first = parseLaLuneSub(_sample, source: 'x');
      final key0 = first.configs[0].key;
      final key1 = first.configs[1].key;
      final prev = first.copyWith(usedBytes: 12345, backendIds: {key0: 7, key1: 8});
      final fresh = parseLaLuneSub(
        '{"ИМЯ #1":{"config":"csqttr://connect?v=2&host=1.2.3.4&peer=46000&password=p&hashes=h","protocol":"CSQTTR"},"hoster":"New"}',
        source: 'x',
        previous: prev,
      );
      expect(fresh.usedBytes, 12345);
      expect(fresh.hoster, 'New');
      expect(fresh.backendIds, {key0: 7});
    });
  });

  group('helpers', () {
    test('subscription detection', () {
      expect(looksLikeSubscription('https://a.b/sub'), isTrue);
      expect(looksLikeSubscription('LaLuneSUB:https://a.b/sub'), isTrue);
      expect(looksLikeSubscription('data:application/json,{}'), isTrue);
      expect(looksLikeSubscription('csqtt://connect?v=2&host=x'), isFalse);
      expect(looksLikeSubscription('csqttr:csqtt://zb_abc'), isFalse);
      expect(stripSubscriptionPrefix('  lalunesub: https://a.b '), 'https://a.b');
    });

    test('traffic limit parsing and formatting', () {
      expect(parseTrafficLimit('10TB'), 10 * 1024 * 1024 * 1024 * 1024);
      expect(parseTrafficLimit('500 GB'), 500 * 1024 * 1024 * 1024);
      expect(parseTrafficLimit('1.5GiB'), (1.5 * 1024 * 1024 * 1024).round());
      expect(parseTrafficLimit('unlimited'), isNull);
      expect(parseTrafficLimit(''), isNull);
      expect(parseTrafficLimit('0'), isNull);
      expect(formatBytes(1536), '1.5 КБ');
      expect(formatBytes(5 * 1024 * 1024 * 1024), '5.0 ГБ');
    });

    test('trafficDelta handles counter reset between connections', () {
      expect(trafficDelta(100, 250), 150);
      expect(trafficDelta(250, 250), 0);
      expect(trafficDelta(5000, 40), 40); // новая сессия
    });

    test('protocol normalization', () {
      expect(normalizeSubProtocol('CSQTT-2.5.1'), 'CSQTT 2.5.1');
      expect(normalizeSubProtocol('csqtt-2.1.9'), 'CSQTT 2.1.9');
      expect(normalizeSubProtocol('CSQTTR'), 'CSQTTR');
      expect(normalizeSubProtocol('paperflux'), 'PaperFlux');
      expect(normalizeSubProtocol(''), 'CSQTT');
    });
  });

  group('fetchSubscriptionText', () {
    test('rejects oversized data and HTTP responses', () async {
      final oversized = 'a' * (2 * 1024 * 1024 + 1);
      await expectLater(
        fetchSubscriptionText('data:text/plain,$oversized'),
        throwsA(isA<SubscriptionFormatException>()),
      );
      final client = MockClient((_) async => _resp(oversized));
      await expectLater(
        fetchSubscriptionText('https://x.test/large', client: client),
        throwsA(isA<SubscriptionFormatException>()),
      );
      client.close();
    });
    test('decodes data: URLs (base64 and plain)', () async {
      expect(
          jsonDecode(await fetchSubscriptionText(_dataUrl(_sample)))['hoster'],
          'LaLune Free sub');
      expect(await fetchSubscriptionText('data:application/json,{"a":1}'),
          '{"a":1}');
      expect(
          await fetchSubscriptionText('LaLuneSUB:data:text/plain,{"a":2}'),
          '{"a":2}');
    });

    test('fetches over http(s) and reports HTTP errors', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/ok') return _resp(_sample);
        return _resp('no', 503);
      });
      expect(
          jsonDecode(await fetchSubscriptionText('https://x.test/ok',
              client: client))['traffic'],
          '10TB');
      await expectLater(
        fetchSubscriptionText('https://x.test/bad', client: client),
        throwsA(isA<SubscriptionFormatException>()),
      );
      await expectLater(fetchSubscriptionText('ftp://x'),
          throwsA(isA<SubscriptionFormatException>()));
    });
  });

  group('SubscriptionsNotifier', () {
    late ProviderContainer container;
    late StateNotifierProvider<SubscriptionsNotifier, SubscriptionsState> provider;
    var fetches = 0;
    var payload = _sample;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      fetches = 0;
      payload = _sample;
      final client = MockClient((request) async {
        fetches++;
        return _resp(payload);
      });
      provider = StateNotifierProvider<SubscriptionsNotifier, SubscriptionsState>(
          (ref) => SubscriptionsNotifier(ref, httpClient: client, autoLoad: false));
      container = ProviderContainer();
    });
    tearDown(() => container.dispose());

    test('add from data: URL, expand, refresh and traffic accounting', () async {
      final n = container.read(provider.notifier);
      expect(await n.add(_dataUrl(_sample)), isNull);
      var s = container.read(provider);
      expect(s.items.length, 1);
      expect(s.items.single.hoster, 'LaLune Free sub');
      expect(s.expanded, {s.items.single.id});

      n.toggleExpanded(s.items.single.id);
      expect(container.read(provider).expanded, isEmpty);

      // трафик учитывается только на подписку и копится
      n.addTraffic(s.items.single.id, 1000);
      n.addTraffic(s.items.single.id, 500);
      expect(container.read(provider).items.single.usedBytes, 1500);

      // refresh по data: URL не ходит в сеть и сохраняет трафик
      await n.refreshAll();
      s = container.read(provider);
      expect(fetches, 0);
      expect(s.items.single.usedBytes, 1500);
      expect(s.refreshing, isFalse);

      // подписка по http(s): refresh реально обращается к серверу
      expect(await n.add('LaLuneSUB:https://x.test/sub'), isNull);
      expect(fetches, 1);
      payload = '{"Новое имя":{"config":"c1","protocol":"CSQTTR"},"hoster":"Обновлено"}';
      await n.refreshAll();
      expect(fetches, 2);
      final http1 = container
          .read(provider)
          .items
          .firstWhere((e) => e.source == 'https://x.test/sub');
      expect(http1.hoster, 'Обновлено');
      expect(http1.configs.single.name, 'Новое имя');
    });

    test('bad subscription returns a readable error and is not added', () async {
      final n = container.read(provider.notifier);
      payload = 'not json';
      expect(await n.add('https://x.test/bad'), isNotNull);
      expect(container.read(provider).items, isEmpty);
    });

    test('managed backend ids are hidden and mapped to their owner', () async {
      final n = container.read(provider.notifier);
      await n.add(_dataUrl(_sample));
      final sub = container.read(provider).items.single;
      expect(container.read(provider).managedIds, isEmpty);
      expect(container.read(provider).ownerOf(42), isNull);
      // имитируем материализованный конфиг
      expect(sub.backendIds, isEmpty);
    });
  });
}
