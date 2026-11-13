// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Логи бэкенда + (опционально) ядра.
//
// Источник:
//   * /logs/tail?source=backend — только строки бэкенда
//   * /logs/tail?source=all     — все строки (backend + [CORE] ...)
//
// Переключатель "Показывать логи ядра" живёт в settingsProvider.
//
// ВАЖНО (исправление): showCoreLogs читается через отдельный
// `_showCoreLogsProvider` (Provider<bool>, который watch'ит settingsProvider).
// Это гарантирует, что при переключении toggle и сохранении:
//   1. logsProvider видит новое значение
//   2. _refresh() перечитывает /logs?source=all
//   3. SSE listener фильтрует по актуальному значению
// Плюс периодический опрос каждые 3 сек — на случай race condition.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'settings_notifier.dart';

const _maxLogLines = 150;

/// Сколько последних строк (включая ядро) хранить для короткого лога: он
/// сворачивает шум, поэтому окно должно быть заметно больше 150 строк.
const _maxAllLines = 1200;

/// Отдельный провайдер: true, если пользователь включил показ логов ядра.
final _showCoreLogsProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider).data.showCoreLogs;
});

class LogsState {
  /// Строки для подробного вида (как раньше: без ядра, если выключено, ≤150).
  final List<String> lines;

  /// Все строки (backend + ядро, ≤1200) — источник короткого лога.
  final List<String> allLines;
  final bool loading;

  const LogsState(
      {this.lines = const [], this.allLines = const [], this.loading = false});

  LogsState copyWith(
          {List<String>? lines, List<String>? allLines, bool? loading}) =>
      LogsState(
        lines: lines ?? this.lines,
        allLines: allLines ?? this.allLines,
        loading: loading ?? this.loading,
      );
}

class LogsNotifier extends StateNotifier<LogsState> {
  final Ref _ref;
  Timer? _poll;
  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _wsReconnect;
  int _wsGeneration = 0;
  StreamSubscription<String>? _baseUrlSub;
  ProviderSubscription<bool>? _showCoreLogsSub;
  int _refreshGeneration = 0;

  /// Опрос и WebSocket работают только пока открыта вкладка «Логи»: в фоне они
  /// зря грузили слабые телефоны (каждые 3 с — до 1200 строк).
  bool _active = false;
  final List<String> _buffer = [];
  Timer? _flush;

  LogsNotifier(this._ref) : super(const LogsState()) {
    // При смене baseUrl — переподключаем WebSocket и перечитываем.
    final api = _ref.read(apiClientProvider);
    _baseUrlSub = api.baseUrlChanges.listen((_) {
      _stopWebSocket();
      _buffer.clear();
      state = state.copyWith(lines: const [], allLines: const []);
      if (_active) {
        _startWebSocket();
        _refresh();
      }
    });

    // При смене showCoreLogs — перечитываем с нужным source.
    _showCoreLogsSub = _ref.listen<bool>(
      _showCoreLogsProvider,
      (prev, next) {
        if (prev != next) {
          // Переключатель влияет только на подробный вид: пересобираем его.
          _apply(state.allLines);
        }
      },
    );
  }

  /// Включает загрузку логов (вызывается, когда вкладка «Логи» на экране).
  void activate() {
    if (_active) return;
    _active = true;
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    _startWebSocket();
  }

  /// Останавливает фоновую загрузку (вкладка закрыта).
  void deactivate() {
    if (!_active) return;
    _active = false;
    _poll?.cancel();
    _poll = null;
    _flush?.cancel();
    _flush = null;
    _buffer.clear();
    _stopWebSocket();
  }

  /// Новые строки накапливаем и применяем не чаще раза в 300 мс: во время
  /// подключения ядро пишет сотни строк в секунду.
  void _enqueue(String line) {
    _buffer.add(line);
    _flush ??= Timer(const Duration(milliseconds: 300), () {
      _flush = null;
      if (!mounted || _buffer.isEmpty) return;
      final merged = [...state.allLines, ..._buffer];
      _buffer.clear();
      _apply(merged);
    });
  }

  /// Актуальное значение на каждый запрос.
  bool get _showCoreLogs => _ref.read(_showCoreLogsProvider);

