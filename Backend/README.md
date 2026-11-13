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
* CI: job `build-desktop-macos` (continue-on-error) собирает универсальный бэкенд (x86_64 + arm64) и `LaLune-macOS.zip`.
* Ядро CSQTT/CSQTTR на macOS — сборка `client-macos-x86_64` (на Apple Silicon работает через Rosetta 2).
* Ограничения: на реальном Mac код не запускался. Сборка не нотаризована (ad-hoc подпись): первый запуск —
  правой кнопкой «Открыть». Если ядро держит соединение с сервером только по неподключённому UDP, адрес сервера
  берётся из конфига (`peer`), поэтому для hostname нужен резолв до подключения.