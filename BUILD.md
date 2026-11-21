# Сборка LaLune

Единый скрипт `build.py` в корне проекта собирает и упаковывает всё.

## Интерактивный режим

```
python build.py
```

Скрипт спросит, под какую платформу собирать:

```
============================================
   LaLune build
============================================

  Под какую платформу собрать?

    1) Windows
    2) Linux

  Выбор [1/2]:
```

## CI-режим

```
python build.py --ci --target windows
python build.py --ci --target linux
```

Без вопросов, сразу собирает указанную платформу.

## Что делает

1. **Собирает Backend** — `cargo build --release` в `Backend/Desktop/`
2. **Собирает Installer** (только Windows) — `cargo build --release` в `Installer/launcher/`
3. **Копирует `Assets/` → `Frontend/assets/`** — Flutter не умеет брать ассеты снаружи
4. **Собирает Frontend** — `flutter build windows --release` или `flutter build linux --release`
5. **Переименовывает бинарник** `lalune`/`lalune.exe` → `LaLune`/`LaLune.exe`
6. **Упаковывает в `Output/`**:

| Файл ↕▾ | Что внутри ↕▾ |
|---|---|
| −`LaLune-Windows.zip` | Весь `Frontend/build/windows/x64/runner/Release/` |
| −`Backend-Windows.zip` | Один файл `LaLuneManager.exe` (Rust-бэкенд) |
| −`Installer-Windows.zip` | Один файл `LaLune-Installer.exe` |
| −`LaLune-Linux.zip` | Весь `Frontend/build/linux/x64/release/bundle/` |
| −`Backend-Linux.zip` | Один файл `LaLuneManager` |
⚙

7. **Чистит**:

- `flutter clean` в `Frontend/`
- `cargo clean` в `Backend/Desktop/`
- `cargo clean` в `Installer/launcher/` (если собирали)
- удаляет временную `Frontend/assets/`

## Формат вывода

```
[RUNNING] cargo build --release (Backend/Desktop)
[OK] cargo build --release (Backend/Desktop)  (42.3s)
[INFO] backend binary: /path/Backend/Desktop/target/release/lalune-backend
[RUNNING] cargo build --release (Installer/launcher)
[OK] cargo build --release (Installer/launcher)  (18.7s)
[INFO] installer exe: /path/Installer/launcher/target/release/LaLune-Installer.exe
[RUNNING] flutter pub get
[OK] flutter pub get  (3.1s)
[RUNNING] flutter build windows --release
[OK] flutter build windows --release  (89.4s)

[INFO] packaging…
[INFO] packaging LaLune-Windows.zip…
[OK] LaLune-Windows.zip  (12345 KB)
[INFO] packaging Backend-Windows.zip…
[OK] Backend-Windows.zip  (2345 KB)
[INFO] packaging Installer-Windows.zip…
[OK] Installer-Windows.zip  (3456 KB)

[OK] build complete: /path/Output
[INFO]   LaLune-Windows.zip  (12345 KB)
[INFO]   Backend-Windows.zip  (2345 KB)
[INFO]   Installer-Windows.zip  (3456 KB)

[INFO] cleaning build artifacts…
[RUNNING] flutter clean (Frontend)
[OK] flutter clean (Frontend)  (2.5s)
[RUNNING] cargo clean (Backend/Desktop)
[OK] cargo clean (Backend/Desktop)  (0.3s)
[RUNNING] cargo clean (Installer/launcher)
[OK] cargo clean (Installer/launcher)  (0.2s)
[OK] removed Frontend/assets/ (temporary copy)

[OK] done.
```

## Флаги

| Флаг ↕▾ | Описание ↕▾ |
|---|---|
| −`--ci` | CI-режим, без вопросов |
| −`--target {windows,linux}` | Целевая платформа |
| −`--no-clean` | Не чистить build-артефакты после сборки |
⚙

## Требования

- **Python 3.8+**
- **Flutter** в `PATH`
- **Rust** (`cargo`) в `PATH`
- **Windows-таргет** — только на Windows-хосте (для сборки нативных exe)

## Использование в GitHub Actions

```
- name: Build Windows
  run: python build.py --ci --target windows

- name: Build Linux
  run: python build.py --ci --target linux

- name: Upload artifacts
  uses: actions/upload-artifact@v4
  with:
    name: LaLune-Windows
    path: Output/*.zip
```

## Подпись Android APK в GitHub Actions

Все публикуемые Android APK собираются как `release` и подписываются ключом `Assets/apk-key/my-release-key.jks` с alias `my-key`. Сам JKS не следует коммитить в репозиторий: CI использует его из этого пути, а если файла нет в checkout — восстанавливает из Base64 GitHub Actions secret.

В Settings → Secrets and variables → Actions добавьте secrets:

- `ANDROID_KEYSTORE_BASE64` — Base64-содержимое `my-release-key.jks` (можно оставить пустым только если JKS уже доступен в checkout);
- `ANDROID_KEYSTORE_PASSWORD` — пароль хранилища;
- `ANDROID_KEY_PASSWORD` — пароль ключа.

Alias зафиксирован как `my-key`. CI проверяет alias, собирает `flutter build apk --release` и запускает `apksigner verify`. Для PR из fork Android job пропускается, потому что GitHub не предоставляет таким workflow секреты репозитория.

## Публикация обновления после ручного релиза

При `workflow_dispatch` после создания GitHub Release и прикрепления macOS-сборки CI создаёт `Release.zip`. Внутри находятся ровно два архива: `Installer-Windows.zip` и `LaLune-Android.apk.zip` (внутри последнего — подписанный `LaLune-Android.apk`). Затем CI отправляет `Release.zip` и версию релиза на `http://82.40.38.237:8000/new_update` через multipart POST. Версия берётся из `stable_version` ручного запуска.
