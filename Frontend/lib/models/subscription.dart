// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Подписки формата LaLuneSUB.
//
// В поле ссылки указывается http(s)-ссылка, которая вернёт JSON, либо
// data:-URL, содержащий этот JSON. Формат:
//
//   {
//     "Имя #1": {"config": "...", "protocol": "CSQTTR", "expires": "0"},
//     "Имя #2": {"config": "...", "protocol": "CSQTT-2.5.1", "expires": "0", "icon": "data:image/png;base64,..."},
//     "hoster": "LaLune Free sub",
//     "traffic": "10TB",
//     "sub_control": "https://t.me/lalune_freedombot"
//   }
//
// Ключи кроме hoster/traffic/sub_control — это конфиги (имя выбирает автор).
// expires: "0" — бессрочно, иначе дата в UTC. sub_control — необязателен.

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Префикс, которым можно явно пометить ссылку на подписку.
final RegExp _prefix = RegExp(r'^\s*lalunesub\s*:\s*', caseSensitive: false);

/// true, если введённая строка похожа на подписку LaLuneSUB (а не на обычный
/// профиль csqtt:// / csqttr:// / tots://).
bool looksLikeSubscription(String input) {
  final s = input.trim();
  if (_prefix.hasMatch(s)) return true;
  final lower = s.toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('data:');
}

/// Убирает необязательный префикс `LaLuneSUB:` и пробелы.
String stripSubscriptionPrefix(String input) =>
    input.trim().replaceFirst(_prefix, '').trim();

/// Приводит протокол из подписки к тому виду, что понимает backend.
String normalizeSubProtocol(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return 'CSQTT';
  final upper = s.toUpperCase().replaceAll('_', ' ').replaceAll('-', ' ');
  switch (upper) {
    case 'CSQTT 2.5.1':
    case 'CSQTT 251':
      return 'CSQTT 2.5.1';
    case 'CSQTT 2.1.9':
    case 'CSQTT 219':
      return 'CSQTT 2.1.9';
    case 'CSQTT':
      return 'CSQTT';
    case 'CSQTTR':
    case 'CSQTTR 2.5.2':
      return 'CSQTTR';
    case 'TOTS':
      return 'ToTS';
    case 'WDTToR':
    case 'WDTT':
    case 'WDTToR (WDTT)':
    case 'WDTTO':
      return 'WDTToR';
  }
  return s;
}

/// Дата окончания: "0"/пусто — бессрочно (null). Иначе UTC.
DateTime? parseSubExpires(Object? raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty || s == '0') return null;
  final asInt = int.tryParse(s);
  if (asInt != null) {
    if (asInt <= 0) return null;
    // unix-время в секундах или миллисекундах
    return DateTime.fromMillisecondsSinceEpoch(
            asInt > 100000000000 ? asInt : asInt * 1000,
            isUtc: true);
  }
  var parsed = DateTime.tryParse(s);
  if (parsed == null) {
    // "dd.MM.yyyy[ HH:mm[:ss]]"
    final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$')
        .firstMatch(s);
    if (m != null) {
      parsed = DateTime.utc(
        int.parse(m.group(3)!),
        int.parse(m.group(2)!),
        int.parse(m.group(1)!),
        int.tryParse(m.group(4) ?? '') ?? 0,
        int.tryParse(m.group(5) ?? '') ?? 0,
        int.tryParse(m.group(6) ?? '') ?? 0,
      );
    }
  }
  if (parsed == null) return null;
  // Без указания зоны считаем, что это UTC.
  return parsed.isUtc
      ? parsed
      : DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour,
          parsed.minute, parsed.second);
}

/// "10TB", "500 GB", "1.5TiB" → байты. null — безлимит/не указано.
int? parseTrafficLimit(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final lower = s.toLowerCase();
  if (lower == '0' ||
      lower.contains('unlim') ||
      lower.contains('безлим') ||
      lower.contains('∞')) {
    return null;
  }
  final m = RegExp(r'^([\d.,]+)\s*([kmgtp]?)(?:i?b|б)?$', caseSensitive: false)
      .firstMatch(s.replaceAll(' ', ''));
  if (m == null) return null;
  final value = double.tryParse(m.group(1)!.replaceAll(',', '.'));
  if (value == null || value <= 0) return null;
  const units = {'': 0, 'k': 1, 'm': 2, 'g': 3, 't': 4, 'p': 5};
  final power = units[m.group(2)!.toLowerCase()] ?? 0;
  var bytes = value;
  for (var i = 0; i < power; i++) {
    bytes *= 1024;
  }
  return bytes.round();
}

