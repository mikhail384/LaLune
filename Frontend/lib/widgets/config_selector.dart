// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/config_item.dart';
import '../models/subscription.dart';
import '../utils/profile_ping.dart';
import 'glass_card.dart';
import 'toast.dart';

class ConfigSelector extends StatelessWidget {
  final List<ConfigItem> configs;
  final int? selectedId;
  final ValueChanged<ConfigItem> onSelect;
  final ValueChanged<int> onDelete;

  /// true только когда API подтвердил список (в т.ч. пустой).
  final bool loaded;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  // --- подписки LaLuneSUB ---
  final List<Subscription> subscriptions;
  final Set<String> expandedSubs;
  final bool refreshingSubs;
  final VoidCallback? onRefreshSubs;
  final ValueChanged<Subscription>? onToggleSub;
  final ValueChanged<Subscription>? onOpenSubControl;
  final ValueChanged<Subscription>? onDeleteSub;
  final void Function(Subscription sub, SubConfig config)? onSelectSubConfig;

  // --- замер задержки ---
  final bool measuringPings;
  final bool pingsMeasured;
  final Map<String, int> pings;
  final VoidCallback? onMeasurePings;

  const ConfigSelector({
    super.key,
    required this.configs,
    required this.selectedId,
    required this.onSelect,
    required this.onDelete,
    this.loaded = true,
    this.loading = false,
    this.error,
    this.onRetry,
    this.subscriptions = const [],
    this.expandedSubs = const {},
    this.refreshingSubs = false,
    this.onRefreshSubs,
    this.onToggleSub,
    this.onOpenSubControl,
    this.onDeleteSub,
    this.onSelectSubConfig,
    this.measuringPings = false,
    this.pingsMeasured = false,
    this.pings = const {},
    this.onMeasurePings,
  });

  Widget _note(String text, {bool spinner = false, Widget? action}) {
    final style = TextStyle(color: Colors.white.withOpacity(0.5));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (spinner) ...[
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 9),
              ],
              Flexible(
                child: Text(text, style: style, textAlign: TextAlign.center),
              ),
            ],
          ),
          if (action != null) action,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasError = error != null && error!.trim().isNotEmpty;
    final hasSubs = subscriptions.isNotEmpty;
    final hasProfiles = configs.isNotEmpty || hasSubs;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: GlassCard(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 4, 5),
              child: Row(
                children: [
                  Text(
                    'Профили',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withOpacity(0.88),
                    ),
                  ),
                  const Spacer(),
                  if (hasProfiles)
                    SizedBox(
                      height: 30,
                      width: 34,
                      child: measuringPings
                          ? const Padding(
                              padding: EdgeInsets.all(8),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              onPressed: onMeasurePings,
                              tooltip: 'Измерить задержку всех профилей',
                              padding: EdgeInsets.zero,
                              iconSize: 19,
                              icon: Icon(Icons.speed,
                                  color: Colors.white.withOpacity(0.72)),
                            ),
                    ),
                  if (hasSubs)
                    SizedBox(
                      height: 30,
                      width: 34,
                      child: refreshingSubs
                          ? const Padding(
                              padding: EdgeInsets.all(8),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              onPressed: onRefreshSubs,
                              tooltip: 'Обновить подписки',
                              padding: EdgeInsets.zero,
                              iconSize: 19,
                              icon: Icon(Icons.refresh,
                                  color: Colors.white.withOpacity(0.72)),
                            ),
                    ),
                ],
              ),
            ),
            if (configs.isNotEmpty) ...[
              ...configs.map((c) => _ConfigRow(
                    config: c,
                    selected: c.id == selectedId,
                    ping: pings[configPingKey(c.id)],
                    pingMeasured: pingsMeasured,
                    onSelect: () => onSelect(c),
                    onDelete: () => onDelete(c.id),
                  )),
              if (hasError)
                _note('Не удалось обновить список — показаны сохранённые данные',
                    action: onRetry == null
                        ? null
                        : TextButton(
                            onPressed: onRetry, child: const Text('Повторить'))),
            ] else if (hasSubs) ...[
              // Есть подписки: «Нет конфигов» не показываем.
            ] else if (!loaded && hasError)
              _note('Не удалось загрузить конфиги — backend недоступен',
                  action: onRetry == null
                      ? null
                      : TextButton(
                          onPressed: onRetry, child: const Text('Повторить')))
            else if (!loaded)
              _note('Загрузка конфигов…', spinner: true)
            else
              _note('Нет конфигов. Нажмите + чтобы добавить'),
            for (final sub in subscriptions)
              _SubGroup(
                sub: sub,
                expanded: expandedSubs.contains(sub.id),
                selectedBackendId: selectedId,
                pings: pings,
                pingMeasured: pingsMeasured,
                onToggle: () => onToggleSub?.call(sub),
                onOpenControl: sub.subControl == null
                    ? null
                    : () => onOpenSubControl?.call(sub),
                onDelete: () => onDeleteSub?.call(sub),
                onSelectConfig: (c) => onSelectSubConfig?.call(sub, c),
              ),
          ],
        ),
      ),
    );
  }
}

