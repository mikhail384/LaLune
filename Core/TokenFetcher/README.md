# LaLune Token Fetcher (Go + playwright-go)

Консольная утилита, которая получает VK `access_token` через настоящий Chromium
(Playwright) и сохраняет его в `token.json` в формате, который читает Rust-бэкенд
(`Backend/Desktop/src/vk.rs`). Заменяет старый .NET Playwright-фетчер: логика
OAuth-цикла перенесена из него один в один, но теперь это один статический
бинарник без .NET-рантайма.

Библиотека: `github.com/mxschmitt/playwright-go` v0.6401.0 — это тот же
playwright-go (модуль намеренно объявляет старый путь; `playwright-community`
начиная с v0.6100.0 отдаёт ровно этот `module`). Более старые версии не умеют
скачивать драйвер: они берут его с `playwright.azureedge.net`, который отдаёт
404.

## Как он попадает к пользователю

Бинарник **встраивается внутрь desktop-бэкендов** для Linux и Windows:
`Backend/Desktop/build.rs` включает `has_embedded_token_fetcher`, если в
`Backend/Desktop/assets/` лежит нужный `.gz`, а `src/vk.rs` подхватывает его
через `include_bytes!`. При логине бэкенд распаковывает бинарник в
`<appDir>/token-fetcher/`, ставит права `0755` и запускает его отдельным
процессом; вывод пишется в `<appDir>/token-fetcher.log`. Отдельная поставка
фетчера не нужна.

Если ассетов нет (свежий checkout без `build.sh`), сборка всё равно проходит:
бэкенд откатывается на старые `Token.ps1`/`Token.sh` и печатает
`cargo:warning`.

## Сборка

Нужен Go 1.22+. Скрипт собирает оба бинарника и кладёт их gzip в
`Backend/Desktop/assets/`:

```bash
cd Core/TokenFetcher
./build.sh
```

Результат:

```
Backend/Desktop/assets/token-fetcher-linux-amd64.gz
Backend/Desktop/assets/token-fetcher-windows-amd64.exe.gz
```

Скрипт идемпотентен: пересобирает и перезаписывает оба артефакта, печатает
размеры, путь к корню репозитория вычисляет от собственного расположения.
Если `go` не в `PATH`, укажите `GO_BIN=/path/to/go ./build.sh`.

Бинарники статические (`CGO_ENABLED=0`, `-trimpath -ldflags "-s -w"`), поэтому
не требуют libc на целевой машине.

## Тесты

```bash
cd Core/TokenFetcher
go test ./...
```

Тесты покрывают только чистые функции: разбор фрагмента URL (access_token,
silent_token, error), определение blank-редиректа, разрешение путей для
Windows/Linux (значения окружения передаются явно), формат `token.json` и права
файла, разбор флагов. Сеть и браузер в тестах не используются.

## Запуск

```bash
./token-fetcher
```

Утилита открывает видимое окно Chromium, ведёт на страницу авторизации VK и ждёт,
пока пользователь войдёт. Профиль Chromium сохраняется на диск, поэтому при
повторных запусках VK сразу предлагает «Продолжить как ...» и токен получается без
пароля.

### Флаги

| Флаг | По умолчанию | Назначение |
| --- | --- | --- |
| `--token-path` | `<appDir>/token.json` | куда записать `token.json` |
| `--user-data-dir` | `<appDir>/vk-token-fetcher/userdata` | профиль Chromium (cookies, localStorage) |
| `--browsers-path` | `<appDir>/vk-token-fetcher/browsers` | каталог браузеров; выставляется в `PLAYWRIGHT_BROWSERS_PATH` до первого вызова Playwright |
| `--timeout` | `5m` | общий таймаут ожидания токена |
| `--headless` | `false` | запуск без окна (для входа нужен видимый браузер) |
| `-h`, `--help` | | справка |

`<appDir>` — `%APPDATA%\.la-lune` на Windows и `~/.la-lune` на Linux, то есть тот
же каталог, из которого Rust-бэкенд читает `token.json`.