  void _startWebSocket() {
    final generation = ++_wsGeneration;
    final api = _ref.read(apiClientProvider);
    final uri = Uri(
      scheme: 'ws',
      host: api.host,
      port: api.port,
      path: '/logs/ws',
    );

    WebSocket.connect(uri.toString()).then((socket) {
      if (generation != _wsGeneration) {
        socket.close();
        return;
      }
      _ws = socket;
      _wsSub = socket.listen(
        (raw) {
          if (generation != _wsGeneration || raw is! String) return;
          try {
            final message = jsonDecode(raw) as Map<String, dynamic>;
            if (message['type'] == 'snapshot') {
              final rawLines = (message['lines'] as List? ?? const [])
                  .map((line) => line.toString())
                  .where((line) => line.isNotEmpty)
                  .toList();
              _buffer.clear();
              _apply(rawLines);
            } else if (message['type'] == 'log') {
              final line = message['line'] as String? ?? '';
              if (line.isEmpty) return;
              final last = _buffer.isNotEmpty
                  ? _buffer.last
                  : (state.allLines.isNotEmpty ? state.allLines.last : null);
              if (last == line) return;
              _enqueue(line);
            }
          } catch (_) {
            // Ignore malformed messages and keep the connection alive.
          }
        },
        onDone: () => _scheduleWsReconnect(generation),
        onError: (_) => _scheduleWsReconnect(generation),
        cancelOnError: true,
      );
    }).catchError((_) {
      _scheduleWsReconnect(generation);
    });
  }

  void _scheduleWsReconnect(int generation) {
    if (generation != _wsGeneration || _wsReconnect?.isActive == true) return;
    _wsReconnect = Timer(const Duration(seconds: 2), () {
      if (generation == _wsGeneration) _startWebSocket();
    });
  }

  void _stopWebSocket() {
    _wsGeneration++;
    _wsReconnect?.cancel();
    _wsReconnect = null;
    _wsSub?.cancel();
    _wsSub = null;
    _ws?.close();
    _ws = null;
  }

  bool _isCoreLog(String line) {
    // Logs can have several prefixes, e.g. [LUA] [CORE] ... or [LUA] [SMART-TUNNEL] ...
    final tags = RegExp(r'\[([^\]]+)\]')
        .allMatches(line)
        .map((m) => m.group(1)!.toUpperCase());
    return tags.any((tag) =>
        tag == 'CORE' ||
        tag == 'CSQTT' ||
        tag == 'PAPERFLUX' ||
        tag == 'LUA' ||
        tag == 'SMART-TUNNEL' ||
        tag == 'WINTUN');
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    final api = _ref.read(apiClientProvider);
    // Read the current toggle for each request. Ignore older responses that
    // finish after a newer request (common when the toggle changes mid-flight).
    try {
      // Всегда читаем все строки: короткий лог строится из них, а подробный
      // вид отфильтровывает ядро по настройке в _apply().
      final list = await api.getJsonList('/logs/tail', query: {
        'lines': '$_maxAllLines',
        'source': 'all',
      });
      if (generation != _refreshGeneration) return;
      _apply(list.map((e) => e.toString()).toList());
    } catch (_) {}
  }

  /// Раскладывает полный список по двум представлениям.
  void _apply(List<String> all) {
    final allTail = all.length > _maxAllLines
        ? all.sublist(all.length - _maxAllLines)
        : all;
    final shown =
        _showCoreLogs ? allTail : allTail.where((l) => !_isCoreLog(l)).toList();
    state = state.copyWith(lines: _tail(shown), allLines: allTail);
  }

  List<String> _tail(List<String> lines) => lines.length > _maxLogLines
      ? lines.sublist(lines.length - _maxLogLines)
      : lines;

  Future<void> clear() async {
    final api = _ref.read(apiClientProvider);
    try {
      await api.deleteJson('/logs');
      state = state.copyWith(lines: [], allLines: []);
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    _flush?.cancel();
    _stopWebSocket();
    _baseUrlSub?.cancel();
    _showCoreLogsSub?.close();
    super.dispose();
  }
}

final logsProvider = StateNotifierProvider<LogsNotifier, LogsState>((ref) {
  return LogsNotifier(ref);
});
