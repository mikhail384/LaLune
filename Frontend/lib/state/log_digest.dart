// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Короткий читаемый лог: превращает поток сырых строк backend/ядра в
// несколько понятных фраз. Шум (сотни строк TURN/DTLS на подключение)
// отбрасывается, повторы сворачиваются в один пункт со счётчиком, а важные
// события (подключение, ошибки VK, лимит потоков сервера и т. п.) пишутся
// одной фразой. Сырые строки остаются доступны в режиме «Подробно».

enum DigestLevel { ok, info, warn, error }

class DigestEntry {
  final String key;
  final DigestLevel level;

  /// Текст; `{n}` заменяется счётчиком/числом последнего значения.
  final String template;
  final int count;
  final String value;

  /// Время последнего события (ЧЧ:ММ:СС); пусто, если неизвестно.
  final String time;

  const DigestEntry({
    required this.key,
    required this.level,
    required this.template,
    this.count = 1,
    this.value = '',
    this.time = '',
  });

  String get text {
    var t = template;
    // «×{n}» показываем только когда было больше одного повтора.
    if (count <= 1) t = t.replaceAll(RegExp(r'\s*×\{n\}'), '');
    if (t.contains('{n}')) {
      return t.replaceAll('{n}', value.isNotEmpty ? value : '$count');
    }
    return t;
  }

  /// Показывать «×N» отдельно, если счётчик не встроен в текст.
  bool get showRepeat => count > 1 && !template.contains('{n}');

  DigestEntry copyWith(
          {int? count, String? value, DigestLevel? level, String? time}) =>
      DigestEntry(
        key: key,
        level: level ?? this.level,
        template: template,
        count: count ?? this.count,
        value: value ?? this.value,
        time: time ?? this.time,
      );
}

class _Rule {
  final RegExp pattern;
  final String? key; // null — отбросить строку
  final DigestLevel level;
  final String template;

  /// Счётчик берётся из первой группы regexp (последнее значение), иначе
  /// считаем количество срабатываний.
  final bool useCapture;

  const _Rule(this.pattern, this.key, this.level, this.template,
      {this.useCapture = false});
}

final RegExp _digits = RegExp(r'\d+');

final List<_Rule> _rules = [
  // --- шум ядра: отбрасываем полностью ---
  _Rule(RegExp(r'\[TURN\]'), null, DigestLevel.info, ''),
  _Rule(RegExp(r'\[СЕССИЯ #?\d+\] (Relay:|\[DIRECT\])'), null, DigestLevel.info, ''),
  _Rule(RegExp(r'\[СЕССИЯ #?\d+\] DTLS: (старт|полёт|рукопожатие)'), null,
      DigestLevel.info, ''),
  _Rule(RegExp(r'\[КЛИЕНТ\]'), null, DigestLevel.info, ''),
  _Rule(RegExp(r'\[WRAP\]'), null, DigestLevel.info, ''),
  _Rule(RegExp(r'\[VK\] Запрос по хешу'), null, DigestLevel.info, ''),
  _Rule(RegExp(r'\[STREAM \d+\] \[VKCalls\] (Identity|step\d)'), null,
      DigestLevel.info, ''),
  _Rule(RegExp(r'\[КРЕД #?\d+\] (OK|Запрос)'), null, DigestLevel.info, ''),
  _Rule(RegExp(r'\[LUA\]'), null, DigestLevel.info, ''),
  // Предупреждение системного линкера Android о флагах .so — не про приложение.
  _Rule(RegExp(r'WARNING: linker:'), null, DigestLevel.info, ''),
  _Rule(RegExp(r'SMART-TUNNEL'), null, DigestLevel.info, ''),
  _Rule(RegExp(r'^\s*\[CORE\] starting|core starting|\[CORE\] \[CORE\] starting'),
      null, DigestLevel.info, ''),
  _Rule(RegExp(r'Нефатальная ошибка разбора TUNCONF: превышен лимит потоков'),
      'limit', DigestLevel.error,
      'Сервер: лимит потоков исчерпан (×{n}). Отключитесь и подождите ~10 минут'),

  _Rule(RegExp(r'\[BACKEND\] .*started'), 'backend', DigestLevel.ok,
      'Backend запущен'),

  // --- события, которые стоит показать ---
  _Rule(RegExp(r'\[VK Auth\] Success|VKCalls\] SUCCESS'), 'vkauth', DigestLevel.ok,
      'VK: авторизация успешна'),
  _Rule(RegExp(r'api\.vk\.(me|com).*|\[КРЕД #?\d+\] Ошибка'), 'vkerr',
      DigestLevel.error, 'VK: нет связи (проверьте доступность VK) ×{n}'),
  _Rule(RegExp(r'\[ВОРКЕР #?\d+\] \[READY\]'), 'ready', DigestLevel.ok,
      'Потоки готовы: {n}'),
  _Rule(RegExp(r'\[ВОРКЕР #?\d+\] Конфиг получен'), null, DigestLevel.info, ''),
  _Rule(RegExp(r'SRTP: DTLS-SRTP'), 'dtls', DigestLevel.info,
      'Защищённых сессий: {n}'),
  _Rule(RegExp(r'DTLS: повтор'), 'dtlswait', DigestLevel.warn,
      'Сервер не отвечает на рукопожатие ×{n}'),
  _Rule(RegExp(r'\[GETCONF\]\[RETRY\] Нет подтверждения, (\d+)'), 'getconf',
      DigestLevel.warn, 'Сервер не подтверждает конфигурацию (попыток: {n})',
      useCapture: true),
  _Rule(RegExp(r'\[ОЖИДАНИЕ\] Порт|\[АВТО-ПОРТ\]|Address already in use'), 'port',
      DigestLevel.warn, 'Порт ядра занят ×{n}'),
  _Rule(RegExp(r'\[ОШИБКА\] Даунлинк'), 'downlink', DigestLevel.warn,
      'Потеря пакетов от сервера ×{n}'),
  _Rule(RegExp(r'\[CORE\] process exited'), 'exit', DigestLevel.info,
      'Ядро остановлено'),
  _Rule(RegExp(r'\[VPN\] connecting using (.+)'), 'connecting', DigestLevel.info,
      'Подключение: {n}',
      useCapture: true),
  _Rule(RegExp(r'\[VPN\] timeout'), 'timeout', DigestLevel.error,
      'Подключение не удалось: сервер не отвечает'),
];

