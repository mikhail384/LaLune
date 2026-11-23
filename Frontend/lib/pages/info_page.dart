// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../widgets/glass_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/update_info.dart';
import '../services/app_update.dart';
import '../state/providers.dart';
import '../theme/assets.dart';
import '../widgets/glass_card.dart';
import '../widgets/toast.dart';

class InfoPage extends ConsumerStatefulWidget {
  const InfoPage({super.key});

  @override
  ConsumerState<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends ConsumerState<InfoPage> {
  static const String _fallbackVersion = 'unknown';
  String _laluneVersion = _fallbackVersion;

  UpdateInfo _lalune = UpdateInfo.empty;
  bool _checkingLaLune = false;
  final _updater = AppUpdater();
  String _updateStatus = '';
  double? _downloadProgress;
  String? _downloadedUpdate;

  @override
  void dispose() {
    _updater.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_refreshAll);
  }

  Future<void> _refreshAll() async {
    final api = ref.read(apiClientProvider);

    // Show the version reported by the running backend, which CI stamps
    // with the exact release tag (stable version or STABLE-shortsha).
    try {
      final version = await api.getJson('/version');
      final value = (version['backend'] ?? version['ui'] ?? '').toString();
      if (value.isNotEmpty) {
        if (mounted) setState(() => _laluneVersion = value);
      }
    } catch (_) {}
  }

  Future<void> _manualCheckLaLune() async {
    setState(() {
      _checkingLaLune = true;
      _updateStatus = 'Проверяем релиз…';
      _downloadProgress = null;
      _downloadedUpdate = null;
    });
    try {
      final asset = await _updater.check();
      if (!mounted) return;
      setState(() {
        _lalune =
            UpdateInfo(remoteTag: asset.tag, localVersion: _laluneVersion);
        _updateStatus = 'Скачиваем ${asset.name}…';
      });
      var lastPercent = -1;
      final path = await _updater.download(asset, onProgress: (value) {
        final percent = (value * 100).floor();
        if (mounted && percent != lastPercent) {
          lastPercent = percent;
          setState(() => _downloadProgress = value);
        }
      });
      if (mounted)
        setState(() {
          _downloadedUpdate = path;
          _updateStatus =
              'Файл скачан: $path\nПодпись и версия пакета должны быть совместимы с установленным приложением.';
        });
    } catch (error) {
      if (mounted)
        setState(() => _updateStatus = 'Не удалось скачать обновление: $error');
    } finally {
      if (mounted)
        setState(() {
          _checkingLaLune = false;
          _downloadProgress = null;
        });
    }
  }

  // ============================================================
  //  QR-модалка
  // ============================================================

  Future<void> _showMaxQrDialog() async {
    final screenWidth = MediaQuery.of(context).size.width;
    final qrSize = math.min(screenWidth - 80, 420.0);

    await showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => GlassDialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.035),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Канал LaLune в MAX',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  Assets.maxQr,
                  width: qrSize,
                  height: qrSize,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Container(
                    width: qrSize,
                    height: qrSize,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.15)),
                    ),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.qr_code_2,
                              size: 64, color: Colors.white54),
                          SizedBox(height: 8),
                          Text('assets/max_qr.jpg',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.white38)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Отсканируйте QR-код, чтобы подписаться на канал',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5, color: Colors.white.withOpacity(0.65)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  //  UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            children: [
              const Text('🌙 LaLune',
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFE5484D))),
              const SizedBox(height: 4),
              Text('Client v$_laluneVersion',
                  style: TextStyle(color: Colors.white.withOpacity(0.5))),
              const SizedBox(height: 20),

              // LaLune
              _block('LaLune', [
                _kv('Установлено', _laluneVersion),
                _kv('Доступно',
                    _lalune.remoteTag.isEmpty ? '—' : _lalune.remoteTag),
              ]),
              _actionButton(
                label: _checkingLaLune
                    ? 'Проверка...'
                    : 'Проверить и скачать обновление',
                onTap: _checkingLaLune ? null : _manualCheckLaLune,
              ),
              if (_downloadProgress != null)
                LinearProgressIndicator(value: _downloadProgress),
              if (_updateStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(_updateStatus,
                      textAlign: TextAlign.center),
                ),
              if (_downloadedUpdate != null &&
                  defaultTargetPlatform == TargetPlatform.android)
                _actionButton(
                    label: 'Открыть установщик',
                    onTap: () async {
                      try {
                        await const MethodChannel('com.lalune/native')
                            .invokeMethod<void>('openDownloadedUpdate',
                                {'path': _downloadedUpdate});
                      } catch (_) {
                        if (mounted)
                          setState(() => _updateStatus =
                              'Не удалось открыть установщик. Файл: $_downloadedUpdate');
                      }
                    }),
              const SizedBox(height: 18),

              _block('Авторы', [
                _kv('CSQTT', 'amurcanov'),
                _kv('LaLune', '@Endlad7373'),
                _linkRow(
                    'Telegram-канал проекта', 't.me/endlad_new', _channelUrl,
                    icon: Icons.telegram),
              ]),
              const SizedBox(height: 18),

              _block('Ограничения интернета', [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'Если вы находитесь в белых списках или подобных '
                    'ограничениях интернета, при которых недоступен сайт '
                    'GitHub, а вам надо обновиться — используйте наш канал '
                    'в MAX. Туда выходят все апдейты.',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Colors.white.withOpacity(0.75)),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _showMaxQrDialog,
                    icon: const Icon(Icons.qr_code_2, size: 16),
                    label: const Text('Показать QR для канала MAX'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withOpacity(0.2)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _block(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 0.7,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withOpacity(0.4))),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  static const String _channelUrl = 'https://t.me/endlad_new';

  Future<void> _openUrl(String url) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await const MethodChannel('com.lalune/native')
            .invokeMethod('openUrl', {'url': url});
        return;
      }
      await ref
          .read(apiClientProvider)
          .postJson('/platform/open-url', {'url': url});
    } catch (_) {
      // Не удалось открыть — копируем ссылку, чтобы её можно было вставить.
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) Toast.show(context, 'Ссылка скопирована: $url');
    }
  }

  Widget _linkRow(String k, String label, String url, {IconData? icon}) {
    return InkWell(
      onTap: () => _openUrl(url),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 19, color: const Color(0xFF6C8CFF)),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(k,
                  style: TextStyle(color: Colors.white.withOpacity(0.65))),
            ),
            Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2FBF71),
                    decoration: TextDecoration.underline)),
            const SizedBox(width: 4),
            const Icon(Icons.open_in_new, size: 14, color: Color(0xFF2FBF71)),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(k,
                style: TextStyle(color: Colors.white.withOpacity(0.65))),
          ),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _actionButton({required String label, VoidCallback? onTap}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withOpacity(0.2)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label),
      ),
    );
  }
}
