# iOS Backend (Swift) — SOCKS5 + incy

`Backend.swift` — точка входа. HTTP-сервер на `127.0.0.1:1062`, ядро CSQTT в
процессе приложения, userspace-стек (TCP/UDP/DNS) и локальный SOCKS5.

## Как это работает

У проекта нет Apple Developer, поэтому NetworkExtension (системный туннель)
недоступен. Схема такая:

1. `TunnelSession` запускает ядро CSQTT/CSQTTR **внутри приложения**; ядро
   отдаёт сырые IPv4-пакеты по UDP на `127.0.0.1:52230`.
2. `PacketPump` читает эти пакеты, `TcpStack` и `UdpNat` реализуют userspace
   TCP/UDP поверх них, `TunnelResolver` делает DNS через туннель.
3. `TunnelSocks5Server` поднимает локальный SOCKS5 (по умолчанию `127.0.0.1:1080`).
4. `IncyConfig` собирает deeplink `incy://add?...` и открывает приложение incy,
   которое поднимает системный VPN и забирает трафик в наш прокси. В deeplink
   передаются исключения: локальные сети, сервисы VK/MAX/CDN/обновлений
   (`Ipv4Routing`) — они идут напрямую.
5. `CallKeepAlive` включает локальный «режим звонка»: аудиосессия
   `.playAndRecord` + `.voiceChat`, вход открыт (микрофон) и сразу
   выбрасывается, а в выход играет локально сгенерированный почти беззвучный
   сигнал «собеседника» (громкость 0). Именно активный звонок не даёт iOS
   приостановить приложение через ~30 секунд после ухода в фон. Если микрофон
   запрещён, режим откатывается в `.playback` (фоновое аудио).

Требуется установленный incy и хотя бы один ручной запуск incy, иначе оно не
примет конфиг.

## Файлы

| Файл | Назначение |
|---|---|
| `Backend.swift` | HTTP-сервер + все роуты |
| `TunnelSession.swift` | Жизненный цикл: ядро, мост, SOCKS5, incy, измерения |
| `TunnelTypes.swift` | Общие типы и протоколы стека |
| `PacketCodec.swift` | Разбор/сборка IPv4, TCP, UDP |
| `TcpStack.swift` | Userspace TCP-клиент |
| `UdpNat.swift` | UDP-флоу поверх туннеля |
| `DnsMessage.swift` / `TunnelResolver.swift` | DNS через туннель |
| `PacketPump.swift` | UDP-мост к ядру (`127.0.0.1:52230`) |
| `TunnelSocks5Server.swift` | Локальный SOCKS5 для incy |
| `Ipv4Routing.swift` | Правила «напрямую vs через туннель» |
| `IncyConfig.swift` | Deeplink-схема incy |
| `CallKeepAlive.swift` | Локальный «режим звонка» (тихий сгенерированный звук) |
| `LaLuneCoreBridge.h` | C API ядра (`csqtt_run`, `csqttr_run_extended`, ...) |
| `HttpServer.swift` | HTTP-сервер на Network.framework |
| `SceneDelegate.swift` | Окно + FlutterViewController, запуск Backend |
| `AppDelegate.swift` | Уведомления и background task |
| `CoreManager.swift` | Скачивание ядра и разбор логов |
| `VkWebViewController.swift` | WKWebView для OAuth ВК |

## Entitlements

Только App Group (общий каталог для настроек/логов):

```
<key>com.apple.security.application-groups</key>
<array><string>group.com.lalune</string></array>
```

Network Extension entitlement больше не нужен.

## Background modes

`fetch`, `processing`, `network-authentication` и `audio` (Info.plist).

## Ограничения

- Системный VPN поднимает только incy; если incy не установлен, LaLune
  покажет подсказку и предложит импортировать SOCKS5 вручную.
- Ядро iOS понимает только незашифрованные `csqtt://connect?...` ссылки.
- Замер задержки идёт TCP-рукопожатием до `1.1.1.1:443` через туннель.
