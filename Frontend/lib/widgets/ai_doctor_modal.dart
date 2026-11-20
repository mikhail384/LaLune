// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../utils/ai_doctor_service.dart';
import 'glass_dialog.dart';

Future<void> showAiDoctorDialog(
  BuildContext context, {
  required String host,
  required String username,
  required String password,
  required String initialLog,
  required String errorMessage,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withOpacity(0.48),
    builder: (_) => _AiDoctorDialog(
      host: host,
      username: username,
      password: password,
      initialLog: initialLog,
      errorMessage: errorMessage,
    ),
  );
}

class _AiDoctorDialog extends StatefulWidget {
  final String host;
  final String username;
  final String password;
  final String initialLog;
  final String errorMessage;

  const _AiDoctorDialog({
    required this.host,
    required this.username,
    required this.password,
    required this.initialLog,
    required this.errorMessage,
  });

  @override
  State<_AiDoctorDialog> createState() => _AiDoctorDialogState();
}

class _AiDoctorDialogState extends State<_AiDoctorDialog> {
  final _urlCtl = TextEditingController();
  final _secretCtl = TextEditingController();

  bool _loading = true;
  bool _configuring = false;
  bool _busy = false;
  String _status = 'Загрузка настроек AI-Doctor...';
  String? _error;
  String? _oauthLoginUrl;
  AiDoctorPlan? _plan;
  final List<String> _history = [];
  late String _currentLog = widget.initialLog;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cfg = await AiDoctorSettings.load();
    _urlCtl.text = cfg.vpsUrl;
    _secretCtl.text = cfg.secret;
    if (!mounted) return;
    if (!cfg.isConfigured) {
      setState(() {
        _loading = false;
        _configuring = true;
      });
      return;
    }
    setState(() => _loading = false);
    await _runDiagnose();
  }

  Future<SSHClient> _openSsh() async {
    final socket = await SSHSocket.connect(
      widget.host,
      22,
      timeout: const Duration(seconds: 6),
    );
    final client = SSHClient(
      socket,
      username: widget.username,
      onPasswordRequest: () => widget.password,
      handshakeTimeout: const Duration(seconds: 12),
      authTimeout: const Duration(seconds: 12),
    );
    await client.authenticated;
    return client;
  }

  Future<void> _saveConfigAndStart() async {
    final cfg = AiDoctorSettings(
      vpsUrl: _urlCtl.text.trim(),
      secret: _secretCtl.text.trim(),
    );
    if (!cfg.isConfigured) {
      setState(() => _error = 'Укажите HTTPS-адрес вашего VPS');
      return;
    }
    await AiDoctorSettings.save(cfg);
    setState(() {
      _configuring = false;
      _error = null;
    });
    await _runDiagnose();
  }

  Future<void> _runDiagnose() async {
    final cfg = await AiDoctorSettings.load();
    setState(() {
      _busy = true;
      _error = null;
      _oauthLoginUrl = null;
      _plan = null;
      _status = 'Проверка Google OAuth на VPS...';
    });
    try {
      final auth = await AiDoctorService.checkAuthStatus(cfg);
      if (!auth.authenticated) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _oauthLoginUrl = auth.loginUrl;
          _error =
              'VPS не авторизован в Google. Откройте ссылку OAuth в браузере и войдите в Google-аккаунт.';
        });
        return;
      }

      if (!mounted) return;
      setState(() => _status = 'ИИ (${auth.model}) анализирует логи OpenWRT...');

      final plan = await AiDoctorService.diagnose(
        cfg: cfg,
        host: widget.host,
        stage: 'openwrt_recovery',
        errorMessage: widget.errorMessage,
        log: _currentLog,
        history: _history,
      );

      if (!mounted) return;
      if (plan.isSafe) {
        setState(() {
          _plan = plan;
          _status = 'Выполняю безопасное действие: ${plan.actionId}...';
        });
        await _executeSafe(plan);
      } else {
        if (plan.requiresApproval) {
          HapticFeedback.heavyImpact();
        }
        setState(() {
          _plan = plan;
          _busy = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _executeSafe(AiDoctorPlan plan) async {
    SSHClient? ssh;
    try {
      ssh = await _openSsh();
      final output = await AiDoctorService.executeSafeAction(ssh, plan);
      _history.add('safe:${plan.actionId} -> OK');
      _currentLog =
          '$_currentLog\n\n=== AI SAFE ACTION (${plan.actionId}) ===\n$output';
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Безопасное действие выполнено: ${plan.actionId}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Ошибка выполнения безопасного действия: $e';
      });
    } finally {
      ssh?.close();
    }
  }

  Future<void> _approveAndExecute(AiDoctorPlan plan) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Создаю бэкап и выполняю подтверждённую команду...';
    });
    SSHClient? ssh;
    try {
      ssh = await _openSsh();
      final output = await AiDoctorService.executeApprovedRootCommand(ssh, plan);
      _history.add('approved:${plan.command}');
      _currentLog =
          '$_currentLog\n\n=== AI APPROVED ROOT COMMAND ===\n$output';
      if (!mounted) return;
      setState(() {
        _busy = false;
        _plan = null;
        _status = 'Команда выполнена. Можно повторить анализ или установку.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Ошибка выполнения команды: $e';
      });
    } finally {
      ssh?.close();
    }
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    _secretCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return GlassAlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('ИИ-диагностика OpenWRT')),
          if (!_configuring)
            IconButton(
              tooltip: 'Настройки VPS',
              icon: const Icon(Icons.settings_outlined, size: 19),
              onPressed: _busy ? null : () => setState(() => _configuring = true),
            ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading || _busy)
                Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_status)),
                  ],
                )
              else if (_configuring) ...[
                TextField(
                  controller: _urlCtl,
                  decoration: const InputDecoration(
                    labelText: 'Адрес VPS (HTTPS)',
                    hintText: 'https://ai.example.com',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _secretCtl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'AI_DOCTOR_SECRET (опционально)',
                  ),
                ),
              ] else if (plan != null) ...[
                Text(
                  plan.diagnosis,
                  style: const TextStyle(fontSize: 13.5, height: 1.4),
                ),
                if (plan.requiresApproval) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: kAccentRed.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kAccentRed.withOpacity(0.45)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Требуется подтверждение (риск: ${plan.riskLevel.toUpperCase()})',
                          style: const TextStyle(
                            color: kAccentRed,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Команда от root:',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Colors.white.withOpacity(0.75),
                          ),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          plan.command ?? '',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Возможные последствия при неудаче: ${plan.consequences}',
                          style: const TextStyle(fontSize: 12, height: 1.35),
                        ),
                        if (plan.backupPaths.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Автобэкап перед запуском: ${plan.backupPaths.join(', ')}',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: kAccentGreen.withOpacity(0.9),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 10),
                  Text(
                    _status,
                    style: const TextStyle(color: kAccentGreen, fontSize: 12.5),
                  ),
                ],
              ] else
                Text(_status),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(color: kAccentRed, fontSize: 12.5),
                ),
              ],
              if (_oauthLoginUrl != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _oauthLoginUrl!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Ссылка Google OAuth скопирована — откройте её в браузере',
                          ),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Скопировать ссылку входа Google'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: _busy
          ? null
          : _configuring
              ? [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Отмена'),
                  ),
                  ElevatedButton(
                    onPressed: _saveConfigAndStart,
                    child: const Text('Сохранить и проверить'),
                  ),
                ]
              : (plan != null && plan.requiresApproval)
                  ? [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Отклонить'),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kAccentRed,
                        ),
                        onPressed: () => _approveAndExecute(plan),
                        child: const Text('Выполнить команду'),
                      ),
                    ]
                  : [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Закрыть'),
                      ),
                      ElevatedButton(
                        onPressed: _runDiagnose,
                        child: const Text('Повторить анализ'),
                      ),
                    ],
    );
  }
}
