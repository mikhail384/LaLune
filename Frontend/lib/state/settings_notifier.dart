// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Настройки. deviceId удалён — новый CSQTT его не использует.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_exception.dart';
import '../models/settings.dart';
import 'providers.dart';

class SettingsState {
  final Settings data;
  final bool loading;
  final String? error;

  const SettingsState({
    required this.data,
    this.loading = false,
    this.error,
  });

  SettingsState copyWith({
    Settings? data,
    bool? loading,
    String? error,
    bool clearError = false,
  }) =>
      SettingsState(
        data: data ?? this.data,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}

String _settingsErrorText(Object error) =>
    error is ApiException ? error.message : error.toString();

class SettingsNotifier extends StateNotifier<SettingsState> {
  final Ref _ref;
  StreamSubscription<String>? _baseUrlSub;
  int _revision = 0;
  bool _disposed = false;

  SettingsNotifier(this._ref) : super(SettingsState(data: Settings())) {
    // При смене baseUrl (подключение/отключение роутера) — перезагружаем.
    final api = _ref.read(apiClientProvider);
    _baseUrlSub = api.baseUrlChanges.listen((_) {
      reload();
    });
  }

  Future<void> reload() async {
    final revision = ++_revision;
    state = state.copyWith(loading: true, clearError: true);
    final api = _ref.read(apiClientProvider);
    final baseUrl = api.baseUrl;
    try {
      final j = await api.getJson('/settings');
      if (_disposed || revision != _revision || api.baseUrl != baseUrl) return;
      state = state.copyWith(
        data: Settings.fromJson(j),
        loading: false,
        clearError: true,
      );
    } catch (e) {
      if (_disposed || revision != _revision || api.baseUrl != baseUrl) return;
      state = state.copyWith(loading: false, error: _settingsErrorText(e));
    }
  }

  Future<bool> save(Settings s) async {
    final revision = ++_revision;
    state = state.copyWith(clearError: true);
    final api = _ref.read(apiClientProvider);
    final baseUrl = api.baseUrl;
    try {
      await api.putJson('/settings', s.toJson());
      if (_disposed || revision != _revision || api.baseUrl != baseUrl) {
        return false;
      }

      // Read back the desktop-only flag that historically got dropped by API
      // targets which did not know about it (notably OpenWRT). Mobile backends
      // intentionally do not expose this desktop-only setting.
      final isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;
      var savedSettings = s;
      if (isDesktop) {
        var persisted = await api.getJson('/settings');
        if (_disposed || revision != _revision || api.baseUrl != baseUrl) {
          return false;
        }
        var persistedMode = persisted['desktopSocks5Mode'];
        if (persistedMode is! bool || persistedMode != s.desktopSocks5Mode) {
          await api.patchJson('/settings', {
            'desktopSocks5Mode': s.desktopSocks5Mode,
          });
          if (_disposed || revision != _revision || api.baseUrl != baseUrl) {
            return false;
          }
          persisted = await api.getJson('/settings');
          if (_disposed || revision != _revision || api.baseUrl != baseUrl) {
            return false;
          }
          persistedMode = persisted['desktopSocks5Mode'];
        }

        savedSettings = Settings.fromJson(persisted);
        if (persistedMode is! bool ||
            persistedMode != s.desktopSocks5Mode ||
            savedSettings.ipRoutingMode != s.ipRoutingMode ||
            savedSettings.ipRoutingIps != s.ipRoutingIps ||
            savedSettings.showCoreLogs != s.showCoreLogs) {
          throw StateError('Настройки не подтверждены бэкендом');
        }
      }

      if (_disposed || revision != _revision || api.baseUrl != baseUrl) {
        return false;
      }
      state = state.copyWith(data: savedSettings, clearError: true);
      return true;
    } catch (e) {
      if (_disposed || revision != _revision || api.baseUrl != baseUrl) {
        return false;
      }
      state = state.copyWith(error: _settingsErrorText(e));
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _baseUrlSub?.cancel();
    super.dispose();
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier(ref);
});
