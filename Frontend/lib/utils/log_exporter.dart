// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Хранилище последнего полного диагностического лога OpenWRT.
class OpenWrtDiagnosticStore {
  static const _kLogKey = 'lalune_openwrt_last_full_log';
  static const _kTimeKey = 'lalune_openwrt_last_full_log_at';

  static String _memoryLog = '';
  static String _memoryTime = '';

  static Future<void> save(String log) async {
    final now = DateTime.now().toIso8601String();
    _memoryLog = log;
    _memoryTime = now;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLogKey, log);
      await prefs.setString(_kTimeKey, now);
    } catch (_) {}
  }

  static Future<({String log, String savedAt})> load() async {
    if (_memoryLog.isNotEmpty) {
      return (log: _memoryLog, savedAt: _memoryTime);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final log = prefs.getString(_kLogKey) ?? '';
      final savedAt = prefs.getString(_kTimeKey) ?? '';
      _memoryLog = log;
      _memoryTime = savedAt;
      return (log: log, savedAt: savedAt);
    } catch (_) {
      return (log: '', savedAt: '');
    }
  }
}

String _timestampForFileName() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

/// Создаёт .txt файл во временной директории и открывает системное меню
/// «Поделиться» (Telegram, почта, файлы и др.). Возвращает путь к файлу.
Future<String> shareLogAsTxtFile({
  required String content,
  required String prefix,
  String? subject,
}) async {
  final fileName = '${prefix}_${_timestampForFileName()}.txt';
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsString(content, encoding: utf8, flush: true);

  if (!kIsWeb) {
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/plain', name: fileName)],
      subject: subject ?? 'LaLune diagnostic log',
      text: subject ?? 'LaLune log ($fileName)',
    );
  }
  return file.path;
}
