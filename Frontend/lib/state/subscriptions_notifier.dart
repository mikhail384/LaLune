// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Подписки LaLuneSUB: хранение, обновление, выбор конфига и учёт трафика.
//
// Конфиги подписки живут в самом приложении. Когда пользователь выбирает один
// из них, он «материализуется» в backend (POST /configs) и подключение идёт
// обычным путём. Эти служебные конфиги скрываются из списка обычных.
//
// Трафик считается по реальным счётчикам туннеля (/vpn/stats) и только пока
// подключён конфиг именно этой подписки.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_exception.dart';
import '../models/subscription.dart';
import 'configs_notifier.dart';
import 'providers.dart';
import 'vpn_notifier.dart';

const _prefsKey = 'lalune_subscriptions_v1';

class SubscriptionsState {
  final List<Subscription> items;
  final Set<String> expanded;
  final bool refreshing;

  const SubscriptionsState({
    this.items = const [],
    this.expanded = const {},
    this.refreshing = false,
  });

  SubscriptionsState copyWith({
    List<Subscription>? items,
    Set<String>? expanded,
    bool? refreshing,
  }) =>
      SubscriptionsState(
        items: items ?? this.items,
        expanded: expanded ?? this.expanded,
        refreshing: refreshing ?? this.refreshing,
      );

  /// id служебных backend-конфигов подписок (скрываются из списка обычных).
  Set<int> get managedIds => {
        for (final s in items) ...s.backendIds.values,
      };

  /// Подписка, которой принадлежит backend-конфиг.
  Subscription? ownerOf(int backendId) {
    for (final s in items) {
      if (s.backendIds.values.contains(backendId)) return s;
    }
    return null;
  }
}

class SubscriptionsNotifier extends StateNotifier<SubscriptionsState> {
  final Ref _ref;
  final http.Client? _httpClient;
  Timer? _tracker;
  Timer? _saveDebounce;

  /// Подписка, по конфигу которой запущено текущее подключение (null — нет).
  String? _activeSubId;
  int _lastTotal = 0;

  SubscriptionsNotifier(this._ref, {http.Client? httpClient, bool autoLoad = true})
      : _httpClient = httpClient,
        super(const SubscriptionsState()) {
    _tracker = Timer.periodic(const Duration(seconds: 5), (_) => _trackTraffic());
    if (autoLoad) _load();
  }

