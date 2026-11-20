// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Настройки. deviceId удалён — новый CSQTT его не использует.
//
// ВАЖНО (исправление):
//   - vkHashes теперь ВСЕГДА берётся из `_vkHashesCtl.text` при сохранении,
//     а не подменяется на _selectedConfig.hashes. Иначе введённые вручную
//     хеши не сохранялись при переходе на другую вкладку.
//   - При загрузке: если у выбранного конфига хеши непустые — берём их,
//     иначе берём settings.vkHashes.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_select.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/config_item.dart';
import '../models/router_info.dart';
import '../models/settings.dart';
import '../models/vk_token_state.dart';
import '../state/configs_notifier.dart';
import '../state/providers.dart';
import '../state/router_notifier.dart';
import '../state/settings_notifier.dart';
import '../state/vk_notifier.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/glass_card.dart';
import '../widgets/input_row.dart';
import '../widgets/openwrt_install_modal.dart';
import '../widgets/router_modal.dart';
import '../widgets/toast.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  Settings _s = Settings();
  ConfigItem? _selectedConfig;
  bool _loading = true;
  bool _busy = false;

  final _peerCtl = TextEditingController();
  final _vkHashesCtl = TextEditingController();
  final _externalHashesUrlCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  final _workersCtl = TextEditingController();
  final _autoApiWorkersCtl = TextEditingController();
  final _clientIdsCtl = TextEditingController();
  final _deviceIdCtl = TextEditingController();

  // ToTS
  final _totsWorkersCtl = TextEditingController();
  final _totsMtuCtl = TextEditingController();
  final _totsVkPercentCtl = TextEditingController();
  final _totsJazzPercentCtl = TextEditingController();
  final _totsYaDocsPercentCtl = TextEditingController();
  final _totsMailDocsPercentCtl = TextEditingController();
  final _totsCupsPercentCtl = TextEditingController();
  final _totsVkLinksCtl = TextEditingController();
  final _totsJazzRoomCtl = TextEditingController();
  final _totsJazzDataCtl = TextEditingController();
  final _totsYaDocsDataCtl = TextEditingController();
  final _totsMailDocsDataCtl = TextEditingController();
  final _totsCupsDataCtl = TextEditingController();

  final _ipRoutingIpsCtl = TextEditingController();
  String _ipRoutingMode = 'blacklist';
  String _androidAppRoutingMode = 'blacklist';
  Set<String> _androidVpnApps = <String>{};
  List<Map<String, dynamic>> _installedApps = [];
  bool _loadingApps = false;
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  String _authMode = 'manual';
  bool _enableSmartTunnel = false;
  bool _showCoreLogs = false;
  bool _shareVpn = false;
  bool _desktopSocks5Mode = false;

  bool get _isTots => _selectedConfig?.isTots == true;
  bool get _isCsqtt219 => _selectedConfig?.isCsqtt219 == true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _peerCtl.dispose();
    _vkHashesCtl.dispose();
    _externalHashesUrlCtl.dispose();
    _passwordCtl.dispose();
    _workersCtl.dispose();
    _autoApiWorkersCtl.dispose();
    _clientIdsCtl.dispose();
    _deviceIdCtl.dispose();
    _totsWorkersCtl.dispose();
    _totsMtuCtl.dispose();
    _totsVkPercentCtl.dispose();
    _totsJazzPercentCtl.dispose();
    _totsYaDocsPercentCtl.dispose();
    _totsMailDocsPercentCtl.dispose();
    _totsCupsPercentCtl.dispose();
    _totsVkLinksCtl.dispose();
    _totsJazzRoomCtl.dispose();
    _totsJazzDataCtl.dispose();
    _totsYaDocsDataCtl.dispose();
    _totsMailDocsDataCtl.dispose();
    _totsCupsDataCtl.dispose();
    _ipRoutingIpsCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await Future.wait([
      ref.read(settingsProvider.notifier).reload(),
      ref.read(configsProvider.notifier).reload(),
    ]);
    if (!mounted) return;

    final s = ref.read(settingsProvider).data;
    final cfg = ref.read(configsProvider).selected;

    _s = s;
    _selectedConfig = cfg;

    if (cfg != null) {
      _peerCtl.text = cfg.peer;
      _passwordCtl.text = cfg.password;
      // Хеши в настройках — самостоятельное значение. Не перезаписываем
      // сохранённый пользовательский ввод хешами выбранного конфига.
      _vkHashesCtl.text = s.vkHashes.isNotEmpty ? s.vkHashes : cfg.hashes;
    } else {
      _peerCtl.text = s.peer;
      _passwordCtl.text = s.password;
      _vkHashesCtl.text = s.vkHashes;
    }

    _workersCtl.text = s.workers.toString();
    _autoApiWorkersCtl.text = s.autoApiWorkers.toString();
    _clientIdsCtl.text = s.clientIds;
    _deviceIdCtl.text = s.deviceId;
    _authMode = s.authMode.isEmpty ? 'manual' : s.authMode;
    _externalHashesUrlCtl.text = s.externalHashesUrl;
    _enableSmartTunnel = s.enableSmartTunnel;
    _showCoreLogs = s.showCoreLogs;
    _shareVpn = s.shareVpn;
    _desktopSocks5Mode = s.desktopSocks5Mode;
    _ipRoutingMode = _isDesktop ? 'blacklist' : s.ipRoutingMode;
    _ipRoutingIpsCtl.text = s.ipRoutingIps;
    _androidAppRoutingMode = s.androidAppRoutingMode;
    _androidVpnApps = s.androidVpnApps.toSet();

    _totsWorkersCtl.text = s.totsWorkers.toString();
    _totsMtuCtl.text = s.totsMtu.toString();
    _totsVkPercentCtl.text = s.totsVkPercent.toString();
    _totsJazzPercentCtl.text = s.totsJazzPercent.toString();
    _totsYaDocsPercentCtl.text = s.totsYaDocsPercent.toString();
    _totsMailDocsPercentCtl.text = s.totsMailDocsPercent.toString();
    _totsCupsPercentCtl.text = s.totsCupsPercent.toString();
    _totsVkLinksCtl.text = s.totsVkCallLinks;
    _totsJazzRoomCtl.text = s.totsJazzRoomName;
    _totsJazzDataCtl.text = s.totsJazzData;
    _totsYaDocsDataCtl.text = s.totsYaDocsData;
    _totsMailDocsDataCtl.text = s.totsMailDocsData;
    _totsCupsDataCtl.text = s.totsCupsData;
    if (_isTots) {
      // A provider cannot be visually enabled when there is no data to put into
      // ToTS provider_data. This also makes the switch state match launch behavior.
      _s = _s.copyWith(
        totsVkEnabled: s.totsVkEnabled && _totsHasData('vk'),
        totsJazzEnabled: s.totsJazzEnabled && _totsHasData('jazz'),
        totsYaDocsEnabled: s.totsYaDocsEnabled && _totsHasData('ya-docs'),
        totsMailDocsEnabled: s.totsMailDocsEnabled && _totsHasData('mail-docs'),
        totsCupsEnabled: s.totsCupsEnabled && _totsHasData('cups'),
      );
    }


    setState(() => _loading = false);
  }

  void _markDirty() {
    if (!mounted) return;
    Toast.show(context, 'Сохраните настройки!',
        isError: true, duration: const Duration(seconds: 2));
  }

  Future<void> _save() async {
    if (_busy) return;

    // Commit the active IME edit before normalizing controllers or building
    // the payload. On Android the keyboard can keep a composing value alive
    // while the user scrolls to this button without pressing its checkmark.
    FocusManager.instance.primaryFocus?.unfocus();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final workersText = _workersCtl.text.trim();
    final autoApiWorkersText = _autoApiWorkersCtl.text.trim();

    var w = int.tryParse(workersText) ?? kDefaultWorkers;
    if (w < kMinWorkers) w = kMinWorkers;
    if (w > kMaxWorkers) w = kMaxWorkers;

    var aw = int.tryParse(autoApiWorkersText) ?? kDefaultAutoApiWorkers;
    if (aw < kMinAutoApiWorkers) aw = kMinAutoApiWorkers;
    if (aw > kMaxAutoApiWorkers) aw = kMaxAutoApiWorkers;

    if (_workersCtl.text != w.toString()) _workersCtl.text = w.toString();
    if (_autoApiWorkersCtl.text != aw.toString()) {
      _autoApiWorkersCtl.text = aw.toString();
    }

    // ВАЖНО: vkHashes всегда из контроллера — не подменяем на конфиг.
    // Это позволяет пользователю ввести хеши вручную и сохранить их
    // в settings.vkHashes. Backend fallback'ом возьмёт их, если у конфига
    // hashes пустые.
    final s = _s.copyWith(
      peer: _peerCtl.text.trim(),
      vkHashes: _vkHashesCtl.text.trim(),
      password: _passwordCtl.text,
      workers: w,
      autoApiWorkers: aw,
      clientIds: _clientIdsCtl.text.trim(),
      deviceId: _deviceIdCtl.text.trim(),
      authMode: _authMode,
      externalHashesUrl: _externalHashesUrlCtl.text.trim(),
      enableSmartTunnel: _enableSmartTunnel,
      showCoreLogs: _showCoreLogs,
      shareVpn: _shareVpn,
      desktopSocks5Mode: _desktopSocks5Mode,
      ipRoutingMode: _ipRoutingMode,
      ipRoutingIps: _ipRoutingIpsCtl.text.trim(),
      androidAppRoutingMode: _androidAppRoutingMode,
      androidVpnApps: _androidVpnApps.toList()..sort(),
      totsWorkers: (int.tryParse(_totsWorkersCtl.text.trim()) ?? 1).clamp(1, 256).toInt(),
      totsMtu: (int.tryParse(_totsMtuCtl.text.trim()) ?? 1200).clamp(576, 1400).toInt(),
      totsVkCallLinks: _totsVkLinksCtl.text.trim(),
      totsJazzRoomName: _totsJazzRoomCtl.text.trim(),
      totsJazzData: _totsJazzDataCtl.text.trim(),
      totsYaDocsData: _totsYaDocsDataCtl.text.trim(),
      totsMailDocsData: _totsMailDocsDataCtl.text.trim(),
      totsCupsData: _totsCupsDataCtl.text.trim(),
    );

    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await ref.read(settingsProvider.notifier).save(s);
    } catch (_) {
      // Keep the button usable even if a provider or transport throws.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _s = s;
    });
    final saveError = ref.read(settingsProvider).error;
    Toast.show(
      context,
      ok
          ? 'Настройки сохранены'
          : (saveError == null || saveError.trim().isEmpty
              ? 'Ошибка сохранения настроек'
              : 'Ошибка сохранения: $saveError'),
      isError: !ok,
      duration: ok ? const Duration(seconds: 3) : const Duration(seconds: 7),
    );
  }

  void _setAuthMode(String mode, VkTokenState vk) {
    if (mode == 'autoApi' || mode == 'autoVk') {
      if (!vk.hasToken) {
        Toast.show(context, 'Требуется авторизация ВК', isError: true);
        return;
      }
    }
    setState(() => _authMode = mode);
    _markDirty();
  }

  Future<void> _onLoginTap() async {
    final vk = ref.read(vkProvider);
    if (vk.hasToken) {
      Toast.show(context, 'Токен ВК уже активен');
      return;
    }
    Toast.show(context, 'Открываю авторизацию ВК...');
    await ref.read(vkProvider.notifier).login();
  }

  Future<void> _onOpenWrtTap() async {
    final action = await showOpenWrtActionDialog(context);
    if (action == null || !mounted) return;
    if (action == 'install') {
      await showOpenWrtInstallFlow(context);
      return;
    }
    if (action == 'connect') {
      await _onConnectRouter();
    }
  }

  Future<void> _onConnectRouter() async {
    final chosen = await showRouterModal(context);
    if (chosen == null || !mounted) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Установить соединение?',
      message:
          'Все API-запросы будут переключены на ${chosen.displayName} '
          '(${chosen.ip}:1062).',
      confirmLabel: 'Подключить',
    );
    if (ok != true || !mounted) return;
    final success = await ref.read(routerProvider.notifier).connect(chosen);
    if (!mounted) return;
    if (success) {
      Toast.show(context, 'Подключено к роутеру ${chosen.displayName}');
    } else {
      final err = ref.read(routerProvider).error ?? 'Ошибка подключения';
      Toast.show(context, err, isError: true);
    }
  }

  Future<void> _onDisconnectRouter() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Отключиться от роутера?',
      message: 'API вернётся на 127.0.0.1.',
      confirmLabel: 'Отключить',
    );
    if (ok != true || !mounted) return;
    await ref.read(routerProvider.notifier).disconnect();
  }

  Future<void> _onRemoveRouter(RouterInfo r) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить роутер?',
      message: '${r.displayName} (${r.ip}) будет удалён.',
      confirmLabel: 'Удалить',
    );
    if (ok != true || !mounted) return;
    await ref.read(routerProvider.notifier).removeRouter(r.ip);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final vk = ref.watch(vkProvider);
    final routerState = ref.watch(routerProvider);

    final items = <WidgetBuilder>[
      (_) => _sectionTitle('Основные настройки'),
      (_) => GlassCard(child: _buildMainBlock()),
      (_) => const SizedBox(height: 18),
      if (!_isTots) ...[
        (_) => _sectionTitle('Авторизация'),
        (_) => _buildAuthBlock(vk),
        (_) => const SizedBox(height: 18),
      ],
      (_) => _sectionTitle('Маршрутизация VPN'),
      (_) => GlassCard(child: _buildRoutingBlock()),
      (_) => const SizedBox(height: 18),
      (_) => _sectionTitle(_isTots ? 'Настройки ToTS' : 'Продвинутые настройки'),
      (_) => _isTots
          ? GlassCard(child: _buildTotsBlock(vk))
          : GlassCard(child: _buildCsqttAdvancedBlock()),
      (_) => const SizedBox(height: 18),
      (_) => _sectionTitle('Экспериментальное'),
      (_) => GlassCard(child: _buildExperimentalBlock(routerState: routerState)),
      (_) => const SizedBox(height: 22),
      (_) => ElevatedButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Сохранение...' : 'Сохранить настройки')),
    ];

    // The settings cards do not overlap, so Flutter can reuse the same
    // backdrop blur without changing the glass effect on individual cards.
    return BackdropGroup(
      child: ListView.builder(
        key: const PageStorageKey('settings-page'),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        itemCount: items.length,
        itemBuilder: (context, index) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SizedBox(
              width: double.infinity,
              child: items[index](context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMainBlock() {
    final cfg = _selectedConfig;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cfg != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                const Icon(Icons.link, size: 14, color: Color(0xFF7CFF9A)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Конфиг: ${cfg.displayName} · ${cfg.protocol}',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withOpacity(0.75)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Конфиг не выбран. Выберите во вкладке «Подключение».',
              style:
                  TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.55)),
            ),
          ),

        if (!_isTots) ...[
          InputRow(label: 'Peer', controller: _peerCtl, readOnly: true),
          InputRow(
            label: 'Password',
            controller: _passwordCtl,
            readOnly: true,
            obscureText: true,
          ),
        ],

        if (!_isTots) Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              SizedBox(
                width: 130,
                child: Text('Workers',
                    style:
                        TextStyle(color: Colors.white.withOpacity(0.7))),
              ),
              Expanded(
                child: Builder(builder: (context) {
                  final value = int.tryParse(_workersCtl.text.trim());
                  return TextField(
                    controller: _workersCtl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: '$kDefaultWorkers',
                      helperText: 'Рекомендуется $kDefaultWorkers · допустимо от '
                          '$kMinWorkers до $kMaxWorkers. После сохранения '
                          'переподключитесь; фактическое число согласуется с сервером.',
                      helperMaxLines: 3,
                      helperStyle: const TextStyle(fontSize: 10.5),
                      suffixIcon: value == kDefaultWorkers
                          ? null
                          : IconButton(
                              tooltip: 'Сбросить на $kDefaultWorkers',
                              icon: const Icon(Icons.restart_alt, size: 18),
                              onPressed: () {
                                setState(() => _workersCtl.text =
                                    '$kDefaultWorkers');
                                _markDirty();
                              },
                            ),
                    ),
                    onChanged: (_) {
                      setState(() {});
                      _markDirty();
                    },
                  );
                }),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _loadInstalledApps() async {
    if (!_isAndroid || _loadingApps) return;
    setState(() => _loadingApps = true);
    try {
      final result = await ref.read(apiClientProvider).getJsonList('/apps/installed');
      if (!mounted) return;
      setState(() {
        _installedApps = result
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .where((item) => (item['packageName'] ?? '').toString().isNotEmpty)
            .toList()
          ..sort((a, b) => (a['label'] ?? a['packageName']).toString()
              .toLowerCase().compareTo((b['label'] ?? b['packageName']).toString().toLowerCase()));
      });
    } catch (_) {
      if (mounted) Toast.show(context, 'Не удалось получить список приложений Android', isError: true);
    } finally {
      if (mounted) setState(() => _loadingApps = false);
    }
  }

  Future<void> _chooseAndroidApps() async {
    if (_installedApps.isEmpty) {
      await _loadInstalledApps();
      if (_installedApps.isEmpty || !mounted) return;
    }
    final selected = Set<String>.from(_androidVpnApps);
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => GlassAlertDialog(
          title: const Text('Приложения для маршрутизации'),
          content: SizedBox(
            width: 460,
            height: 480,
            child: ListView.builder(
              itemCount: _installedApps.length,
              itemBuilder: (context, index) {
                final app = _installedApps[index];
                final packageName = app['packageName'].toString();
                final label = (app['label'] ?? packageName).toString();
                return CheckboxListTile(
                  value: selected.contains(packageName),
                  title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(packageName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  dense: true,
                  onChanged: (checked) => setDialogState(() {
                    if (checked == true) {
                      selected.add(packageName);
                    } else {
                      selected.remove(packageName);
                    }
                  }),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Отмена')),
            ElevatedButton(onPressed: () => Navigator.pop(dialogContext, selected), child: const Text('Применить')),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() => _androidVpnApps = result);
      _markDirty();
    }
  }

  Widget _buildRoutingBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('IP-адреса', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
            color: Colors.white.withOpacity(0.9))),
        const SizedBox(height: 5),
        Text('Настройка общая для поддерживаемых протоколов. Можно указывать IPv4, IPv6 и CIDR — по одному на строку.',
            style: TextStyle(fontSize: 11.5, height: 1.45, color: Colors.white.withOpacity(0.55))),
        const SizedBox(height: 10),
        _rowDropdown(
          'Режим IP',
          _ipRoutingMode == 'whitelist' ? 'Белый список' : 'Чёрный список',
          _isDesktop ? const ['Чёрный список'] : const ['Чёрный список', 'Белый список'],
          (v) {
            setState(() => _ipRoutingMode = v == 'Белый список' ? 'whitelist' : 'blacklist');
            _markDirty();
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: _ipRoutingIpsCtl,
            minLines: 3,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'IP / CIDR',
              hintText: '192.168.1.10\n10.0.0.0/8\n2001:db8::/32',
              helperText: _ipRoutingMode == 'whitelist'
                  ? 'Белый список: только эти IP идут через VPN.'
                  : (_isDesktop
                      ? 'Чёрный список: эти IP идут напрямую, остальные — через VPN. На Windows/Linux применяются IPv4 и IPv4/CIDR; IPv6 у текущего desktop TUN и так не перехватывается.'
                      : 'Чёрный список: эти IP должны идти напрямую, остальные — через VPN. Исключение IP поддерживается на Android 13+.'),
              helperMaxLines: 3,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onChanged: (_) => _markDirty(),
          ),
        ),
        if (_isAndroid) ...[
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Text('Приложения Android', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
              color: Colors.white.withOpacity(0.9))),
          const SizedBox(height: 5),
          Text('Выберите приложения по установленному пакету. Изменения применятся при следующем подключении VPN.',
              style: TextStyle(fontSize: 11.5, height: 1.45, color: Colors.white.withOpacity(0.55))),
          const SizedBox(height: 8),
          _rowDropdown('Режим приложений', _androidAppRoutingMode == 'whitelist' ? 'Белый список' : 'Чёрный список', const ['Чёрный список', 'Белый список'], (v) {
            setState(() => _androidAppRoutingMode = v == 'Белый список' ? 'whitelist' : 'blacklist');
            _markDirty();
          }),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _loadingApps ? null : _chooseAndroidApps,
              icon: _loadingApps
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.apps, size: 17),
              label: Text(_loadingApps ? 'Загрузка приложений...' : 'Выбрать приложения (' + _androidVpnApps.length.toString() + ')'),
            ),
          ),
          Text(_androidAppRoutingMode == 'whitelist'
              ? 'Белый список: через VPN идут только выбранные приложения.'
              : 'Чёрный список: выбранные приложения идут напрямую, остальные — через VPN.',
              style: TextStyle(fontSize: 11.5, height: 1.45, color: Colors.white.withOpacity(0.55))),
        ],
      ],
    );
  }


  Map<String, dynamic> _decodedTotsProviderData() {
    final raw = _selectedConfig?.rawLink.trim() ?? '';
    if (!raw.toLowerCase().startsWith('tots://')) return const {};
    try {
      var payload = raw.substring(raw.indexOf('://') + 3).trim();
      payload = payload.replaceAll('-', '+').replaceAll('_', '/');
      while (payload.length % 4 != 0) { payload += '='; }
      final decoded = jsonDecode(utf8.decode(base64Decode(payload)));
      if (decoded is Map && decoded['provider_data'] is Map) {
        final data = Map<String, dynamic>.from(decoded['provider_data'] as Map);
        const providerKeys = {'vk', 'jazz', 'ya-docs', 'mail-docs', 'cups'};
        if (data.keys.any(providerKeys.contains)) return data;
        final primary = (decoded['provider'] ?? 'vk').toString();
        return <String, dynamic>{primary: data};
      }
    } catch (_) {}
    return const {};
  }

  bool _totsHasData(String provider) {
    if (_decodedTotsProviderData().containsKey(provider)) return true;
    switch (provider) {
      case 'vk': return _s.totsVkAuthMode == 'autoApi' || _totsVkLinksCtl.text.trim().isNotEmpty;
      case 'jazz': return _totsJazzDataCtl.text.trim().isNotEmpty;
      case 'ya-docs': return _totsYaDocsDataCtl.text.trim().isNotEmpty;
      case 'mail-docs': return _totsMailDocsDataCtl.text.trim().isNotEmpty;
      case 'cups': return _totsCupsDataCtl.text.trim().isNotEmpty;
    }
    return false;
  }

  void _missingTotsProviderData(String provider) {
    Toast.show(context, 'Для $provider не указаны provider data', isError: true);
  }

  void _setTotsProviderEnabled(String provider, bool value) {
    if (value && !_totsHasData(provider)) {
      _missingTotsProviderData(provider);
      return;
    }
    setState(() {
      switch (provider) {
        case 'vk': _s = _s.copyWith(totsVkEnabled: value); break;
        case 'jazz': _s = _s.copyWith(totsJazzEnabled: value); break;
        case 'ya-docs': _s = _s.copyWith(totsYaDocsEnabled: value); break;
        case 'mail-docs': _s = _s.copyWith(totsMailDocsEnabled: value); break;
        case 'cups': _s = _s.copyWith(totsCupsEnabled: value); break;
      }
    });
    _markDirty();
  }

  Widget _totsPercentRow(
    String provider,
    int value,
    bool enabled,
    TextEditingController controller,
    ValueChanged<int> onChanged,
  ) {
    final available = _totsHasData(provider);
    final active = available && enabled;
    void apply(int next) {
      final v = next.clamp(0, 100).toInt();
      controller.text = v.toString();
      onChanged(v);
      _markDirty();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: active ? null : () => _missingTotsProviderData(provider),
              child: AbsorbPointer(
                absorbing: !active,
                child: Slider(
                  min: 0,
                  max: 100,
                  divisions: 100,
                  value: value.clamp(0, 100).toDouble(),
                  onChanged: (v) => apply(v.round()),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: TextField(
              controller: controller,
              readOnly: !active,
              onTap: active ? null : () => _missingTotsProviderData(provider),
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(isDense: true, suffixText: '%'),
              onChanged: (raw) {
                final parsed = int.tryParse(raw);
                if (parsed != null) onChanged(parsed.clamp(0, 100).toInt());
                _markDirty();
              },
              onEditingComplete: () {
                apply((int.tryParse(controller.text) ?? value).clamp(0, 100).toInt());
                FocusScope.of(context).unfocus();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _totsProviderFrame({
    required String provider,
    required String title,
    required bool enabled,
    required int percent,
    required TextEditingController percentController,
    required ValueChanged<int> onPercent,
    Widget? info,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (info != null) ...[const SizedBox(width: 5), info],
              const Spacer(),
              Switch(
                value: enabled,
                onChanged: (v) => _setTotsProviderEnabled(provider, v),
                activeColor: const Color(0xFFE5484D),
              ),
            ],
          ),
          _totsPercentRow(provider, percent, enabled, percentController, onPercent),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }

  Widget _totsJsonField(String label, TextEditingController controller, String hint) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: controller,
        minLines: 2,
        maxLines: 5,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
        onChanged: (_) { setState(() {}); _markDirty(); },
      ),
    );
  }

  Widget _buildTotsBlock(VkTokenState vk) {
    final jazzInfo = IconButton(
      tooltip: 'Jazz',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      onPressed: () => Toast.show(
        context,
        'Jazz не требует VK-хешей: для комнаты используется её название, а transport data берутся из provider data.',
        duration: const Duration(seconds: 5),
      ),
      icon: const Icon(Icons.error_outline, size: 19, color: Color(0xFF63E68B)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputRow(label: 'Workers', controller: _totsWorkersCtl, onChanged: (_) => _markDirty()),
        InputRow(label: 'MTU', controller: _totsMtuCtl, onChanged: (_) => _markDirty()),
        _toggleRow('Relay only', _s.totsRelayOnly, (v) {
          setState(() => _s = _s.copyWith(totsRelayOnly: v)); _markDirty();
        }),
        const SizedBox(height: 10),
        Text('Проценты автоматически нормализуются до 100 при запуске. Провайдер без provider data нельзя включить или изменить.',
            style: TextStyle(fontSize: 11.5, height: 1.4, color: Colors.white.withOpacity(0.55))),
        const SizedBox(height: 10),
        _totsProviderFrame(
          provider: 'vk', title: 'VK', enabled: _s.totsVkEnabled,
          percent: _s.totsVkPercent, percentController: _totsVkPercentCtl,
          onPercent: (v) => setState(() => _s = _s.copyWith(totsVkPercent: v)),
          children: [
            _rowDropdown('VK режим', _s.totsVkAuthMode == 'autoApi' ? 'АвтоAPI' : 'Ручные', const ['Ручные', 'АвтоAPI'], (v) {
              if (v == 'АвтоAPI' && !vk.hasToken) {
                Toast.show(context, 'Для АвтоAPI требуется авторизация ВК', isError: true);
                return;
              }
              setState(() => _s = _s.copyWith(totsVkAuthMode: v == 'АвтоAPI' ? 'autoApi' : 'manual'));
              _markDirty();
            }),
            if (_s.totsVkAuthMode != 'autoApi') ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('Хеши (через запятую или +)',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.65))),
              ),
              TextField(
                controller: _totsVkLinksCtl,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(hintText: 'hash1,hash2,hash3'),
                onChanged: (_) { setState(() {}); _markDirty(); },
              ),
            ],
            const SizedBox(height: 8),
            if (!vk.hasToken)
              _buildLoginButton(vk)
            else
              _buildTokenActiveBadge(),
            if (_s.totsVkAuthMode == 'autoApi') ...[
              const SizedBox(height: 8),
              InputRow(
                label: 'Воркеров на хеш',
                controller: _autoApiWorkersCtl,
                onChanged: (_) => _markDirty(),
              ),
            ],
          ],
        ),
        _totsProviderFrame(
          provider: 'jazz', title: 'Jazz', info: jazzInfo, enabled: _s.totsJazzEnabled,
          percent: _s.totsJazzPercent, percentController: _totsJazzPercentCtl,
          onPercent: (v) => setState(() => _s = _s.copyWith(totsJazzPercent: v)),
          children: [
            _toggleRow('Random name', _s.totsJazzRandomName, (v) {
              setState(() => _s = _s.copyWith(totsJazzRandomName: v)); _markDirty();
            }),
            InputRow(label: 'Название комнаты', controller: _totsJazzRoomCtl,
              readOnly: _s.totsJazzRandomName, onChanged: (_) => _markDirty()),
            _totsJsonField('Jazz provider data', _totsJazzDataCtl,
                '{"join_link":"https://salutejazz.ru/...","connector_url":"wss://..."}'),
          ],
        ),
        _totsProviderFrame(
          provider: 'ya-docs', title: 'Ya Docs', enabled: _s.totsYaDocsEnabled,
          percent: _s.totsYaDocsPercent, percentController: _totsYaDocsPercentCtl,
          onPercent: (v) => setState(() => _s = _s.copyWith(totsYaDocsPercent: v)),
          children: [_totsJsonField('Ya Docs provider data', _totsYaDocsDataCtl,
              '{"url":"https://...","cookies":{"name":"value"}}')],
        ),
        _totsProviderFrame(
          provider: 'mail-docs', title: 'Mail Docs', enabled: _s.totsMailDocsEnabled,
          percent: _s.totsMailDocsPercent, percentController: _totsMailDocsPercentCtl,
          onPercent: (v) => setState(() => _s = _s.copyWith(totsMailDocsPercent: v)),
          children: [_totsJsonField('Mail Docs provider data', _totsMailDocsDataCtl,
              '{"url":"https://...","cookies":{"name":"value"}}')],
        ),
        _totsProviderFrame(
          provider: 'cups', title: 'Cups', enabled: _s.totsCupsEnabled,
          percent: _s.totsCupsPercent, percentController: _totsCupsPercentCtl,
          onPercent: (v) => setState(() => _s = _s.copyWith(totsCupsPercent: v)),
          children: [_totsJsonField('Cups provider data', _totsCupsDataCtl,
              '{"room_id":"..."}')],
        ),
      ],
    );
  }

  Widget _buildCsqttAdvancedBlock() {
    return Column(
      children: [
        _rowDropdown('Obfs', _s.obfs, const ['video', 'audio'], (v) {
          setState(() => _s = _s.copyWith(obfs: v));
          _markDirty();
        }),
        _rowDropdown('Fingerprint', _s.fingerprint,
            const ['firefox', 'chrome', 'edge'], (v) {
          setState(() => _s = _s.copyWith(fingerprint: v));
          _markDirty();
        }),
        _rowDropdown('Captcha Mode', _s.captchaMode,
            const ['auto', 'wv', 'rjs'], (v) {
          setState(() => _s = _s.copyWith(captchaMode: v));
          _markDirty();
        }),
        _rowDropdown('Turn Transport', _s.turnTransport,
            const ['udp', 'tcp'], (v) {
          setState(() => _s = _s.copyWith(turnTransport: v));
          _markDirty();
        }),
        InputRow(
            label: 'Client IDs',
            controller: _clientIdsCtl,
            onChanged: (_) => _markDirty()),
        _toggleRow('Allow hash redistribution', _s.allowHashRedistribution,
            (v) {
          setState(() => _s = _s.copyWith(allowHashRedistribution: v));
          _markDirty();
        }),
        _toggleRow('Validate VK hashes', _s.validateVkHashes, (v) {
          setState(() => _s = _s.copyWith(validateVkHashes: v));
          _markDirty();
        }),
        if (_isCsqtt219) ...[
          const SizedBox(height: 10),
          const _SubHeader('CSQTT 2.1.9'),
          InputRow(
            label: 'Device ID',
            controller: _deviceIdCtl,
            onChanged: (_) => _markDirty(),
          ),
        ],
      ],
    );
  }

  Widget _buildAuthBlock(VkTokenState vk) {
    final hasToken = vk.hasToken;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('РЕЖИМ АВТОРИЗАЦИИ',
                  style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 0.7,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withOpacity(0.4))),
              const SizedBox(height: 10),
              _authOption('manual', 'Ручной', 'Ввести хеши вручную',
                  enabled: true, vk: vk),
              _authOption('autoApi', 'Авто API',
                  'Создавать звонки через VK API',
                  enabled: hasToken, vk: vk, stableHint: true),
              _authOption('autoVk', 'Авто ВК',
                  'Ядро само авторизуется через VK',
                  enabled: hasToken, vk: vk),
              _authOption('externalHashes', 'Внешние хеши',
                  'Скачивать hashes.txt из публичного ZIP на Яндекс Диске при каждом запуске VPN',
                  enabled: true, vk: vk),
              if (_authMode == 'autoApi' || _authMode == 'autoVk') ...[
                const SizedBox(height: 12),
                if (!hasToken)
                  _buildLoginButton(vk)
                else
                  _buildTokenActiveBadge(),
              ],
              if (vk.fetching && (_authMode == 'autoApi' || _authMode == 'autoVk')) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: vk.progress / 100.0,
                  backgroundColor: Colors.white.withOpacity(0.1),
                  valueColor:
                      const AlwaysStoppedAnimation(Color(0xFFE5484D)),
                  minHeight: 4,
                ),
                const SizedBox(height: 6),
                Text(vk.message,
                    style: TextStyle(
                        fontSize: 11, color: Colors.white.withOpacity(0.6))),
              ],
              if (_authMode == 'manual') ...[
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('Хеши (через запятую или +)',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.65))),
                ),
                TextField(
                  controller: _vkHashesCtl,
                  minLines: 2,
                  maxLines: 4,
                  style: const TextStyle(fontSize: 13),
                  decoration:
                      const InputDecoration(hintText: 'hash1,hash2,hash3'),
                  onChanged: (_) => _markDirty(),
                ),
              ],
              if (_authMode == 'externalHashes') ...[
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('Публичный ZIP на Яндекс Диске',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.65))),
                ),
                TextField(
                  controller: _externalHashesUrlCtl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'https://disk.yandex.ru/d/AbCdEf123456',
                    helperText: 'В ZIP должен находиться hashes.txt. Архив скачивается заново перед каждым подключением.',
                    helperMaxLines: 3,
                    helperStyle: TextStyle(fontSize: 10.5),
                  ),
                  onChanged: (_) => _markDirty(),
                ),
              ],
            ],
          ),
        ),
        if (_authMode == 'autoApi') ...[
          const SizedBox(height: 14),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('АВТО API',
                    style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.7,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withOpacity(0.4))),
                const SizedBox(height: 10),
                Row(
                  children: [
                    SizedBox(
                      width: 170,
                      child: Text('Воркеров на хеш',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.7))),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _autoApiWorkersCtl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 13.5),
                        decoration: const InputDecoration(
                          hintText: '9',
                          helperText: 'От 9 до 27',
                          helperStyle: TextStyle(fontSize: 10.5),
                        ),
                        onChanged: (_) => _markDirty(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildExperimentalBlock({required RouterState routerState}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isDesktop) ...[
          _toggleRow('Режим SOCKS5 вместо TUN', _desktopSocks5Mode, (v) {
            setState(() => _desktopSocks5Mode = v);
            _markDirty();
          }),
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 6),
            child: Text(
              'Только Windows/Linux, для CSQTT/CSQTTR. Ядро по-прежнему отдаёт raw IP через локальный UDP, '
              'но системный default route не меняется: трафик SOCKS5 направляется в этот UDP-туннель через служебный TUN.',
              style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: Colors.white.withOpacity(0.55)),
            ),
          ),
        ],
        _toggleRow('Раздавать VPN', _shareVpn, (v) {
          setState(() => _shareVpn = v);
          _markDirty();
        }),
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 6),
          child: Text(
            _isDesktop
                ? (_desktopSocks5Mode
                    ? 'В режиме SOCKS5: выключено — слушает только 127.0.0.1; включено — 0.0.0.0 для устройств в LAN. Порт виден в /vpn/status как socks5Port.'
                    : 'На ПК «Раздавать VPN» используется вместе с режимом SOCKS5 для CSQTT/CSQTTR.')
                : 'Открывает SOCKS5-прокси на случайном свободном порту (не 1080). Порт виден в /vpn/status как socks5Port.',
            style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: Colors.white.withOpacity(0.55)),
          ),
        ),
        _toggleRow('Показывать логи ядра', _showCoreLogs, (v) {
          setState(() => _showCoreLogs = v);
          _markDirty();
        }),
        _toggleRow('Enable SmartTunnel', _enableSmartTunnel, (v) {
          setState(() => _enableSmartTunnel = v);
          _markDirty();
        }),
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 14),
        Text('РОУТЕРЫ',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.7,
              fontWeight: FontWeight.w700,
              color: Colors.white.withOpacity(0.4),
            )),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _onOpenWrtTap,
            icon: const Icon(Icons.router, size: 16),
            label: const Text('Подключить OpenWRT'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2FBF71),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        if (routerState.activeRouter != null) ...[
          const SizedBox(height: 10),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF2E7D32).withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: const Color(0xFF2E7D32).withOpacity(0.55)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle,
                    size: 16, color: Color(0xFF7CFF9A)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Подключено к '
                    '${routerState.activeRouter!.displayName}',
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: _onDisconnectRouter,
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent),
                  child: const Text('Отключить'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (routerState.savedRouters.isEmpty)
          Text(
            'Сохранённых роутеров нет',
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.white.withOpacity(0.45),
            ),
          )
        else
          ...routerState.savedRouters.map((r) {
            final active = routerState.activeRouter?.ip == r.ip;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: active
                      ? const Color(0xFF2FBF71).withOpacity(0.14)
                      : Colors.white.withOpacity(0.03),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: active
                        ? const Color(0xFF2FBF71).withOpacity(0.5)
                        : Colors.white.withOpacity(0.08),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.router,
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.displayName,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          Text('${r.ip}:1062',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withOpacity(0.55),
                              )),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Удалить',
                      onPressed: () => _onRemoveRouter(r),
                      iconSize: 16,
                      icon: Icon(Icons.delete_outline,
                          color: Colors.white.withOpacity(0.5)),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _authOption(String value, String title, String subtitle,
      {required bool enabled,
      required VkTokenState vk,
      bool stableHint = false}) {
    final selected = _authMode == value;
    final opacity = enabled ? 1.0 : 0.4;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Opacity(
        opacity: opacity,
        child: InkWell(
          onTap: enabled ? () => _setAuthMode(value, vk) : null,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF2FBF71).withOpacity(0.18)
                  : Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? const Color(0xFF2FBF71).withOpacity(0.55)
                    : Colors.white.withOpacity(0.08),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                  color: selected
                      ? const Color(0xFF2FBF71)
                      : Colors.white.withOpacity(0.4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title,
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600)),
                          if (stableHint) ...[
                            const SizedBox(width: 4),
                            Tooltip(
                              message: 'Самый стабильный режим',
                              child: InkResponse(
                                radius: 16,
                                onTap: () => Toast.show(
                                  context,
                                  'Это самый стабильный режим авторизации. Авто ВК может работать нестабильно.',
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.all(3),
                                  child: Icon(
                                    Icons.error_outline,
                                    size: 17,
                                    color: Color(0xFF55D187),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(subtitle,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: Colors.white.withOpacity(0.55))),
                    ],
                  ),
                ),
                if (!enabled)
                  Icon(Icons.lock_outline,
                      size: 14, color: Colors.white.withOpacity(0.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginButton(VkTokenState vk) {
    if (vk.fetching) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: null,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Ожидание... ${vk.progress}%'),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _onLoginTap,
        icon: const Icon(Icons.login, size: 16),
        label: const Text('Войти'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withOpacity(0.2)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _buildTokenActiveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF7CFF9A).withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF7CFF9A).withOpacity(0.45)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text('Активно',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Сбросить токен',
            onPressed: () async {
              await ref.read(vkProvider.notifier).deleteToken();
              if (!mounted) return;
              setState(() => _authMode = 'manual');
              Toast.show(context, 'Токен ВК удалён');
            },
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Colors.white.withOpacity(0.55))),
    );
  }

  Widget _rowDropdown(String label, String value, List<String> items,
      ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Flexible(
            flex: 2,
            child: Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: GlassSelectField(
              value: items.contains(value) ? value : items.first,
              items: items,
              title: label,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFFE5484D),
          ),
        ],
      ),
    );
  }
}

class _SubHeader extends StatelessWidget {
  final String text;
  const _SubHeader(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4, left: 2),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.7,
              fontWeight: FontWeight.w700,
              color: Colors.white.withOpacity(0.4))),
    );
  }
}
