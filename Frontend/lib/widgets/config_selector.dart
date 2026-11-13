// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';

import '../models/config_item.dart';
import '../models/subscription.dart';
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
                  child: Text(text, style: style, textAlign: TextAlign.center)),
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: GlassCard(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            // Кнопка обновления подписок — в правом верхнем углу блока конфигов.
            if (hasSubs)
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
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
                              color: Colors.white.withOpacity(0.7)),
                        ),
                ),
              ),
            if (configs.isNotEmpty) ...[
              ...configs.map((c) => _ConfigRow(
                    config: c,
                    selected: c.id == selectedId,
                    onSelect: () => onSelect(c),
                    onDelete: () => onDelete(c.id),
                  )),
              // Показанный список остаётся, пока backend недоступен.
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
            // Подписки отображаются там же, где конфиги (после обычных).
            for (final sub in subscriptions)
              _SubGroup(
                sub: sub,
                expanded: expandedSubs.contains(sub.id),
                selectedBackendId: selectedId,
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

/// Группа подписки: имя хостера, трафик и (в развёрнутом виде) её конфиги,
/// сдвинутые чуть правее обычных.
class _SubGroup extends StatelessWidget {
  final Subscription sub;
  final bool expanded;
  final int? selectedBackendId;
  final VoidCallback onToggle;
  final VoidCallback? onOpenControl;
  final VoidCallback onDelete;
  final ValueChanged<SubConfig> onSelectConfig;

  const _SubGroup({
    required this.sub,
    required this.expanded,
    required this.selectedBackendId,
    required this.onToggle,
    required this.onOpenControl,
    required this.onDelete,
    required this.onSelectConfig,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF7C9CFF);
    final limit = sub.limitBytes;
    final used = sub.usedBytes;
    final ratio = limit == null ? 0.0 : (used / limit).clamp(0.0, 1.0);
    final nearLimit = limit != null && ratio >= 0.9;
    final trafficText = limit == null
        ? 'Трафик: ${formatBytes(used)}${sub.traffic.isEmpty ? '' : ' · ${sub.traffic}'}'
        : 'Трафик: ${formatBytes(used)} из ${formatBytes(limit)}';

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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: expanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: Icon(Icons.chevron_right,
                            size: 20, color: Colors.white.withOpacity(0.7)),
                      ),
                      const SizedBox(width: 6),
                      // Имя + счётчик занимают всю свободную ширину (раньше Spacer
                      // делил её пополам с именем и обрезал его).
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              // Нажатие на имя хостера открывает sub_control.
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: onOpenControl ?? onToggle,
                                child: Text(
                                  sub.hoster,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
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
                          child: const Icon(Icons.error_outline,
                              size: 16, color: Color(0xFFFFB74D)),
                        ),
                      IconButton(
                        onPressed: onDelete,
                        tooltip: 'Удалить подписку',
                        splashRadius: 16,
                        iconSize: 16,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 28, minHeight: 28),
                        icon: Icon(Icons.close,
                            color: Colors.white.withOpacity(0.35)),
                      ),
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
              onTap: () => onSelectConfig(c),
            ),
      ],
    );
  }
}

/// Конфиг внутри подписки — со сдвигом вправо относительно обычных конфигов.
class _SubConfigRow extends StatelessWidget {
  final SubConfig config;
  final bool selected;
  final VoidCallback onTap;

  const _SubConfigRow(
      {required this.config, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final expired = config.expired;
    final badgeColor = config.protocol.toLowerCase() == 'paperflux'
        ? const Color(0xFFF7E84E)
        : const Color(0xFF4A6CF7);
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? badgeColor.withOpacity(0.22)
                  : Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? badgeColor.withOpacity(0.55)
                    : Colors.white.withOpacity(0.08),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeColor.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    config.protocol,
                    style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: badgeColor),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(config.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
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
                if (selected)
                  const Icon(Icons.check_circle,
                      size: 16, color: Color(0xFF7CFF9A)),
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
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  const _ConfigRow({
    required this.config,
    required this.selected,
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
    // Цвет бейджа зависит от протокола.
    final badgeColor = widget.config.isPaperFlux
        ? const Color(0xFFF7E84E)
        : const Color(0xFF4A6CF7);

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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? badgeColor.withOpacity(0.22)
                : Colors.white.withOpacity(_hover ? 0.06 : 0.02),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? badgeColor.withOpacity(0.55)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  widget.config.protocol,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: badgeColor,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.config.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5),
                    ),
                    if (widget.config.isPaperFlux &&
                        widget.config.transport.isNotEmpty)
                      Text(
                        widget.config.transport,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Colors.white.withOpacity(0.5),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.config.isCsqtt251)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
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
                      child: const Text(
                        '!',
                        style: TextStyle(
                          color: Color(0xFF302900),
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.selected)
                const Icon(Icons.check_circle,
                    size: 16, color: Color(0xFF7CFF9A)),
              const SizedBox(width: 6),
              IconButton(
                onPressed: widget.onDelete,
                splashRadius: 16,
                iconSize: 16,
                icon: Icon(Icons.close,
                    color: Colors.white.withOpacity(_hover ? 0.75 : 0.35)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