  // ---------------------------------------------------------------- storage

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Subscription.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (!mounted) return;
      state = state.copyWith(items: list);
      // Тихо обновляем при старте приложения.
      unawaited(refreshAll(silent: true));
    } catch (_) {
      // повреждённое хранилище не должно ломать запуск
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey, jsonEncode(state.items.map((s) => s.toJson()).toList()));
    } catch (_) {}
  }

  void _saveSoon() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 3), _save);
  }

  // ----------------------------------------------------------------- actions

  /// Добавляет подписку. Возвращает текст ошибки или null при успехе.
  Future<String?> add(String input) async {
    final source = stripSubscriptionPrefix(input);
    try {
      final text = await fetchSubscriptionText(source, client: _httpClient);
      final sub = parseLaLuneSub(text,
          source: source, previous: _byId(subscriptionIdFor(source)));
      final others =
          state.items.where((s) => s.id != sub.id).toList(growable: true);
      state = state.copyWith(
        items: [...others, sub],
        expanded: {...state.expanded, sub.id},
      );
      await _save();
      return null;
    } on SubscriptionFormatException catch (e) {
      return e.message;
    } catch (e) {
      return 'Не удалось добавить подписку: $e';
    }
  }

  /// Заново обращается к серверу / data:-URL за JSON каждой подписки.
  Future<void> refreshAll({bool silent = false}) async {
    if (state.refreshing || state.items.isEmpty) return;
    state = state.copyWith(refreshing: true);
    final updated = <Subscription>[];
    for (final old in state.items) {
      try {
        final text = await fetchSubscriptionText(old.source, client: _httpClient);
        final fresh = parseLaLuneSub(text, source: old.source, previous: old);
        // Конфиги, которых больше нет в подписке, убираем из backend.
        final removed = old.backendIds.entries
            .where((e) => !fresh.configs.any((c) => c.key == e.key));
        for (final e in removed) {
          await _deleteBackendConfig(e.value);
        }
        updated.add(fresh);
      } catch (e) {
        // сервер недоступен: оставляем прежние данные, показываем ошибку
        updated.add(old.copyWith(
            error: e is SubscriptionFormatException ? e.message : 'Нет связи с сервером подписки'));
      }
    }
    if (!mounted) return;
    state = state.copyWith(items: updated, refreshing: false);
    await _save();
    // Список backend мог измениться (удалили устаревшие служебные конфиги).
    unawaited(_ref.read(configsProvider.notifier).reload());
  }

  Future<void> remove(String id) async {
    final sub = _byId(id);
    if (sub == null) return;
    for (final backendId in sub.backendIds.values) {
      await _deleteBackendConfig(backendId);
    }
    state = state.copyWith(
      items: state.items.where((s) => s.id != id).toList(),
      expanded: {...state.expanded}..remove(id),
    );
    await _save();
    unawaited(_ref.read(configsProvider.notifier).reload());
  }

  void toggleExpanded(String id) {
    final next = {...state.expanded};
    if (!next.remove(id)) next.add(id);
    state = state.copyWith(expanded: next);
  }

  /// Гарантирует, что конфиг подписки есть в backend, и возвращает его id.
  Future<int?> materialize(Subscription sub, SubConfig config) async {
    final api = _ref.read(apiClientProvider);
    var existing = sub.backendIds[config.key];
    if (existing != null) {
      // Мог быть удалён вручную/после сброса данных — проверяем.
      try {
        final list = await api.getJsonList('/configs');
        final alive = list.any((e) => e is Map && (e['id'] as num?)?.toInt() == existing);
        if (alive) return existing;
      } catch (_) {
        return existing;
      }
    }
    try {
      final resp = await api.postJson('/configs', {
        'link': config.config,
        'protocol': config.protocol,
        'name': config.name,
      });
      final id = (resp['id'] as num?)?.toInt();
      if (id == null) return null;
      final ids = {...sub.backendIds, config.key: id};
      _replace(sub.copyWith(backendIds: ids));
      await _save();
      await _ref.read(configsProvider.notifier).reload();
      return id;
    } on ApiException {
      return null;
    }
  }

  // ----------------------------------------------------------------- traffic

  /// Вызывается при нажатии «Подключить»: учёт трафика пойдёт на эту подписку.
  void beginConnection(String? subId) {
    _activeSubId = subId;
    _lastTotal = 0;
  }

  Future<void> _trackTraffic() async {
    final subId = _activeSubId;
    if (subId == null) return;
    final vpn = _ref.read(vpnProvider);
    if (vpn.connected) {
      try {
        final j = await _ref.read(apiClientProvider).getJson('/vpn/stats');
        final total = ((j['rxBytes'] as num?) ?? 0).toInt() +
            ((j['txBytes'] as num?) ?? 0).toInt();
        final delta = trafficDelta(_lastTotal, total);
        _lastTotal = total;
        if (delta > 0) addTraffic(subId, delta);
      } catch (_) {}
    } else if (!_isTransition(vpn.state)) {
      // отключились — следующее подключение начнёт новый учёт
      _activeSubId = null;
      _lastTotal = 0;
    }
  }

  bool _isTransition(String s) => s == 'connecting' || s == 'checking';

  /// Добавляет израсходованный трафик подписке (открыто для тестов).
  void addTraffic(String subId, int bytes) {
    final sub = _byId(subId);
    if (sub == null || bytes <= 0) return;
    _replace(sub.copyWith(usedBytes: sub.usedBytes + bytes));
    _saveSoon();
  }

  // ----------------------------------------------------------------- helpers

  Subscription? _byId(String id) {
    for (final s in state.items) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _replace(Subscription next) {
    state = state.copyWith(
      items: [for (final s in state.items) s.id == next.id ? next : s],
    );
  }

  Future<void> _deleteBackendConfig(int id) async {
    try {
      await _ref.read(apiClientProvider).deleteJson('/configs/$id');
    } catch (_) {}
  }

  @override
  void dispose() {
    _tracker?.cancel();
    _saveDebounce?.cancel();
    super.dispose();
  }
}

final subscriptionsProvider =
    StateNotifierProvider<SubscriptionsNotifier, SubscriptionsState>((ref) {
  return SubscriptionsNotifier(ref);
});