### Коды возврата

| Код | Значение |
| --- | --- |
| 0 | токен получен и сохранён |
| 3 | токен не получен (тайм-аут, отказ VK, `silent_token` без `access_token`) |
| 4 | Chromium не удалось установить (в stderr есть маркер `LALUNE_CHROMIUM_MISSING`) |
| 1 | прочая ошибка |

Человекочитаемые сообщения печатаются в stdout с префиксом `[LaLune] `, ошибки — в
stderr.

## Как это работает

1. **Проверка браузера.** До запуска OAuth утилита проверяет
   `pw.Chromium.ExecutablePath()` и существование файла. Если Chromium нет, он
   скачивается автоматически через API playwright-go
   (`playwright.Install` с `Browsers: ["chromium"]`), без ручных вызовов `npm` и
   `node`. Если после установки файл всё ещё не найден — выход с кодом 4.
2. **Persistent context.** Chromium запускается с `--user-data-dir` (не инкогнито),
   `headless=false`, `--disable-blink-features=AutomationControlled`, locale
   `ru-RU`, timezone `Europe/Moscow`. Профиль переживает перезапуски.
3. **OAuth.** Открывается
   `https://oauth.vk.ru/authorize?client_id=7793118&scope=1073737727&redirect_uri=https%3A%2F%2Foauth.vk.ru%2Fblank.html&display=page&response_type=token&revoke=1&v=5.199`
   (client_id 7793118 — официальное приложение VK для Android, только оно разрешает
   implicit flow). URL страницы опрашивается каждые 3 секунды до дедлайна.
4. **Разбор редиректа.** Если URL — `oauth.vk.ru`/`oauth.vk.com` + `/blank.html`:
   - во фрагменте есть настоящий `access_token=` → токен сохраняется, код 0;
   - во фрагменте `payload=` с `type":"silent_token"` → утилита открывает
     `https://vk.com/`, ждёт 2 секунды и повторяет OAuth (не более одного
     перезапуска, итого два прохода). На втором проходе VK обычно показывает
     «Продолжить как <Имя>» и возвращает настоящий токен;
   - во фрагменте `error=` → код 3;
   - по таймауту → код 3.
5. **Сохранение.** `token.json` пишется атомарно (временный файл + rename) в
   каталог `--token-path`, каталог создаётся при необходимости, на Linux права
   `0600`. Формат: `{"Token": "...", "SavedAt": "<RFC3339 UTC>"}` — ключ `Token` с
   большой буквы, как ждёт Rust; на чтение Rust также принимает `token`.

## Что качается при первом запуске

Утилита не содержит ни Node, ни браузера. При первом запуске playwright-go
скачивает драйвер (Playwright + Node, ~135 МБ в распакованном виде) в кэш
пользователя (`%USERPROFILE%\AppData\Local\ms-playwright-go\...` на Windows,
`~/.cache/ms-playwright-go/...` на Linux; можно переопределить переменной
`PLAYWRIGHT_DRIVER_PATH`) и Chromium в `--browsers-path` (по умолчанию
`<appDir>/vk-token-fetcher/browsers`, ~680 МБ: Chromium, headless shell и FFmpeg).
Для этого нужен интернет; при повторных запусках загрузки уже нет.

Если каталог с драйвером или браузером повреждён/удалён, утилита сообщит об этом
и попробует установить их заново. Антивирус на Windows может проверять
скачанный Chromium при первом старте — это нормально, но может замедлить запуск.

## Зависимость

Единственная сторонняя зависимость — playwright-go. В `go.mod` указан её текущий
канонический путь `github.com/mxschmitt/playwright-go` (v0.6401.0): репозиторий
переименован в `playwright-community`, но сам модуль объявляет путь `mxschmitt`,
а последняя версия под старым путём `github.com/playwright-community/playwright-go`
(v0.6000.0) скачивает драйвер с отключённого CDN `playwright.azureedge.net` и на
чистой машине установить браузер не может. Начиная с v0.6100.0 драйвер ставится
из npm-реестра, и автоустановка работает.