/// Читаемый размер: 1.5 ГБ.
String formatBytes(num bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ', 'ПБ'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  final text = i == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[i]}';
}

/// Прирост счётчика трафика между двумя опросами. Счётчик backend обнуляется
/// при каждом новом подключении, поэтому если значение уменьшилось — это новая
/// сессия и весь `current` относится к ней.
int trafficDelta(int previous, int current) {
  if (current < 0) return 0;
  return current >= previous ? current - previous : current;
}

class SubConfig {
  final String name;
  final String config;
  final String protocol;

  /// null — бессрочно.
  final DateTime? expires;

  /// Необязательная data:-иконка профиля из подписки.
  final String? icon;

  const SubConfig({
    required this.name,
    required this.config,
    required this.protocol,
    this.expires,
    this.icon,
  });

  /// Идентичность конфига внутри подписки.
  String get key => '$protocol|$config';

  bool get expired =>
      expires != null && DateTime.now().toUtc().isAfter(expires!);

  Map<String, dynamic> toJson() => {
        'name': name,
        'config': config,
        'protocol': protocol,
        'expires': expires?.toIso8601String(),
        if (icon != null) 'icon': icon,
      };

  factory SubConfig.fromJson(Map<String, dynamic> j) => SubConfig(
        name: (j['name'] ?? '').toString(),
        config: (j['config'] ?? '').toString(),
        protocol: (j['protocol'] ?? 'CSQTT').toString(),
        expires: parseSubExpires(j['expires']),
        icon: _normalizeIcon(j['icon']),
      );
}
class Subscription {
  /// Стабильный идентификатор (из источника).
  final String id;

  /// Как ввёл пользователь: http(s)-ссылка или data:-URL.
  final String source;
  final String hoster;

  /// Исходная строка лимита ("10TB").
  final String traffic;
  final String? subControl;
  final List<SubConfig> configs;
  final DateTime? updatedAt;
  final String? error;

  /// Реально израсходованный трафик по конфигам этой подписки (байты).
  final int usedBytes;
  /// Directional totals since directional accounting was introduced.
  /// Older aggregate-only history remains included in usedBytes.
  final int receivedBytes;
  final int sentBytes;

  // Last tunnel snapshot persisted together with the totals. A matching
  // session can be resumed without either losing or counting bytes twice.
  final String trafficSessionId;
  final int trafficConfigId;
  final int trafficCheckpointRx;
  final int trafficCheckpointTx;

  /// SubConfig.key → id конфига в backend (конфиг создаётся при выборе).
  final Map<String, int> backendIds;

  const Subscription({
    required this.id,
    required this.source,
    required this.hoster,
    this.traffic = '',
    this.subControl,
    this.configs = const [],
    this.updatedAt,
    this.error,
    this.usedBytes = 0,
    this.receivedBytes = 0,
    this.sentBytes = 0,
    this.trafficSessionId = '',
    this.trafficConfigId = 0,
    this.trafficCheckpointRx = 0,
    this.trafficCheckpointTx = 0,
    this.backendIds = const {},
  });

  int? get limitBytes => parseTrafficLimit(traffic);