class _SubGroup extends StatelessWidget {
  final Subscription sub;
  final bool expanded;
  final int? selectedBackendId;
  final Map<String, int> pings;
  final bool pingMeasured;
  final VoidCallback onToggle;
  final VoidCallback? onOpenControl;
  final VoidCallback onDelete;
  final ValueChanged<SubConfig> onSelectConfig;

  const _SubGroup({
    required this.sub,
    required this.expanded,
    required this.selectedBackendId,
    required this.pings,
    required this.pingMeasured,
    required this.onToggle,
    required this.onOpenControl,
    required this.onDelete,
    required this.onSelectConfig,
  });

  int? get _bestPing {
    final values = <int>[];
    for (final config in sub.configs) {
      final value = pings[subConfigPingKey(sub.id, config)];
      if (value != null) values.add(value);
    }
    if (values.isEmpty) return null;
    values.sort();
    return values.first;
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF7C9CFF);
    final limit = sub.limitBytes;
    final used = sub.usedBytes;
    final ratio = limit == null ? 0.0 : (used / limit).clamp(0.0, 1.0);
    final nearLimit = limit != null && ratio >= 0.9;
    final trafficText = limit == null
        ? 'Локальный расход: ${formatBytes(used)}${sub.traffic.isEmpty ? '' : ' · ${sub.traffic}'}'
        : 'Локальный расход: ${formatBytes(used)} из ${formatBytes(limit)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onToggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: expanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: Icon(Icons.chevron_right,
                            size: 20, color: Colors.white.withOpacity(0.7)),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: onOpenControl ?? onToggle,
                                child: Text(
                                  sub.hoster,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w700,
                                    color: onOpenControl != null ? accent : null,
                                    decoration: onOpenControl != null
                                        ? TextDecoration.underline
                                        : null,
                                    decorationColor: accent.withOpacity(0.6),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('${sub.configs.length}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withOpacity(0.45))),
                          ],
                        ),
                      ),
                      if (sub.error != null)
                        Tooltip(
                          message: sub.error!,
                          child: const Padding(
                            padding: EdgeInsets.only(right: 5),
                            child: Icon(Icons.error_outline,
                                size: 16, color: Color(0xFFFFB74D)),
                          ),
                        ),
                      _PingIndicator(
                          ping: _bestPing, measured: pingMeasured, compact: true),
                      const SizedBox(width: 5),
                      _TrashButton(onPressed: onDelete, tooltip: 'Удалить подписку'),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(38, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trafficText,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: nearLimit
                            ? const Color(0xFFFFB74D)
                            : Colors.white.withOpacity(0.5),
                      ),
                    ),
                    if (sub.receivedBytes + sub.sentBytes > 0) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Получено: ${formatBytes(sub.receivedBytes)} · Отправлено: ${formatBytes(sub.sentBytes)}'
                        '${sub.usedBytes > sub.receivedBytes + sub.sentBytes ? ' (часть истории без разбивки)' : ''}',
                        style: TextStyle(
                            fontSize: 10.5, color: Colors.white.withOpacity(0.5)),
                      ),
                    ],
                    if (limit != null) ...[
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 3,
                          backgroundColor: Colors.white.withOpacity(0.08),
                          valueColor: AlwaysStoppedAnimation<Color>(
                              nearLimit ? const Color(0xFFFFB74D) : accent),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (expanded)
          for (final c in sub.configs)
            _SubConfigRow(
              config: c,
              selected: sub.backendIds[c.key] != null &&
                  sub.backendIds[c.key] == selectedBackendId,
              ping: pings[subConfigPingKey(sub.id, c)],
              pingMeasured: pingMeasured,
              onTap: () => onSelectConfig(c),
            ),
      ],
    );
  }
}

class _SubConfigRow extends StatelessWidget {
  final SubConfig config;
  final bool selected;
  final int? ping;
  final bool pingMeasured;
  final VoidCallback onTap;

