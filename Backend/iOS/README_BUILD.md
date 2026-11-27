# Сборка iOS backend

## Требования

- Xcode 15+, iOS 17.0+
- App Group `group.com.lalune`
- Статические библиотеки ядра: `libcsqtt_ios_core.a`, `libcsqttr_ios_core.a`
  (кладутся в `Frontend/ios/Core/` шагом CI)

Network Extension entitlement и таргет-расширение **не нужны**: системный VPN
поднимает приложение incy, LaLune работает как локальный SOCKS5-прокси.

## Интеграция

1. Скопировать все `Backend/iOS/*.swift` и `LaLuneCoreBridge.h` в target
   `Runner` (это делает шаг «Copy iOS backend sources» в `build-ios.yml`).
2. `Runner-Bridging-Header.h` должен импортировать `LaLuneCoreBridge.h` —
   иначе Swift не увидит `csqtt_run`/`csqttr_run_extended`.
3. `Backend.shared.attach(window:)` и `Backend.shared.run()` вызывать из
   `SceneDelegate`, после `makeKeyAndVisible()`.
4. Линковать `-lcsqtt_ios_core -lcsqttr_ios_core` и `AVFoundation`.

## Entitlements (Runner)

```
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.lalune</string>
</array>
```

## Info.plist (Runner)

- `UIBackgroundModes`: `fetch`, `processing`, `network-authentication`, `audio`
- `NSMicrophoneUsageDescription` — «режим звонка» (запись не сохраняется)
- `LSApplicationQueriesSchemes`: `incy`, `vk`, `tg` — иначе `canOpenURL`
  для deeplink в incy всегда возвращает `false`
- `NSLocalNetworkUsageDescription` — локальный API на 127.0.0.1:1062

## Проверка перед сборкой

```
# чистая компиляция всех файлов без iOS SDK (только парсинг/типы Foundation-части)
Backend/iOS/Tests/run-tests.sh
```

Скрипты тестов используют Swift из репозитория (`.swift-tools/`) и пишут кеш
внутрь репозитория, потому что системный кеш может быть read-only.
