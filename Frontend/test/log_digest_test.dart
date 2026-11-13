import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/state/log_digest.dart';

List<String> _texts(List<String> raw) =>
    digestLogs(raw).map((e) => e.text).toList();

void main() {
  test('core noise is dropped and a healthy connect becomes a few lines', () {
    final raw = <String>[
      '[VPN] connecting using CSQTT 2.1.9',
      '[CORE] [КЛИЕНТ] Воркеров: 10 (групп: 1, по 10)',
      '[CORE] [VK] Запрос по хешу звонка',
      '[CORE] [STREAM 100] [VKCalls] step1 OK, anonymous_token (290 chars)',
      '[CORE] [STREAM 100] [VKCalls] SUCCESS, TURN urls=2',
      for (var i = 0; i < 9; i++) ...[
        '[CORE] [TURN] Подключение к turn:1.2.3.4:19302',
        '[CORE] [TURN] Аллокация активна: relay 1.2.3.4:5000',
        '[CORE] [СЕССИЯ #${i + 1}] Relay: 1.2.3.4:5000',
        '[CORE] [TURN] ChannelBind активен: канал 0x4000',
        '[CORE] [СЕССИЯ #${i + 1}] [DIRECT] Прямой режим обфускации (Video)',
        '[CORE] [СЕССИЯ #${i + 1}] SRTP: DTLS-SRTP ✓',
        '[CORE] [ВОРКЕР #${i + 1}] Конфиг получен',
        '[CORE] [ВОРКЕР #${i + 1}] [READY] Поток готов ✓',
      ],
      '[CORE] [СТАТИСТИКА] Активных: 9 | Трафик: 0.14 МБ',
      '[CORE] [СТАТИСТИКА] Активных: 9 | Трафик: 1.11 МБ',
    ];
    final t = _texts(raw);
    expect(t, [
      'Подключение: CSQTT 2.1.9',
      'VK: авторизация успешна',
      'Защищённых сессий: 9',
      'Потоки готовы: 9',
      'Сессий: 9, трафик ядра: 1.11 МБ',
    ]);
  });

  test('server stream limit and VK failures are collapsed with a counter', () {
    final raw = [
      for (var i = 0; i < 71; i++)
        '[CORE] [ВОРКЕР #$i] Нефатальная ошибка разбора TUNCONF: превышен лимит потоков, продолжаем ожидание',
      '[CORE] [КРЕД #1] Ошибка: error sending request for url (https://api.vk.me/method/auth.getAnonymToken?v=5.1)',
      '[CORE] [КРЕД #2] Ошибка: error sending request for url (https://api.vk.me/method/auth.getAnonymToken?v=5.1)',
    ];
    final e = digestLogs(raw);
    expect(e.length, 2);
    expect(e[0].level, DigestLevel.error);
    expect(e[0].text, contains('лимит потоков исчерпан (×71)'));
    expect(e[1].text, 'VK: нет связи (проверьте доступность VK) ×2');
  });

  test('GETCONF retries keep only the latest number, single errors stay plain', () {
    final e = digestLogs([
      '[CORE] [GETCONF][RETRY] Нет подтверждения, 1 попыток восстановления',
      '[CORE] [GETCONF][RETRY] Нет подтверждения, 18 попыток восстановления',
      '[BACKEND] Что-то пошло не так: Error: boom',
    ]);
    expect(e[0].text, 'Сервер не подтверждает конфигурацию (попыток: 18)');
    expect(e[1].level, DigestLevel.error);
    expect(e[1].text, 'Что-то пошло не так: Error: boom');
  });

  test('result is short even for thousands of lines', () {
    final raw = [
      for (var i = 0; i < 5000; i++) '[CORE] [TURN] Refresh аллокации подтверждён ✓',
      for (var i = 0; i < 200; i++) 'line number $i of unknown format',
    ];
    expect(digestLogs(raw).length, lessThanOrEqualTo(40));
  });
}
