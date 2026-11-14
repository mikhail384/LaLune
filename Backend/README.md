# Backend

Три независимые реализации HTTP-демона на `http://127.0.0.1:1062`.

| Платформа ↕▾ | Язык ↕▾ | Технологии ↕▾ | TUN ↕▾ |
|---|---|---|---|
| −Linux / Windows | Rust | axum + tokio + tun | `tun` crate |
| −Android | Kotlin | Ktor / NanoHTTPD + VpnService | VpnService |
| −iOS | Swift | Network.framework + NEPacketTunnelProvider | NEPacketTunnelProvider |
⚙

## Общий контракт

Единый REST + SSE API (см. [`API.md`](https://api.md/)). UI (Flutter) не знает, какой бэкенд работает — он просто дёргает `http://127.0.0.1:1062/...`.

## Общие файлы данных

Все бэкенды работают с одинаковыми файлами в `<appDir>`:

```
la-lune/
├── configs.db        # SQLite: конфиги
├── settings.json     # настройки
├── token.json        # VK-токен
├── LATEST            # версия ядра
├── logs.log          # логи
├── client-*          # бинарник ядра
└── vk-token-fetcher/ # Playwright + browsers (Desktop)
```

Пути `appDir`:

- **Linux:** `~/.la-lune`
- **Windows:** `%APPDATA%\.la-lune`
- **Android:** `filesDir/la-lune`
- **iOS:** `Documents/la-lune` + App Group `group.com.lalune`

## Запуск

### Desktop (Rust)

```
cd Desktop
cargo run --release
```

### Android (Kotlin)

```
Backend(this).run()   // запускает HTTP-сервер + VpnService
```

### iOS (Swift)

```
Backend.shared.run()  // запускает HTTP-сервер на 127.0.0.1:1062
```

## Статус реализации

- ✅ Desktop — полная реализация
- ✅ Android — полная реализация
- ✅ iOS — полная реализация
- ⏸ DeployManager — заглушка (методы возвращают `{stub: true}`)
## macOS (без проверки на реальном Mac)

* Бэкенд: `Backend/macos_tun.rs` — utun (крейт `tun`), маршруты `route` (две половины 0.0.0.0/1 и 128.0.0.0/1,
  сервер ядра и IP-исключения идут через физический шлюз), DNS через `networksetup` с откатом при отключении.
* Приложение: `Frontend/macos`; `AppDelegate.swift` при старте запускает `Contents/Resources/lalune-backend`
  через штатный диалог пароля администратора и шлёт `POST /shutdown` при выходе. Sandbox отключён.
* Тестовый workflow `codex-macos-build.yml` собирает универсальный бэкенд,
  DMG и нативные ядра CSQTT/CSQTTR для Apple Silicon; при отсутствии отдельного
  пользовательского ядра они используются из пакета. Intel использует x86-64 ядра.
* Облачный Mac проверил запуск приложения, обмен пакетом через utun с локальным
  эхо-ядром для CSQTT и CSQTTR, а также реальный CSQTTR с HTTPS 200, ростом
  счётчиков и восстановлением DNS. Реальный CSQTT и личный Mac не проверены.
* Сборка не нотаризована (ad-hoc подпись). Если ядро держит соединение с сервером только по неподключённому UDP, адрес сервера
  берётся из конфига (`peer`), поэтому для hostname нужен резолв до подключения.
