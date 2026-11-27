# GitHub Actions — LaLune

## Workflow'ы

| Файл ↕▾ | Что делает ↕▾ |
|---|---|
| `build.yml` | Desktop (Windows + Linux + macOS), OpenWRT, Android APK, Token Fetcher, Release |
| `build-ios.yml` | iOS IPA (unsigned, для AltStore/Scarlet) |
| `deploy-site.yml` | Flutter Web → GitHub Pages |

## Триггеры

Сборочные workflow запускаются:

- при `push` в `main` / `release` (`build-ios` — ещё `master`)
- вручную через **Actions → Run workflow**
- `build-ios` дополнительно на теги `v*` (для аттача IPA к релизу)

## Как работает `build.yml`

### `build-desktop-linux`

```
ubuntu-22.04
├── python 3.12
├── rust stable
├── flutter 3.47.5
├── apt install gtk3-dev, clang, cmake, ninja, pkg-config
└── python build.py --ci --target linux
     ├── cargo build --release (Backend/Desktop)
     ├── flutter pub get
     ├── flutter build linux --release
     ├── rename lalune → LaLune
     ├── package LaLune-Linux.zip
     ├── package Backend-Linux.zip
     └── clean
```

Артефакт: `Output-Linux` (содержит `LaLune-Linux.zip`, `Backend-Linux.zip`).

### `build-desktop-windows`

```
windows-latest
├── python 3.12
├── rust stable
├── flutter 3.47.5
└── python build.py --ci --target windows
     ├── cargo build --release (Backend/Desktop)
     ├── cargo build --release (Installer/launcher)
     ├── flutter pub get
     ├── flutter build windows --release
     ├── rename lalune.exe → LaLune.exe
     ├── package LaLune-Windows.zip
     ├── package Backend-Windows.zip
     ├── package Installer-Windows.zip
     └── clean
```

Артефакт: `Output-Windows` (содержит 3 zip).

### `build-android`

```
ubuntu-latest
├── python 3.12
├── flutter 3.47.5
├── java 17
├── Android SDK + NDK 27
├── restore Assets/apk-key/my-release-key.jks ONLY from ANDROID_KEYSTORE_BASE64 secret
├── validate keystore password + alias my-key
├── write temporary Frontend/android/key.properties from password secrets
├── build native Android dependencies for supported ABIs
├── flutter pub get
├── flutter build apk --release
├── verify APK signature with apksigner
└── cp signed app-release.apk → Output/LaLune-Android.apk
```

Артефакт: `Output-Android` (`LaLune-Android.apk`), release-подпись обязательна.

Для сборки нужны GitHub Actions Secrets:

- `ANDROID_KEYSTORE_BASE64` — Base64 содержимое `my-release-key.jks`.
- `ANDROID_KEYSTORE_PASSWORD` — пароль keystore.
- `ANDROID_KEY_PASSWORD` — пароль приватного ключа.

CI удаляет любой JKS, пришедший из checkout, и восстанавливает keystore только из `ANDROID_KEYSTORE_BASE64`. Если секрет отсутствует или невалиден, job завершается ошибкой. После сборки временный JKS и `key.properties` удаляются.

### `build-token-fetcher`

**Без изменений** — matrix Windows + Linux, `dotnet publish` через
`build_token_grabber.py` → `Core/TokenFetcher/build.sh` (Go). Бинарники
упаковываются в gzip в `Backend/Desktop/assets/` и встраиваются в desktop-бэкенды,
а для обратной совместимости публикуются и `LaLuneTokenFetcher_<OS>.zip`.

### `create-release`

Запускается после всех. Собирает все zip'ы + APK в `release/` и создаёт
GitHub Release с тегом вида `26.10.03.15.30`.

Файлы в релизе:

- `LaLune-Windows.zip`
- `Backend-Windows.zip`
- `Installer-Windows.zip`
- `LaLune-Linux.zip`
- `Backend-Linux.zip`
- `LaLune-Android.apk`
- `LaLuneTokenFetcher_Windows.zip`
- `LaLuneTokenFetcher_Linux.zip`

## Как работает `build-ios.yml`

```
macos-14
├── Xcode 15.4
├── flutter 3.29.0
├── xcodegen
├── sh Frontend/ios/sync-backend.sh → Runner/ (без Tunnel/)
├── copy Assets/ → Frontend/assets/
├── flutter pub get
├── download libcsqtt_ios_core.a → Frontend/ios/Core/
├── xcodegen generate (Runner.xcodeproj)
├── patch objectVersion 77 → 56
├── xcodebuild archive (unsigned)
└── package Payload/ → LaLune.ipa
```

Артефакт: `LaLune-iOS-unsigned` (`LaLune.ipa`).

**Что нужно от тебя:**

- `Frontend/ios/project.yml` — конфиг XcodeGen с двумя target'ами:
`Runner` (основное приложение) + `Tunnel` (Network Extension).
- `Frontend/ios/Entitlements/Runner.entitlements` — App Groups + Network Extension.
- `Frontend/ios/Entitlements/Tunnel.entitlements` — packet-tunnel-provider.

Как только будут — workflow соберётся. Структура каталогов должна быть:

```
Frontend/ios/
├── project.yml
├── Entitlements/
│   ├── Runner.entitlements
│   └── Tunnel.entitlements
├── Runner/
│   ├── AppDelegate.swift        ← наш
│   ├── SceneDelegate.swift      ← копируется workflow'ом
│   ├── Backend.swift            ← копируется workflow'ом
│   ├── TunnelSession.swift      ← копируется workflow'ом
│   ├── TcpStack.swift / UdpNat.swift / PacketPump.swift
│   ├── TunnelSocks5Server.swift / IncyConfig.swift
│   ├── Info.plist               ← наш
│   └── Assets.xcassets/
└── Core/
    ├── libcsqtt_ios_core.a      ← скачивается workflow'ом
    └── libcsqttr_ios_core.a
```

Расширения `Tunnel/` больше нет: системный VPN поднимает incy, LaLune
запускает ядро в процессе приложения и отдаёт наружу локальный SOCKS5.

## Локальная проверка

Если хочешь понять, что workflow делает, просто прогони то же самое локально:

**Windows:**

```
python build.py --ci --target windows
```

**Linux:**

```
python build.py --ci --target linux
```

Оба требуют Flutter, Rust и Python в PATH.

## Отладка

Если job падает:

1. **Desktop** — проверь `flutter doctor -v` и `cargo --version` в логах. Часто Flutter не находит VS на Windows — тогда в `build.py` увидишь `[FAIL] flutter build windows`.
2. **Android** — проверь, что `Backend/Android/*.kt` скопировались в нужный package (`com.lalune.backend`). Если gradle не видит — смотри `app/build.gradle`, нужно `sourceSets` включать `.kt` из этого пакета.
3. **Token Fetcher** — оставлен без изменений, работает как раньше.
4. **iOS** — самый хрупкий. Порядок: Xcode → xcodegen → patch objectVersion → archive. Если `xcodegen generate` падает — проверь `project.yml`.