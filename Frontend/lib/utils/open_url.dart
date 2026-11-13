// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Открытие внешней ссылки (браузер / Telegram) на любой платформе.

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../api/api_client.dart';

/// Открывает http(s)-ссылку. Возвращает false, если открыть не удалось —
/// вызывающий может скопировать ссылку в буфер.
Future<bool> openExternalUrl(ApiClient api, String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
    return false;
  }
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await const MethodChannel('com.lalune/native')
          .invokeMethod('openUrl', {'url': uri.toString()});
      return true;
    }
    await api.postJson('/platform/open-url', {'url': uri.toString()});
    return true;
  } catch (_) {
    return false;
  }
}
