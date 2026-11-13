# OpenWRT в LaLune Frontend

Кнопка **«Подключить OpenWRT»** предлагает установку по SSH или подключение к
уже работающему backend.

## Установка по SSH

1. Frontend находит роутер по SSH или принимает IP вручную.
2. Определяет архитектуру по `DISTRIB_ARCH` (aarch64, x86_64, i386, mips,
   mipsel, arm); неподдерживаемая — понятная ошибка со списком.
3. При необходимости устанавливает `ip-full`, `kmod-tun`,
   `iptables-nft`/`iptables`, `coreutils-nohup`, downloader и CA certificates.
4. Скачивает только соответствующий `lalune-openwrt-backend[-<abi>]`.
5. Отдельный core больше не скачивается: все backend содержат
   **CSQTT**, **CSQTTR** и **CSQTT 2.1.9** внутри бинарника.
6. Перезапускает backend и проверяет `http://<router>:1062/ping`.

После установки панель доступна по `http://<router>:1062/panel`.

## Подключение

Frontend проверяет `/ping` и `/core/protocols`, передаёт токен через
`/vk/token/submit` best-effort и переключает `ApiClient` на API роутера.
Release-сборки OpenWRT должны возвращать поддержку всех трёх встроенных
протоколов; отдельный файл `csqtt-client-aarch64` больше не требуется.

Основная логика SSH находится в `lib/state/openwrt_installer.dart`, переключение
API — в `lib/state/router_notifier.dart` и `lib/api/api_client.dart`.