final RegExp _stats =
    RegExp(r'\[СТАТИСТИКА\] Активных: (\d+) \| Трафик: ([\d.,]+) МБ');
final RegExp _tag = RegExp(r'^\s*(\[[^\]]*\]\s*)+');
final RegExp _errorWord =
    RegExp(r'error|exception|ошибк|не удалось|failed', caseSensitive: false);

/// Сворачивает сырые строки в короткий список (старые → новые).
List<DigestEntry> digestLogs(List<String> raw,
    {int maxEntries = 40, List<String>? times}) {
  final out = <DigestEntry>[];
  DigestEntry? stats;

  var currentTime = '';

  void emit(String key, DigestLevel level, String template, {String? capture}) {
    final idx = out.lastIndexWhere((e) => e.key == key);
    // Один пункт на ключ рядом с предыдущим: считаем повторы, обновляем значение.
    if (idx >= 0 && idx >= out.length - 3) {
      final e = out[idx];
      out[idx] = e.copyWith(
        count: e.count + 1,
        value: capture ?? '${e.count + 1}',
        level: level,
        time: currentTime,
      );
      return;
    }
    out.add(DigestEntry(
      key: key,
      level: level,
      template: template,
      value: capture ?? '1',
      time: currentTime,
    ));
  }

  outer:
  for (var index = 0; index < raw.length; index++) {
    final s = raw[index].trim();
    if (s.isEmpty) continue;
    currentTime = (times != null && index < times.length) ? times[index] : '';

    final st = _stats.firstMatch(s);
    if (st != null) {
      stats = DigestEntry(
        key: 'stats',
        level: DigestLevel.info,
        template: 'Сессий: ${st.group(1)}, трафик ядра: ${st.group(2)} МБ',
        time: currentTime,
      );
      continue;
    }

    for (final rule in _rules) {
      final m = rule.pattern.firstMatch(s);
      if (m == null) continue;
      if (rule.key == null) continue outer;
      final capture =
          rule.useCapture && m.groupCount >= 1 ? m.group(1) : null;
      emit(rule.key!, rule.level, rule.template, capture: capture);
      continue outer;
    }

    // Остальное: ошибки показываем всегда, прочее — укороченно.
    final msg = s.replaceFirst(_tag, '').trim();
    final shown = msg.isEmpty ? s : msg;
    final short = shown.length > 120 ? '${shown.substring(0, 117)}…' : shown;
    final isErr = _errorWord.hasMatch(s);
    emit('raw:$short', isErr ? DigestLevel.error : DigestLevel.info, short);
  }

  if (stats != null) out.add(stats);
  return out.length > maxEntries ? out.sublist(out.length - maxEntries) : out;
}