  const _SubConfigRow({
    required this.config,
    required this.selected,
    required this.ping,
    required this.pingMeasured,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final expired = config.expired;
    const accent = Color(0xFF4A6CF7);
    String? expiryText;
    if (config.expires != null) {
      final d = config.expires!;
      expiryText = expired
          ? 'истёк'
          : 'до ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
    }
    return Padding(
      padding: const EdgeInsets.only(left: 22),
      child: Opacity(
        opacity: expired ? 0.5 : 1,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withOpacity(0.22)
                  : Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? accent.withOpacity(0.55)
                    : Colors.white.withOpacity(0.08),
              ),
            ),
            child: Row(
              children: [
                _SubscriptionIcon(dataUrl: config.icon),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(config.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5)),
                      if (expiryText != null)
                        Text(expiryText,
                            style: TextStyle(
                                fontSize: 10,
                                color: expired
                                    ? const Color(0xFFFF626C)
                                    : Colors.white.withOpacity(0.5))),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _ProtocolPingColumn(
                  protocol: config.protocol,
                  ping: ping,
                  measured: pingMeasured,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfigRow extends StatefulWidget {
  final ConfigItem config;
  final bool selected;
  final int? ping;
  final bool pingMeasured;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  const _ConfigRow({
    required this.config,
    required this.selected,
    required this.ping,
    required this.pingMeasured,
    required this.onSelect,
    required this.onDelete,
  });

  @override
  State<_ConfigRow> createState() => _ConfigRowState();
}

class _ConfigRowState extends State<_ConfigRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF4A6CF7);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onSelect,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? accent.withOpacity(0.22)
                : Colors.white.withOpacity(_hover ? 0.06 : 0.02),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? accent.withOpacity(0.55)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.vpn_key_outlined,
                    size: 17, color: Colors.white.withOpacity(0.65)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.config.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
              if (widget.config.isCsqtt251)
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 6),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Toast.show(
                      context,
                      'CSQTT 2.5.1: возможны проблемы с DTLS, совместимостью соединения и стабильностью туннеля. Если подключение не работает, попробуйте CSQTT 2.1.9.',
                      duration: const Duration(seconds: 5),
                    ),
                    child: Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7E84E),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text('!',
                          style: TextStyle(
                              color: Color(0xFF302900),
                              fontSize: 14,
                              fontWeight: FontWeight.w900)),
                    ),
                  ),
                ),
              _ProtocolPingColumn(
                protocol: widget.config.protocol,
                ping: widget.ping,
                measured: widget.pingMeasured,
              ),
              const SizedBox(width: 7),
              _TrashButton(
                onPressed: widget.onDelete,
                tooltip: 'Удалить профиль',
                opacity: _hover ? 0.82 : 0.48,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProtocolPingColumn extends StatelessWidget {
  final String protocol;
  final int? ping;
  final bool measured;

  const _ProtocolPingColumn({
    required this.protocol,
    required this.ping,
    required this.measured,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            protocol,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF8EA5FF),
            ),
          ),
          const SizedBox(height: 3),
          _PingIndicator(ping: ping, measured: measured),
        ],
      ),
    );
  }
}

class _PingIndicator extends StatelessWidget {
  final int? ping;
  final bool measured;
  final bool compact;

  const _PingIndicator({
    required this.ping,
    required this.measured,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final value = ping;
    final Color color;
    final int bars;
    if (value == null) {
      color = Colors.white.withOpacity(0.32);
      bars = 0;
    } else if (value < 70) {
      color = const Color(0xFF70E38B);
      bars = 4;
    } else if (value <= 100) {
      color = const Color(0xFF70E38B);
      bars = 3;
    } else if (value < 200) {
      color = const Color(0xFFF2C94C);
      bars = 2;
    } else {
      color = const Color(0xFFFF626C);
      bars = 1;
    }
    final label = value == null ? (measured ? '—' : '—') : '$value ms';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: compact ? 9.5 : 9.5,
                fontWeight: FontWeight.w700,
                color: color)),
        const SizedBox(width: 4),
        _SignalBars(activeBars: bars, color: color, compact: compact),
      ],
    );
  }
}

class _SignalBars extends StatelessWidget {
  final int activeBars;
  final Color color;
  final bool compact;

  const _SignalBars({
    required this.activeBars,
    required this.color,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 11 : 12,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(4, (index) {
          final active = index < activeBars;
          return Container(
            width: compact ? 2.3 : 2.6,
            height: (index + 1) * (compact ? 2.2 : 2.5),
            margin: const EdgeInsets.only(left: 1.4),
            decoration: BoxDecoration(
              color: active ? color : Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(1),
            ),
          );
        }),
      ),
    );
  }
}

class _SubscriptionIcon extends StatelessWidget {
  final String? dataUrl;
  const _SubscriptionIcon({required this.dataUrl});

  Uint8List? _bytes() {
    final raw = dataUrl;
    if (raw == null || raw.isEmpty) return null;
    try {
      final parsed = UriData.parse(raw);
      final bytes = parsed.contentAsBytes();
      return bytes.isEmpty ? null : Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 34,
        height: 34,
        color: Colors.white.withOpacity(0.06),
        child: bytes == null
            ? Icon(Icons.person_outline,
                size: 19, color: Colors.white.withOpacity(0.62))
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      ),
    );
  }
}

class _TrashButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String tooltip;
  final double opacity;

  const _TrashButton({
    required this.onPressed,
    required this.tooltip,
    this.opacity = 0.58,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      splashRadius: 16,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      icon: SvgPicture.asset(
        'assets/icons/trash.svg',
        width: 16,
        height: 16,
        colorFilter: ColorFilter.mode(
          Colors.white.withOpacity(opacity),
          BlendMode.srcIn,
        ),
      ),
    );
  }
}
