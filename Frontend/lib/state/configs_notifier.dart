// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_exception.dart';
import '../models/config_item.dart';
import 'providers.dart';

class ConfigsState {
  final List<ConfigItem> items;
  final int? selectedId;
  final bool loading;
  final String? error;

  /// true только после УСПЕШНОГО ответа GET /configs. Пока false, пустой
  /// `items` — это «ещё не знаем», а не подтверждённый пустой список.
  final bool loaded;

  /// Ошибка именно ЗАГРУЗКИ списка (backend/API недоступен). `error` же
  /// остаётся для ошибок add/delete.
  final String? loadError;

  const ConfigsState({
    this.items = const [],
    this.selectedId,
    this.loading = true,
    this.error,
    this.loaded = false,
    this.loadError,
  });

  /// Подтверждённо пустой список (API ответил, конфигов нет).
  bool get confirmedEmpty => loaded && items.isEmpty;

  ConfigsState copyWith({
    List<ConfigItem>? items,
    int? selectedId,
    bool clearSelected = false,
    bool? loading,
    String? error,
    bool clearError = false,
    bool? loaded,
    String? loadError,
    bool clearLoadError = false,
  }) =>
      ConfigsState(
        items: items ?? this.items,
        selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        loaded: loaded ?? this.loaded,
        loadError: clearLoadError ? null : (loadError ?? this.loadError),
      );

  ConfigItem? get selected {
    if (selectedId == null) return null;
    for (final c in items) {
      if (c.id == selectedId) return c;
    }
    return null;
  }
}

String _configErrorText(Object error) =>
    error is ApiException ? error.message : error.toString();

class ConfigsNotifier extends StateNotifier<ConfigsState> {
  final Ref _ref;
  StreamSubscription<String>? _baseUrlSub;

  ConfigsNotifier(this._ref) : super(const ConfigsState()) {
    final api = _ref.read(apiClientProvider);
    _baseUrlSub = api.baseUrlChanges.listen((_) {
      // Другой хост (роутер <-> локальный backend): список прежнего хоста
      // не показываем и не смешиваем с новым.
      _retryTimer?.cancel();
      _retryAttempt = 0;
      state = const ConfigsState();
      reload();
    });
  }

  bool _reloadAgain = false;
  Timer? _retryTimer;
  int _retryAttempt = 0;
  static const List<int> _retryDelaysSec = [1, 2, 4, 8, 10];

  /// Повторная загрузка после восстановления backend: только если прошлая
  /// загрузка не удалась или ещё не состоялась. Если загрузка уже идёт —
  /// просто присоединяемся к ней, без лишнего второго прохода.
  Future<void> reloadIfNeeded() async {
    if (state.loaded && state.loadError == null) return;
    final running = _inFlight;
    if (running != null) return running;
    await reload();
  }

  /// Ограниченный по частоте автоповтор, пока список не загружен (backend
  /// ещё стартует или перезапускается). Останавливается при успехе.
  void _scheduleRetry() {
    _retryTimer?.cancel();
    final delay = _retryDelaysSec[
        _retryAttempt < _retryDelaysSec.length ? _retryAttempt : _retryDelaysSec.length - 1];
    _retryAttempt++;
    _retryTimer = Timer(Duration(seconds: delay), () {
      if (!mounted) return;
      reloadIfNeeded();
    });
  }

  Future<void>? _inFlight;

  Future<void> reload() {
    // Single-flight: параллельные reload() схлопываются в один повтор,
    // а вызывающий дожидается актуального результата.
    final running = _inFlight;
    if (running != null) {
      _reloadAgain = true;
      return running;
    }
    final f = () async {
      try {
        do {
          _reloadAgain = false;
          await _reloadOnce();
        } while (_reloadAgain && mounted);
      } finally {
        _inFlight = null;
      }
    }();
    _inFlight = f;
    return f;
  }

  Future<void> _reloadOnce() async {
    // Уже известные items/selectedId НЕ сбрасываем на время загрузки/ошибки.
    state = state.copyWith(loading: true, clearError: true);
    final api = _ref.read(apiClientProvider);
    try {
      final list = await api.getJsonList('/configs');
      final items = list
          .map((e) => ConfigItem.fromJson(e as Map<String, dynamic>))
          .toList();

      int? persistedSelectedId;
      try {
        final selected = await api.getJson('/configs/selected');
        final rawId = selected['id'];
        persistedSelectedId = rawId is num
            ? rawId.toInt()
            : int.tryParse(rawId?.toString() ?? '');
      } catch (_) {
        // Older router backends may not expose selected config state.
      }

      int? newSelected = state.selectedId;
      if (newSelected == null || !items.any((c) => c.id == newSelected)) {
        final persistedExists = persistedSelectedId != null &&
            items.any((c) => c.id == persistedSelectedId);
        newSelected = persistedExists
            ? persistedSelectedId
            : (items.isNotEmpty ? items.first.id : null);
        if (newSelected != null && newSelected != persistedSelectedId) {
          await _selectOnBackend(newSelected);
        }
      }

      state = state.copyWith(
        items: items,
        selectedId: newSelected,
        loading: false,
        loaded: true,
        clearError: true,
        clearLoadError: true,
      );
      _retryTimer?.cancel();
      _retryAttempt = 0;
    } catch (e) {
      if (!mounted) return;
      // Ошибка API — не «пустой список»: items и loaded остаются как были.
      final text = _configErrorText(e);
      state = state.copyWith(loading: false, error: text, loadError: text);
      _scheduleRetry();
    }
  }

  Future<void> select(int id) async {
    state = state.copyWith(selectedId: id);
    await _selectOnBackend(id);
  }

  Future<void> _selectOnBackend(int? id) async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.putJson('/configs/selected', id == null ? {} : {'id': id});
    } catch (_) {}
  }

  Future<bool> add(String link, String protocol) async {
    state = state.copyWith(clearError: true);
    final api = _ref.read(apiClientProvider);
    try {
      await api.postJson('/configs', {'link': link, 'protocol': protocol});
    } catch (e) {
      // Some backends can persist the profile and then fail while building
      // the response. Re-read the list before telling the user it failed.
      await reload();
      final normalizedLink = link.trim();
      final persisted =
          state.items.any((item) => item.rawLink.trim() == normalizedLink);
      if (persisted) return true;
      state = state.copyWith(error: _configErrorText(e));
      return false;
    }

    // A refresh failure must not turn a successful POST into a red error toast.
    await reload();
    return true;
  }

  Future<bool> delete(int id) async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.deleteJson('/configs/$id');
      if (state.selectedId == id) {
        await _selectOnBackend(null);
      }
      await reload();
      return true;
    } catch (e) {
      state = state.copyWith(error: _configErrorText(e));
      return false;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _baseUrlSub?.cancel();
    super.dispose();
  }
}

final configsProvider =
    StateNotifierProvider<ConfigsNotifier, ConfigsState>((ref) {
  // Без побочных эффектов: первая загрузка — ConnectionPage.initState, а
  // повтор при восстановлении backend — слушатель в RootShell (main.dart).
  return ConfigsNotifier(ref);
});
