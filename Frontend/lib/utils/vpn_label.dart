// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Подписи состояния подключения.
//
// Backend может держать ядро живым, но отцеплять TUN (Android auto-sleep), и
// сообщает об этом через `message`: «Туннель спит», «Возвращаю туннель». UI
// должен показывать это как есть, а не всегда «Подключено».

const String kVpnMessageConnected = 'Подключено';
const String kVpnMessageSleeping = 'Туннель спит';
const String kVpnMessageReattaching = 'Возвращаю туннель';

/// Подпись для состояния «connected».
///
/// Любое непустое сообщение бэкенда, кроме дефолтного «Подключено», имеет
/// приоритет: именно так сервис сообщает о сне и возврате туннеля.
String vpnConnectedLabel(String message) {
  final text = message.trim();
  if (text.isEmpty || text == kVpnMessageConnected) return kVpnMessageConnected;
  return text;
}
