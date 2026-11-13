// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Не даёт экрану телефона гаснуть, пока выполняется долгая операция
// (установка на роутер). Работает на Android; на других платформах ничего не делает.

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

Future<void> setKeepScreenOn(bool enabled) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await const MethodChannel('com.lalune/native')
        .invokeMethod('keepScreenOn', {'enabled': enabled});
  } catch (_) {
    // Нет канала (тесты, не Android) — не критично.
  }
}