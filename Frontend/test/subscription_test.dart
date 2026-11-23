import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/api/api_client.dart';
import 'package:lalune/models/subscription.dart';
import 'package:lalune/models/vpn_status.dart';
import 'package:lalune/state/providers.dart';
import 'package:lalune/state/subscriptions_notifier.dart';
import 'package:lalune/state/vpn_notifier.dart';
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

class _TestVpnNotifier extends VpnNotifier {
  _TestVpnNotifier(Ref ref) : super(ref);

  void setStatus(VpnStatus next) => state = next;
}

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
      final prev = first.copyWith(usedBytes: 12345, backendIds: {key0: 7, key1: 8},
          trafficSessionId: 'fixture', trafficConfigId: 7,
          trafficCheckpointRx: 123, trafficCheckpointTx: 45);
      final fresh = parseLaLuneSub(
        '{"ИМЯ #1":{"config":"csqttr://connect?v=2&host=1.2.3.4&peer=46000&password=p&hashes=h","protocol":"CSQTTR"},"hoster":"New"}',
        source: 'x',
        previous: prev,
      );
      expect(fresh.usedBytes, 12345);
      expect(fresh.hoster, 'New');
      expect(fresh.backendIds, {key0: 7});
      expect(fresh.trafficSessionId, 'fixture');
      expect(fresh.trafficConfigId, 7);
      expect(fresh.trafficCheckpointRx, 123);
      expect(fresh.trafficCheckpointTx, 45);
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
      n.addDirectionalTraffic(s.items.single.id, 100, 50);
      expect(container.read(provider).items.single.usedBytes, 1650);
      expect(container.read(provider).items.single.receivedBytes, 100);
      expect(container.read(provider).items.single.sentBytes, 50);

      // refresh по data: URL не ходит в сеть и сохраняет трафик
      await n.refreshAll();
      s = container.read(provider);
      expect(fetches, 0);
      expect(s.items.single.usedBytes, 1650);
      expect(Subscription.fromJson(s.items.single.toJson()).receivedBytes, 100);
      expect(Subscription.fromJson(s.items.single.toJson()).sentBytes, 50);
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

    test('refresh preserves traffic and subscriptions added while fetching', () async {
      final pending = Completer<http.Response>();
      var requests = 0;
      final client = MockClient((_) {
        requests++;
        return requests == 1 ? Future.value(_resp(_sample)) : pending.future;
      });
      final p = StateNotifierProvider<SubscriptionsNotifier, SubscriptionsState>(
          (ref) => SubscriptionsNotifier(ref, httpClient: client, autoLoad: false));
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(p.notifier);
      await n.add('https://x.test/sub');
      final id = c.read(p).items.single.id;
      final refresh = n.refreshAll();
      n.addTraffic(id, 123);
      await n.add(_dataUrl(_sample));
      pending.complete(_resp(_sample));
      await refresh;
      expect(c.read(p).items, hasLength(2));
      expect(c.read(p).items.firstWhere((s) => s.id == id).usedBytes, 123);
      client.close();
    });

    test('pending traffic is saved when the notifier is disposed', () async {
      final c = ProviderContainer();
      final n = c.read(provider.notifier);
      await n.add(_dataUrl(_sample));
      final id = c.read(provider).items.single.id;
      n.addDirectionalTraffic(id, 17, 23);
      c.dispose();
      // Queued SharedPreferences writes run asynchronously after dispose.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('lalune_subscriptions_v1')!) as List;
      expect(saved.single['usedBytes'], 40);
      expect(saved.single['receivedBytes'], 17);
      expect(saved.single['sentBytes'], 23);
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

  test('restores active subscription tracking without counting old bytes twice', () async {
    final original = parseLaLuneSub(_sample, source: _dataUrl(_sample));
    final saved = original.copyWith(
      usedBytes: 400,
      receivedBytes: 250,
      sentBytes: 150,
      backendIds: {original.configs.first.key: 42},
    );
    SharedPreferences.setMockInitialValues({
      'lalune_subscriptions_v1': jsonEncode([saved.toJson()]),
    });
    var rx = 1000;
    var tx = 600;
    var failStats = true;
    Completer<http.Response>? pendingStats;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/vpn/status':
          return _resp('{"state":"connected","connected":true,"configId":42}');
        case '/vpn/stats':
          if (pendingStats != null) return pendingStats!.future;
          if (failStats) return _resp('temporary failure', 503);
          return _resp(jsonEncode({'rxBytes': rx, 'txBytes': tx}));
        default:
          return _resp('{}');
      }
    });
    final api = ApiClient(httpClient: client);
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      vpnProvider.overrideWith((ref) => _TestVpnNotifier(ref)),
    ]);
    addTearDown(() { container.dispose(); client.close(); });
    final notifier = container.read(subscriptionsProvider.notifier);
    final vpn = container.read(vpnProvider.notifier) as _TestVpnNotifier;
    vpn.setStatus(const VpnStatus(state: 'connected', connected: true, configId: 42));
    for (var i = 0; i < 50 && container.read(subscriptionsProvider).items.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(subscriptionsProvider).items, hasLength(1));

    await notifier.flushTraffic();
    expect(container.read(subscriptionsProvider).items.single.usedBytes, 400);
    failStats = false;
    await notifier.flushTraffic();
    expect(container.read(subscriptionsProvider).items.single.usedBytes, 400);
    rx += 25;
    tx += 10;
    await notifier.flushTraffic();
    final tracked = container.read(subscriptionsProvider).items.single;
    expect(tracked.usedBytes, 435);
    expect(tracked.receivedBytes, 275);
    expect(tracked.sentBytes, 160);

    // Switching to an ordinary configuration outside the UI must stop
    // attribution, and switching back establishes a fresh baseline.
    vpn.setStatus(const VpnStatus(state: 'connected', connected: true, configId: 99));
    rx = 5000;
    tx = 4000;
    await notifier.flushTraffic();
    expect(container.read(subscriptionsProvider).items.single.usedBytes, 435);
    vpn.setStatus(const VpnStatus(state: 'connected', connected: true, configId: 42));
    await notifier.flushTraffic();
    rx += 2;
    tx += 1;
    await notifier.flushTraffic();
    expect(container.read(subscriptionsProvider).items.single.usedBytes, 438);

    // A sample requested for an already tracked connection can also arrive
    // after another configuration becomes active.
    pendingStats = Completer<http.Response>();
    final activeSample = notifier.flushTraffic();
    await Future<void>.delayed(Duration.zero);
    vpn.setStatus(const VpnStatus(state: 'connected', connected: true, configId: 99));
    pendingStats!.complete(_resp(jsonEncode({'rxBytes': 9000, 'txBytes': 8000})));
    await activeSample;
    pendingStats = null;
    expect(container.read(subscriptionsProvider).items.single.usedBytes, 438);
    vpn.setStatus(const VpnStatus(state: 'connected', connected: true, configId: 42));

    // A delayed sample from the previous subscription must not attach its
    // counters after the active connection has switched to an ordinary config.
    notifier.beginConnection(null);
    pendingStats = Completer<http.Response>();
    final pendingSample = notifier.flushTraffic();
    await Future<void>.delayed(Duration.zero);
    vpn.setStatus(const VpnStatus(state: 'connected', connected: true, configId: 99));
    pendingStats!.complete(_resp(jsonEncode({'rxBytes': 5000, 'txBytes': 4000})));
    await pendingSample;
    pendingStats = null;
    await notifier.flushTraffic();
    expect(container.read(subscriptionsProvider).items.single.usedBytes, 438);
  });

  test('persists a matching tunnel checkpoint with subscription totals', () async {
    final original = parseLaLuneSub(_sample, source: _dataUrl(_sample));
    final saved = original.copyWith(
      usedBytes: 400, receivedBytes: 250, sentBytes: 150,
      backendIds: {original.configs.first.key: 42},
      trafficSessionId: 'fixture-session-a', trafficConfigId: 42,
      trafficCheckpointRx: 900, trafficCheckpointTx: 550,
    );
    SharedPreferences.setMockInitialValues({
      'lalune_subscriptions_v1': jsonEncode([saved.toJson()]),
    });
    var rx = 1000;
    var tx = 600;
    var session = 'fixture-session-a';
    var statsConfigId = 42;
    final client = MockClient((request) async {
      if (request.url.path == '/vpn/status') {
        return _resp('{"state":"connected","connected":true,"configId":42}');
      }
      if (request.url.path == '/vpn/stats') {
        return _resp(jsonEncode({'rxBytes': rx, 'txBytes': tx, 'sessionId': session,
          'configId': statsConfigId}));
      }
      return _resp('{}');
    });
    final api = ApiClient(httpClient: client);
    ProviderContainer makeContainer() => ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      vpnProvider.overrideWith((ref) => _TestVpnNotifier(ref)),
    ]);
    Future<void> waitForSubscriptions(ProviderContainer c) async {
      for (var i = 0; i < 50 && c.read(subscriptionsProvider).items.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(c.read(subscriptionsProvider).items, hasLength(1));
      (c.read(vpnProvider.notifier) as _TestVpnNotifier).setStatus(
        const VpnStatus(state: 'connected', connected: true, configId: 42));
    }

    var c = makeContainer();
    await waitForSubscriptions(c);
    await c.read(subscriptionsProvider.notifier).flushTraffic();
    var tracked = c.read(subscriptionsProvider).items.single;
    expect(tracked.usedBytes, 550);
    expect(tracked.trafficCheckpointRx, 1000);
    expect(tracked.trafficCheckpointTx, 600);
    c.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    rx = 1100;
    tx = 650;
    c = makeContainer();
    await waitForSubscriptions(c);
    await c.read(subscriptionsProvider.notifier).flushTraffic();
    tracked = c.read(subscriptionsProvider).items.single;
    expect(tracked.usedBytes, 700);
    expect(tracked.receivedBytes, 450);
    expect(tracked.sentBytes, 250);
    expect(tracked.trafficCheckpointRx, 1100);
    expect(tracked.trafficCheckpointTx, 650);

    // Backend switches before the next status refresh: counters explicitly
    // belonging to another profile must not be charged to this subscription.
    statsConfigId = 99;
    rx = 9000;
    tx = 8000;
    await c.read(subscriptionsProvider.notifier).flushTraffic();
    expect(c.read(subscriptionsProvider).items.single.usedBytes, 700);
    statsConfigId = 42;

    // A transient blank ID during backend rollover must not advance the
    // checkpoint or count the same counters twice on the next stable sample.
    session = '';
    rx = 1105;
    tx = 655;
    await c.read(subscriptionsProvider.notifier).flushTraffic();
    expect(c.read(subscriptionsProvider).items.single.usedBytes, 700);
    session = 'fixture-session-a';
    await c.read(subscriptionsProvider.notifier).flushTraffic();
    expect(c.read(subscriptionsProvider).items.single.usedBytes, 710);

    // A different session must never reuse the previous session's baseline.
    c.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    session = 'fixture-session-b';
    rx = 1500;
    tx = 900;
    c = makeContainer();
    await waitForSubscriptions(c);
    await c.read(subscriptionsProvider.notifier).flushTraffic();
    expect(c.read(subscriptionsProvider).items.single.usedBytes, 710);
    rx += 5;
    tx += 7;
    await c.read(subscriptionsProvider.notifier).flushTraffic();
    expect(c.read(subscriptionsProvider).items.single.usedBytes, 722);
    c.dispose();
    client.close();
  });

  test('refresh keeps a checkpoint recorded while an old profile is being removed', () async {
    final source = 'https://fixture.test/sub';
    final first = parseLaLuneSub(_sample, source: source);
    final saved = first.copyWith(
      usedBytes: 100, receivedBytes: 60, sentBytes: 40,
      backendIds: {first.configs[0].key: 42, first.configs[1].key: 43},
      trafficSessionId: 'fixture-session', trafficConfigId: 42,
      trafficCheckpointRx: 60, trafficCheckpointTx: 40,
    );
    SharedPreferences.setMockInitialValues({
      'lalune_subscriptions_v1': jsonEncode([saved.toJson()]),
    });
    final deleteStarted = Completer<void>();
    final deleteResponse = Completer<http.Response>();
    final apiHttp = MockClient((request) async {
      if (request.method == 'DELETE' && request.url.path == '/configs/43') {
        deleteStarted.complete();
        return deleteResponse.future;
      }
      if (request.url.path == '/vpn/status') {
        return _resp('{"state":"connected","connected":true,"configId":42}');
      }
      if (request.url.path == '/vpn/stats') {
        return _resp('{"rxBytes":80,"txBytes":50,"sessionId":"fixture-session"}');
      }
      if (request.url.path == '/configs') return _resp('[]');
      return _resp('{}');
    });
    final subHttp = MockClient((_) async => _resp(jsonEncode({
      'ИМЯ #1': {'config': first.configs[0].config, 'protocol': 'CSQTTR'},
      'hoster': 'updated',
    })));
    final api = ApiClient(httpClient: apiHttp);
    final provider = StateNotifierProvider<SubscriptionsNotifier, SubscriptionsState>(
      (ref) => SubscriptionsNotifier(ref, httpClient: subHttp));
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      vpnProvider.overrideWith((ref) => _TestVpnNotifier(ref)),
    ]);
    addTearDown(() { c.dispose(); apiHttp.close(); subHttp.close(); });
    final notifier = c.read(provider.notifier);
    (c.read(vpnProvider.notifier) as _TestVpnNotifier).setStatus(
      const VpnStatus(state: 'connected', connected: true, configId: 42));
    await deleteStarted.future.timeout(const Duration(seconds: 2));
    await notifier.flushTraffic();
    deleteResponse.complete(_resp('{}'));
    for (var i = 0; i < 50 && c.read(provider).refreshing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.read(provider).refreshing, isFalse);
    final updated = c.read(provider).items.single;
    expect(updated.usedBytes, 130);
    expect(updated.trafficSessionId, 'fixture-session');
    expect(updated.trafficCheckpointRx, 80);
    expect(updated.trafficCheckpointTx, 50);
  });
}