  Subscription copyWith({
    String? hoster,
    String? traffic,
    String? subControl,
    bool clearSubControl = false,
    List<SubConfig>? configs,
    DateTime? updatedAt,
    String? error,
    bool clearError = false,
    int? usedBytes,
    int? receivedBytes,
    int? sentBytes,
    String? trafficSessionId,
    int? trafficConfigId,
    int? trafficCheckpointRx,
    int? trafficCheckpointTx,
    Map<String, int>? backendIds,
  }) =>
      Subscription(
        id: id,
        source: source,
        hoster: hoster ?? this.hoster,
        traffic: traffic ?? this.traffic,
        subControl: clearSubControl ? null : (subControl ?? this.subControl),
        configs: configs ?? this.configs,
        updatedAt: updatedAt ?? this.updatedAt,
        error: clearError ? null : (error ?? this.error),
        usedBytes: usedBytes ?? this.usedBytes,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        sentBytes: sentBytes ?? this.sentBytes,
        trafficSessionId: trafficSessionId ?? this.trafficSessionId,
        trafficConfigId: trafficConfigId ?? this.trafficConfigId,
        trafficCheckpointRx: trafficCheckpointRx ?? this.trafficCheckpointRx,
        trafficCheckpointTx: trafficCheckpointTx ?? this.trafficCheckpointTx,
        backendIds: backendIds ?? this.backendIds,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source,
        'hoster': hoster,
        'traffic': traffic,
        'subControl': subControl,
        'configs': configs.map((c) => c.toJson()).toList(),
        'updatedAt': updatedAt?.toIso8601String(),
        'usedBytes': usedBytes,
        'receivedBytes': receivedBytes,
        'sentBytes': sentBytes,
        'trafficSessionId': trafficSessionId,
        'trafficConfigId': trafficConfigId,
        'trafficCheckpointRx': trafficCheckpointRx,
        'trafficCheckpointTx': trafficCheckpointTx,
        'backendIds': backendIds,
      };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: (j['id'] ?? '') as String,
        source: (j['source'] ?? '') as String,
        hoster: (j['hoster'] ?? 'Подписка') as String,
        traffic: (j['traffic'] ?? '') as String,
        subControl: j['subControl'] as String?,
        configs: ((j['configs'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => SubConfig.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        updatedAt: DateTime.tryParse((j['updatedAt'] ?? '') as String),
        usedBytes: (j['usedBytes'] as num?)?.toInt() ?? 0,
        receivedBytes: (j['receivedBytes'] as num?)?.toInt() ?? 0,
        sentBytes: (j['sentBytes'] as num?)?.toInt() ?? 0,
        trafficSessionId: (j['trafficSessionId'] as String?) ?? '',
        trafficConfigId: (j['trafficConfigId'] as num?)?.toInt() ?? 0,
        trafficCheckpointRx: (j['trafficCheckpointRx'] as num?)?.toInt() ?? 0,
        trafficCheckpointTx: (j['trafficCheckpointTx'] as num?)?.toInt() ?? 0,
        backendIds: ((j['backendIds'] as Map?) ?? const {}).map(
          (k, v) => MapEntry(k.toString(), (v as num).toInt()),
        ),
      );
}

/// Идентификатор подписки по источнику (без хешей-зависимостей).
String subscriptionIdFor(String source) {
  var h = 0xcbf29ce484222325 & 0x7fffffffffffffff;
  for (final unit in source.codeUnits) {
    h = ((h ^ unit) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return 's${h.toRadixString(36)}';
}

class SubscriptionFormatException implements Exception {
  final String message;
  const SubscriptionFormatException(this.message);
  @override
  String toString() => message;
}

/// Разбирает JSON подписки. Недопустимые записи пропускаются, но подписка без
/// единого конфига считается ошибкой.
Subscription parseLaLuneSub(
  String jsonText, {
  required String source,
  Subscription? previous,
}) {
  final decoded = _decodeSubscriptionPayload(jsonText);
  Map<String, dynamic> root;
  Object? rawConfigs;

  if (decoded is Map) {
    root = Map<String, dynamic>.from(decoded);
    rawConfigs = _takeCaseInsensitive(root, 'configs');
  } else if (decoded is List) {
    root = <String, dynamic>{};
    rawConfigs = decoded;
  } else {
    throw const SubscriptionFormatException(
        'Формат подписки: ожидался JSON-объект или список');
  }

  final hoster = (_takeCaseInsensitive(root, 'hoster') ?? '').toString().trim();
  final traffic = (_takeCaseInsensitive(root, 'traffic') ?? '').toString().trim();
  final control =
      (_takeCaseInsensitive(root, 'sub_control') ??
              _takeCaseInsensitive(root, 'subControl') ??
              '')
          .toString()
          .trim();

  // Старый формат хранит конфиги прямо в корне. Новый также может использовать
  // поле "configs" как объект или список.
  rawConfigs ??= root;

  final configs = <SubConfig>[];
  if (rawConfigs is Map) {
    final map = Map<Object?, Object?>.from(rawConfigs);
    for (final entry in map.entries) {
      final name = entry.key.toString().trim();
      final value = entry.value;
      if (_isMetadataKey(name)) continue;
      final parsed = _parseSubConfigValue(
        value,
        fallbackName: name.isEmpty ? 'Конфиг ${configs.length + 1}' : name,
      );
      if (parsed != null) configs.add(parsed);
    }
  } else if (rawConfigs is List) {
    for (final value in rawConfigs) {
      final parsed = _parseSubConfigValue(
        value,
        fallbackName: 'Конфиг ${configs.length + 1}',
      );
      if (parsed != null) configs.add(parsed);
    }
  }

  if (configs.isEmpty) {
    throw const SubscriptionFormatException('В подписке нет ни одного конфига');
  }

  final id = previous?.id ?? subscriptionIdFor(source);
  return Subscription(
    id: id,
    source: source,
    hoster: hoster.isEmpty ? 'Подписка' : hoster,
    traffic: traffic,
    subControl: control.isEmpty ? null : control,
    configs: configs,
    updatedAt: DateTime.now().toUtc(),
    usedBytes: previous?.usedBytes ?? 0,
    receivedBytes: previous?.receivedBytes ?? 0,
    sentBytes: previous?.sentBytes ?? 0,
    trafficSessionId: previous?.trafficSessionId ?? '',
    trafficConfigId: previous?.trafficConfigId ?? 0,
    trafficCheckpointRx: previous?.trafficCheckpointRx ?? 0,
    trafficCheckpointTx: previous?.trafficCheckpointTx ?? 0,
    backendIds: {
      for (final c in configs)
        if (previous?.backendIds[c.key] != null)
          c.key: previous!.backendIds[c.key]!,
    },
  );
}

Object _decodeSubscriptionPayload(String input) {
  var text = input.trim();
  if (text.startsWith('\uFEFF')) text = text.substring(1).trimLeft();
  if (text.startsWith('```')) {
    text = text.replaceFirst(
        RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
    text = text.replaceFirst(RegExp(r'\s*```\s*$'), '');
  }

  Object? decoded = _tryJson(text);
  decoded ??= _tryJson(_extractJsonEnvelope(text) ?? '');

  // Некоторые сервисы заворачивают JSON/base64 ещё в JSON-строку.
  for (var i = 0; i < 2 && decoded is String; i++) {
    final inner = _maybeBase64(decoded).trim();
    decoded = _tryJson(inner) ?? _tryJson(_extractJsonEnvelope(inner) ?? '');
  }

  if (decoded == null) {
    final base = _maybeBase64(text);
    decoded = _tryJson(base) ?? _tryJson(_extractJsonEnvelope(base) ?? '');
  }

  if (decoded == null) {
    throw const SubscriptionFormatException('Подписка вернула не JSON');
  }
  return decoded;
}

Object? _tryJson(String text) {
  if (text.trim().isEmpty) return null;
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

/// Выделяет первый сбалансированный JSON-объект/массив из ответа с лишним
/// текстом вокруг. Учитывает кавычки и экранирование.
String? _extractJsonEnvelope(String text) {
  final source = text.trim();
  var start = -1;
  String? opener;
  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    if (c == '{' || c == '[') {
      start = i;
      opener = c;
      break;
    }
  }
  if (start < 0 || opener == null) return null;
  final closer = opener == '{' ? '}' : ']';
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (var i = start; i < source.length; i++) {
    final c = source[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
      continue;
    }
    if (c == '"') {
      quoted = true;
    } else if (c == opener) {
      depth++;
    } else if (c == closer) {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  return null;
}

Object? _takeCaseInsensitive(Map<String, dynamic> map, String key) {
  final wanted = key.toLowerCase();
  for (final current in map.keys.toList()) {
    if (current.toLowerCase() == wanted) return map.remove(current);
  }
  return null;
}

bool _isMetadataKey(String key) {
  final k = key.toLowerCase();
  return k == 'hoster' ||
      k == 'traffic' ||
      k == 'sub_control' ||
      k == 'subcontrol' ||
      k == 'configs';
}

SubConfig? _parseSubConfigValue(Object? raw, {required String fallbackName}) {
  if (raw is String) {
    final config = raw.trim();
    if (config.isEmpty) return null;
    return SubConfig(
      name: fallbackName,
      config: config,
      protocol: _protocolFromLink(config),
    );
  }
  if (raw is! Map) return null;
  final value = Map<String, dynamic>.from(raw);
  final config =
      (_takeCaseInsensitive(value, 'config') ??
              _takeCaseInsensitive(value, 'link') ??
              _takeCaseInsensitive(value, 'url') ??
              '')
          .toString()
          .trim();
  if (config.isEmpty) return null;
  final name =
      (_takeCaseInsensitive(value, 'name') ?? fallbackName).toString().trim();
  final protocolRaw = (_takeCaseInsensitive(value, 'protocol') ?? '').toString();
  final expires = _takeCaseInsensitive(value, 'expires') ??
      _takeCaseInsensitive(value, 'expire') ??
      _takeCaseInsensitive(value, 'expiry');
  final icon = _takeCaseInsensitive(value, 'icon');
  final normalized = normalizeSubProtocol(protocolRaw);
  return SubConfig(
    name: name.isEmpty ? fallbackName : name,
    config: config,
    protocol: protocolRaw.trim().isEmpty ? _protocolFromLink(config) : normalized,
    expires: parseSubExpires(expires),
    icon: _normalizeIcon(icon),
  );
}

String _protocolFromLink(String link) {
  final lower = link.trimLeft().toLowerCase();
  if (lower.startsWith('tots://')) return 'ToTS';
  if (lower.startsWith('wdtt://')) return 'WDTToR';
  if (lower.startsWith('csqttr://')) return 'CSQTTR';
  if (lower.startsWith('csqtt://')) return 'CSQTT';
  return 'CSQTT';
}

String? _normalizeIcon(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty || !value.toLowerCase().startsWith('data:image/')) return null;
  try {
    final parsed = UriData.parse(value);
    if (!parsed.mimeType.toLowerCase().startsWith('image/')) return null;
    final bytes = parsed.contentAsBytes();
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) return null;
    return value;
  } catch (_) {
    return null;
  }
}
/// Загружает текст подписки: из data:-URL или по http(s).
Future<String> fetchSubscriptionText(
  String input, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final src = stripSubscriptionPrefix(input);
  const maxBytes = 2 * 1024 * 1024;
  if (src.toLowerCase().startsWith('data:')) {
    try {
      // Reject oversized encoded data before allocating the decoded payload.
      if (src.length > maxBytes * 3 + 1024) {
        throw const SubscriptionFormatException('Подписка слишком большая');
      }
      final data = UriData.parse(src);
      final bytes = data.contentAsBytes();
      if (bytes.length > maxBytes) {
        throw const SubscriptionFormatException('Подписка слишком большая');
      }
      // contentAsString() падает на не-ASCII без charset: декодируем сами в UTF-8.
      return _maybeBase64(utf8.decode(bytes, allowMalformed: true));
    } on SubscriptionFormatException {
      rethrow;
    } catch (_) {
      throw const SubscriptionFormatException('Некорректный data:-URL подписки');
    }
  }
  final uri = Uri.tryParse(src);
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty) {
    throw const SubscriptionFormatException(
        'Ожидалась http(s)-ссылка или data:-URL');
  }
  final c = client ?? http.Client();
  try {
    final request = http.Request('GET', uri)..headers.addAll(const {
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': 'LaLune',
    });
    final resp = await c.send(request).timeout(timeout);
    if (resp.statusCode != 200) {
      throw SubscriptionFormatException('Сервер подписки ответил ${resp.statusCode}');
    }
    if (resp.contentLength != null && resp.contentLength! > maxBytes) {
      throw const SubscriptionFormatException('Подписка слишком большая');
    }
    final bytes = <int>[];
    await for (final chunk in resp.stream.timeout(timeout)) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const SubscriptionFormatException('Подписка слишком большая');
      }
      bytes.addAll(chunk);
    }
    return _maybeBase64(utf8.decode(bytes, allowMalformed: true));
  } on SubscriptionFormatException {
    rethrow;
  } catch (e) {
    throw SubscriptionFormatException('Не удалось получить подписку: ${_short(e)}');
  } finally {
    if (client == null) c.close();
  }
}

String _short(Object e) {
  final s = e.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

/// Некоторые серверы отдают JSON в base64: если текст не JSON, пробуем декодировать.
String _maybeBase64(String text) {
  var t = text.trim();
  if (t.startsWith('\uFEFF')) t = t.substring(1).trimLeft();
  if (t.startsWith('{') || t.startsWith('[') || t.startsWith('"')) return t;

  final compact = t.replaceAll(RegExp(r'\s+'), '');
  for (final codec in <Base64Codec>[base64, base64Url]) {
    try {
      final bytes = codec.decode(codec.normalize(compact));
      final decoded =
          utf8.decode(Uint8List.fromList(bytes), allowMalformed: true).trim();
      if (decoded.isNotEmpty) return decoded;
    } catch (_) {}
  }
  return t;
}
