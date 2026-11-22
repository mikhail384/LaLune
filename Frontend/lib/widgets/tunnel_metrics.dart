// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';

import '../models/vpn_status.dart';

class TunnelMetrics extends StatelessWidget {
  const TunnelMetrics({super.key, required this.status, required this.isTots});

  final VpnStatus status;
  final bool isTots;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.68);
    final requested = status.workersRequested;
    final target = status.workersTarget;
    final rtt = status.tunnelRttMs;
    final paths = [
      ('vk', 'VK', status.workersVk),
      ('jazz', 'Jazz', status.workersJazz),
      ('ya_docs', 'Ya Docs', status.workersYaDocs),
      ('mail_docs', 'Mail', status.workersMailDocs),
      ('cups', 'Cups', status.workersCups),
      ('max', 'MAX', status.workersMax),
    ];

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status.trafficAvailable)
            Row(
              children: [
                Expanded(
                  child: _TrafficDirection(
                    icon: Icons.south_rounded,
                    label: 'Входящий',
                    color: const Color(0xFF7CFF9A),
                    bytes: status.rxBytes,
                    rate: status.trafficRatesAvailable ? status.rxRate : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TrafficDirection(
                    icon: Icons.north_rounded,
                    label: 'Исходящий',
                    color: const Color(0xFF91B8FF),
                    bytes: status.txBytes,
                    rate: status.trafficRatesAvailable ? status.txRate : null,
                  ),
                ),
              ],
            )
          else
            Text(
              isTots && !status.workersAvailable
                  ? 'Ожидание данных ToTS'
                  : 'Счётчики трафика недоступны',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          if (isTots) ...[
            Divider(height: 22, color: Colors.white.withValues(alpha: 0.12)),
            _MetricRow(
              label: 'Пинг до VPS через ToTS',
              value: rtt > 0 ? '$rtt мс' : 'Ожидание',
            ),
            const SizedBox(height: 8),
            _MetricRow(
              label: 'Активные workers',
              value:
                  status.workersAvailable
                      ? '${status.workers} / $target'
                      : 'Согласование',
            ),
            if (target > 0 && requested > target)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  'Запрошено $requested · доступно по профилю $target',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            if (status.workerProvidersAvailable) ...[
              const SizedBox(height: 7),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  for (final (key, label, active) in paths)
                    if (active > 0 || (status.workerTargets[key] ?? 0) > 0)
                      Text(
                        status.workerTargets.containsKey(key)
                            ? '$label $active / ${status.workerTargets[key]}'
                            : '$label $active',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
        const SizedBox(width: 8),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _TrafficDirection extends StatelessWidget {
  const _TrafficDirection({
    required this.icon,
    required this.label,
    required this.color,
    required this.bytes,
    required this.rate,
  });

  final IconData icon;
  final String label;
  final Color color;
  final int bytes;
  final int? rate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final speed = rate;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              Text(
                speed == null ? 'Замер…' : '${_formatBytes(speed)}/с',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Всего ${_formatBytes(bytes)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatBytes(int value) {
  if (value < 1024) return '$value Б';
  const units = ['КиБ', 'МиБ', 'ГиБ', 'ТиБ'];
  var amount = value / 1024.0;
  var unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit++;
  }
  return '${amount.toStringAsFixed(amount >= 100 ? 0 : 1)} ${units[unit]}';
}
