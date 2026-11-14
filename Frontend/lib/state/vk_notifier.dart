// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vk_token_state.dart';
import 'providers.dart';

class VkNotifier extends StateNotifier<VkTokenState> {
  final Ref _ref;
  Timer? _poll;
  StreamSubscription<String>? _baseUrlSub;
  bool _refreshing = false;
  bool _refreshAgain = false;
  int _generation = 0;

  VkNotifier(this._ref) : super(VkTokenState.empty) {
    _refresh();

    final api = _ref.read(apiClientProvider);
    _baseUrlSub = api.baseUrlChanges.listen((_) {
      _generation++;
      _refresh();
    });
  }

  void _schedule(Duration delay) {
    _poll?.cancel();
    if (mounted) _poll = Timer(delay, _refresh);
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    final generation = _generation;
    final api = _ref.read(apiClientProvider);
    try {
      final j = await api.getJson('/vk/token/state');
      if (!mounted || generation != _generation) return;
      final next = VkTokenState.fromJson(j);
      if (next.hasToken != state.hasToken ||
          next.fetching != state.fetching ||
          next.progress != state.progress ||
          next.message != state.message) {
        state = next;
      }
    } catch (_) {
      // Keep the last state and retry without blocking the interface.
    } finally {
      _refreshing = false;
      if (mounted) {
        final immediate = _refreshAgain;
        _refreshAgain = false;
        _schedule(immediate ? Duration.zero : state.fetching
            ? const Duration(milliseconds: 500)
            : const Duration(seconds: 5));
      }
    }
  }

  Future<bool> login() async {
    _generation++;
    final api = _ref.read(apiClientProvider);
    try {
      // Бэкенд сам открывает WebView (Android/iOS) или запускает
      // Token.ps1/Token.sh (Desktop).
      await api.postJson('/vk/token/login', {});
      if (!mounted) return false;
      state = const VkTokenState(
        fetching: true,
        progress: 10,
        message: 'Открываю окно авторизации...',
      );
      _schedule(Duration.zero);
      return true;
    } catch (e) {
      if (mounted) {
        state = VkTokenState(message: '$e');
        _schedule(const Duration(seconds: 5));
      }
      return false;
    }
  }

  Future<bool> deleteToken() async {
    _generation++;
    final api = _ref.read(apiClientProvider);
    try {
      await api.deleteJson('/vk/token');
      if (!mounted) return false;
      state = VkTokenState.empty;
      _schedule(Duration.zero);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _baseUrlSub?.cancel();
    super.dispose();
  }
}

final vkProvider = StateNotifierProvider<VkNotifier, VkTokenState>((ref) {
  return VkNotifier(ref);
});
