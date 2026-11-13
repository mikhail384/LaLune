// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Backend watchdog: только НАБЛЮДАЕТ за /ping и отдаёт статус для баннера.
//
// Перезапуском backend на Android владеет единственный компонент —
// MainActivity (single-flight, startup grace, backoff). Dart сюда не лезет,
// чтобы два watchdog не перезапускали backend параллельно.
//
// Статус `dead` выставляется только после нескольких подряд неудачных
// проверок и не раньше окончания startup grace: на холодном старте и при
// коротком сбое баннер «Backend offline» не мигает.

import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'state/providers.dart';

enum BackendStatus { unknown, alive, dead }

class BackendWatchdog extends StateNotifier<BackendStatus> {
  static const Duration _interval = Duration(seconds: 3);
  static const Duration _startupGrace = Duration(seconds: 20);
  static const int _failuresBeforeDead = 3;

  final Ref _ref;
  Timer? _timer;
  final Stopwatch _sinceStart = Stopwatch()..start();
  bool _checking = false;
  int _failures = 0;

  BackendWatchdog(this._ref) : super(BackendStatus.unknown) {
    _tick();
    _timer = Timer.periodic(_interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_checking) return; // не копим параллельные проверки
    _checking = true;
    try {
      final alive = await _ref.read(apiClientProvider).ping();
      if (!mounted) return;
      if (alive) {
        if (_failures > 0) debugPrint('[watchdog] backend reachable again');
        _failures = 0;
        if (state != BackendStatus.alive) state = BackendStatus.alive;
        return;
      }
      _failures++;
      final inGrace = _sinceStart.elapsed < _startupGrace;
      if (state == BackendStatus.alive || !inGrace) {
        if (_failures >= _failuresBeforeDead && state != BackendStatus.dead) {
          debugPrint('[watchdog] backend unreachable ($_failures checks)');
          state = BackendStatus.dead;
        }
      }
    } finally {
      _checking = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final backendWatchdogProvider =
    StateNotifierProvider<BackendWatchdog, BackendStatus>((ref) {
  return BackendWatchdog(ref);
});

/// Утилита для проверки «жив ли API прямо сейчас».
Future<bool> isBackendAlive(ApiClient api) => api.ping();
