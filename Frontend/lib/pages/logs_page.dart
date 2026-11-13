// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/log_digest.dart';
import '../state/logs_notifier.dart';
import '../widgets/glass_card.dart';

const _maxVisibleLogs = 150;

class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  final _scroll = ScrollController();

  /// false — короткий читаемый лог (по умолчанию), true — все сырые строки.
  bool _detailed = false;

  late final LogsNotifier _logs;

  // Свёртка пересчитывается только когда пришли новые строки, а не на каждую
  // перерисовку (на слабых телефонах это заметно).
  List<String>? _digestSource;
  List<DigestEntry> _digestCache = const [];

  List<DigestEntry> _digestOf(List<String> all, List<String> times) {
    if (!identical(all, _digestSource)) {
      _digestSource = all;
      _digestCache = digestLogs(all, times: times);
    }
    return _digestCache;
  }

  @override
  void initState() {
    super.initState();
    _logs = ref.read(logsProvider.notifier);
    // Загрузка логов идёт только пока вкладка открыта.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _logs.activate();
    });
  }

  @override
  void dispose() {
    _logs.deactivate();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(logsProvider);
    final recentLines = logs.lines.length > _maxVisibleLogs
        ? logs.lines.sublist(logs.lines.length - _maxVisibleLogs)
        : logs.lines;
    final recentTimes = logs.times.length == logs.lines.length
        ? (logs.times.length > _maxVisibleLogs
            ? logs.times.sublist(logs.times.length - _maxVisibleLogs)
            : logs.times)
        : List<String>.filled(recentLines.length, '');
    final visibleLines = recentLines.reversed.toList(growable: false);
    final visibleTimes = recentTimes.reversed.toList(growable: false);
    final stats = _LogStats.fromLines(recentLines);
    final digest = _digestOf(logs.allLines, logs.allTimes);
    final shortWarn = digest.where((e) => e.level == DigestLevel.warn).length;
    final shortErr = digest.where((e) => e.level == DigestLevel.error).length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            children: [
              Row(
                children: [
                  const Text('Логи',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  FilterChip(
                    label: const Text('Подробно'),
                    selected: _detailed,
                    onSelected: (v) => setState(() => _detailed = v),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    onPressed: logs.lines.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(ClipboardData(
                                text: _detailed
                                    ? [
                                    for (var i = 0; i < logs.lines.length; i++)
                                      (i < logs.times.length && logs.times[i].isNotEmpty
                                              ? '[${logs.times[i]}] '
                                              : '') +
                                          logs.lines[i],
                                  ].join('\n')
                                    : digest.map((e) {
                                        final rep =
                                            e.showRepeat ? ' ×${e.count}' : '';
                                        final at =
                                            e.time.isEmpty ? '' : '${e.time} ';
                                        return '$at${_levelMark(e.level)} ${e.text}$rep';
                                      }).join('\n')));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Логи скопированы'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                    tooltip: 'Копировать все логи',
                    icon: const Icon(Icons.copy_all_outlined, size: 20),
                  ),
                  IconButton(
                    onPressed: () => ref.read(logsProvider.notifier).clear(),
                    tooltip: 'Очистить',
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
                ],
              ),
              // Счётчики — отдельной строкой под заголовком, чтобы не сжимались
              // на узких экранах (раньше текст рвало на вертикальные столбики).
              if (_detailed || shortWarn > 0 || shortErr > 0) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 6,
                    children: [
                      if (_detailed)
                        _StatChip(
                            label: 'Инфо',
                            count: stats.info,
                            color: const Color(0xFF65B8F3)),
                      if (_detailed || shortWarn > 0)
                        _StatChip(
                            label: 'Внимание',
                            count: _detailed ? stats.warnings : shortWarn,
                            color: const Color(0xFFFFB74D)),
                      if (_detailed || shortErr > 0)
                        _StatChip(
                            label: 'Ошибки',
                            count: _detailed ? stats.errors : shortErr,
                            color: const Color(0xFFFF626C)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: !_detailed
                    ? _ShortLog(entries: digest)
                    : GlassCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      // Сводка закреплена над прокручиваемыми строками и всегда видна.
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.035),
                          border: Border(
                            bottom: BorderSide(
                                color: Colors.white.withOpacity(0.10)),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.analytics_outlined,
                                size: 16,
                                color: Colors.white.withOpacity(0.65)),
                            const SizedBox(width: 8),
                            Text(
                              logs.lines.length > visibleLines.length
                                  ? 'Последние ${visibleLines.length} из ${logs.lines.length}'
                                  : 'Записей: ${visibleLines.length}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withOpacity(0.8),
                              ),
                            ),
                            const Spacer(),
                            _CompactStat(
                                label: 'INFO',
                                count: stats.info,
                                color: const Color(0xFF65B8F3)),
                            const SizedBox(width: 10),
                            _CompactStat(
                                label: 'WARN',
                                count: stats.warnings,
                                color: const Color(0xFFFFB74D)),
                            const SizedBox(width: 10),
                            _CompactStat(
                                label: 'ERROR',
                                count: stats.errors,
                                color: const Color(0xFFFF626C)),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Scrollbar(
                          controller: _scroll,
                          child: visibleLines.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 30),
                                    child: Text('Логи пусты',
                                        style: TextStyle(
                                            color: Colors.white
                                                .withOpacity(0.45))),
                                  ),
                                )
                              : ListView.builder(
                                  controller: _scroll,
                                  padding: const EdgeInsets.all(10),
                                  itemCount: visibleLines.length,
                                  itemBuilder: (context, index) => Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: _LogLine(
                                      key: ValueKey(
                                          '${index}_${visibleLines[index].hashCode}'),
                                      line: visibleLines[index],
                                      time: visibleTimes[index],
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _levelMark(DigestLevel l) {
  switch (l) {
    case DigestLevel.ok:
      return '[OK]';
    case DigestLevel.info:
      return '[i]';
    case DigestLevel.warn:
      return '[!]';
    case DigestLevel.error:
      return '[ERR]';
  }
}

Color _digestColor(DigestLevel l) {
  switch (l) {
    case DigestLevel.ok:
      return const Color(0xFF65D6A2);
    case DigestLevel.info:
      return const Color(0xFF8FA8C0);
    case DigestLevel.warn:
      return const Color(0xFFFFB74D);
    case DigestLevel.error:
      return const Color(0xFFFF626C);
  }
}

/// Короткий лог: одна строка на событие, новые сверху.
class _ShortLog extends StatelessWidget {
  final List<DigestEntry> entries;
  const _ShortLog({required this.entries});

  @override
  Widget build(BuildContext context) {
    final items = entries.reversed.toList(growable: false);
    return GlassCard(
      padding: EdgeInsets.zero,
      child: items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Text('Логи пусты',
                    style: TextStyle(color: Colors.white.withOpacity(0.45))),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final e = items[i];
                final color = _digestColor(e.level);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5, right: 10),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration:
                            BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                    ),
                    if (e.time.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 8),
                        child: Text(
                          e.time,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Colors.white.withOpacity(0.45),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        e.showRepeat ? '${e.text}  ×${e.count}' : e.text,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.35,
                          color: e.level == DigestLevel.info
                              ? Colors.white.withOpacity(0.8)
                              : color,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _LogLine extends StatefulWidget {
  final String line;
  final String time;
  const _LogLine({super.key, required this.line, this.time = ''});

  @override
  State<_LogLine> createState() => _LogLineState();
}

class _LogLineState extends State<_LogLine> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final parsed = _ParsedLogLine.parse(widget.line);
    final severity = _severityForEntry(parsed);
    final color = _severityColor(severity);
    final isLong = parsed.message.length > 150 || parsed.message.contains('\n');
    final visibleTags = parsed.tags.take(3);
    final hiddenTagCount = parsed.tags.length - visibleTags.length;

    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 5,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _SeverityChip(severity: severity),
              if (parsed.time.isNotEmpty || widget.time.isNotEmpty)
                Text(
                  parsed.time.isNotEmpty ? parsed.time : widget.time,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withOpacity(0.55),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              for (final tag in visibleTags) _TagPill(tag: tag),
              if (hiddenTagCount > 0) _TagPill(tag: '+$hiddenTagCount'),
            ],
          ),
          if (parsed.message.isNotEmpty) ...[
            const SizedBox(height: 5),
            if (_expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 170),
                child: SingleChildScrollView(
                  child: SelectableText(
                    parsed.message,
                    style: const TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                ),
              )
            else
              Text(
                parsed.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.4),
              ),
            if (isLong)
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  height: 28,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      visualDensity: VisualDensity.compact,
                      foregroundColor: color,
                    ),
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                    ),
                    label: Text(_expanded ? 'Свернуть' : 'Подробнее'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ParsedLogLine {
  final List<String> tags;
  final String time;
  final String message;

  const _ParsedLogLine(this.tags, this.time, this.message);

  static _ParsedLogLine parse(String line) {
    var remaining = line.trimLeft();
    var time = '';
    final timestamp = RegExp(
      r'^\[?(\d{2}:\d{2}:\d{2}(?:[.,]\d{3})?|\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d{3})?)\]?\s+',
    ).firstMatch(remaining);
    if (timestamp != null) {
      time = timestamp.group(1)!;
      remaining = remaining.substring(timestamp.end);
    }

    final prefix = RegExp(r'^((?:\[[^\]]+\]\s*)+)').firstMatch(remaining);
    if (prefix == null) return _ParsedLogLine(const [], time, remaining);
    final tags = RegExp(r'\[([^\]]+)\]')
        .allMatches(prefix.group(1)!)
        .map((match) => match.group(1)!.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
    return _ParsedLogLine(
      tags,
      time,
      remaining.substring(prefix.end).trimLeft(),
    );
  }
}

_LogSeverity _severityForEntry(_ParsedLogLine entry) {
  final severities = entry.tags.map(_severityForTag).toList();
  if (severities.contains(_LogSeverity.error)) return _LogSeverity.error;
  if (severities.contains(_LogSeverity.warning)) return _LogSeverity.warning;
  if (severities.contains(_LogSeverity.success)) return _LogSeverity.success;
  if (severities.contains(_LogSeverity.info)) return _LogSeverity.info;

  final message = entry.message.toLowerCase();
  if (message.contains('error') || message.contains('exception')) {
    return _LogSeverity.error;
  }
  if (message.contains('warning') || message.contains('warn')) {
    return _LogSeverity.warning;
  }
  if (message.contains('готово') || message.contains('успешно')) {
    return _LogSeverity.success;
  }
  return _LogSeverity.neutral;
}

Color _severityColor(_LogSeverity severity) {
  switch (severity) {
    case _LogSeverity.error:
      return const Color(0xFFFF626C);
    case _LogSeverity.warning:
      return const Color(0xFFFFB74D);
    case _LogSeverity.success:
      return const Color(0xFF65D6A2);
    case _LogSeverity.info:
      return const Color(0xFF65B8F3);
    case _LogSeverity.neutral:
      return const Color(0xFFB0BEC5);
  }
}

String _severityLabel(_LogSeverity severity) {
  switch (severity) {
    case _LogSeverity.error:
      return 'ОШИБКА';
    case _LogSeverity.warning:
      return 'ВНИМАНИЕ';
    case _LogSeverity.success:
      return 'ГОТОВО';
    case _LogSeverity.info:
      return 'ИНФО';
    case _LogSeverity.neutral:
      return 'СОБЫТИЕ';
  }
}

class _SeverityChip extends StatelessWidget {
  final _LogSeverity severity;

  const _SeverityChip({required this.severity});

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(severity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _severityLabel(severity),
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

enum _LogSeverity { info, warning, error, success, neutral }

_LogSeverity _severityForTag(String tag) {
  final value = tag.toUpperCase();
  if (value.contains('ERROR') ||
      value.contains('FAIL') ||
      value.contains('FATAL') ||
      value.contains('EXCEPTION') ||
      value == 'ERR') {
    return _LogSeverity.error;
  }
  if (value.contains('WARN')) return _LogSeverity.warning;
  if (value == 'OK' || value.contains('SUCCESS') || value == 'DONE') {
    return _LogSeverity.success;
  }
  if (value == 'INFO' || value == 'DEBUG' || value == 'TRACE') {
    return _LogSeverity.info;
  }
  return _LogSeverity.neutral;
}

Color _tagColor(String tag) {
  switch (_severityForTag(tag)) {
    case _LogSeverity.error:
      return const Color(0xFFFF626C);
    case _LogSeverity.warning:
      return const Color(0xFFFFB74D);
    case _LogSeverity.success:
      return const Color(0xFF65D6A2);
    case _LogSeverity.info:
      return const Color(0xFF65B8F3);
    case _LogSeverity.neutral:
      switch (tag.toUpperCase()) {
        case 'CORE':
          return const Color(0xFF63D3D1);
        case 'LUA':
          return const Color(0xFFC49BFF);
        case 'SMART-TUNNEL':
          return const Color(0xFF8FAEFF);
        case 'PAPERFLUX':
          return const Color(0xFFFFA86B);
        case 'CSQTT':
          return const Color(0xFF80CBC4);
        default:
          return const Color(0xFFB0BEC5);
      }
  }
}

class _TagPill extends StatelessWidget {
  final String tag;
  const _TagPill({required this.tag});

  @override
  Widget build(BuildContext context) {
    final color = _tagColor(tag);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.48), width: 0.8),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _LogStats {
  final int info;
  final int warnings;
  final int errors;

  const _LogStats(
      {required this.info, required this.warnings, required this.errors});

  factory _LogStats.fromLines(List<String> lines) {
    var info = 0;
    var warnings = 0;
    var errors = 0;
    for (final line in lines) {
      final tags = _ParsedLogLine.parse(line).tags;
      final severities = tags.map(_severityForTag).toList();
      if (severities.contains(_LogSeverity.error)) {
        errors++;
      } else if (severities.contains(_LogSeverity.warning)) {
        warnings++;
      } else {
        info++;
      }
    }
    return _LogStats(info: info, warnings: warnings, errors: errors);
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _StatChip(
      {required this.label, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.32)),
      ),
      child: Text(
        '$label: $count',
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CompactStat extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _CompactStat(
      {required this.label, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text('$label $count',
        style:
            TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700));
  }
}
