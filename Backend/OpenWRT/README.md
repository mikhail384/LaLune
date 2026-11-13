# LaLune Backend — OpenWRT

Backend для OpenWrt: aarch64, `ramips` (`mipsel_24kc`), а также x86_64, i386,
armv7, armv5 и mips (big-endian) (см. `build-multiarch.sh` ниже; riscv64 в
скрипте есть, но в релиз не входит: backend не прошёл проверку в qemu).
Все release-сборки содержат внутри backend одинаковый набор из трёх ядер:
**CSQTT**, **CSQTTR** и **CSQTT 2.1.9**. Отдельно скачивать core на роутер не нужно.

## Сборка

ARM64:

```sh
cd Backend/OpenWRT
./build.sh
```

`build.sh` скачивает официальный OpenWrt SDK 25.12.5 для `armsr/armv8`,
проверяет SHA256, собирает из зафиксированных исходников `csqtt-core`,
`csqttr-core` и legacy CSQTT 2.1.9, упаковывает их в `openwrt-cores.zip`,
передаёт ZIP в `build.rs` и собирает backend под
`aarch64-unknown-linux-musl`.

Результаты:

- `output/lalune-openwrt-backend` — ARM64 backend со встроенным ZIP ядер;
- `output/lalune-openwrt-cores-aarch64.zip` — копия ZIP для проверки CI.

ramips/mt7621:

```sh
cd Backend/OpenWRT
./build-ramips.sh
```

Скрипт делает то же самое для `mipsel-unknown-linux-musl` и создаёт:

- `output/lalune-openwrt-backend-ramips`;
- `output/lalune-openwrt-cores-ramips.zip`.

x86_64, i386, armv7, armv5, mips (и экспериментально riscv64):

```sh
cd Backend/OpenWRT
./build-multiarch.sh <abi>      # нужны curl, xz, zip, unzip, python3, rustup, qemu-user
```

Статический musl-бинарник собирается Rust + `zig cc` (закреплённая версия zig,
SHA256 проверяется), три ядра берутся из тех же закреплённых ревизий. Скрипт
проверяет ELF (класс, порядок байт, машина, без INTERP/NEEDED), запускает ядра и
backend (нативно или в `qemu-user`) и проверяет `/ping` и `/core/protocols`.
Результат: `output/lalune-openwrt-backend-<abi>` и
`output/lalune-openwrt-cores-<abi>.zip`. В CI это матрица
`build-openwrt-multiarch`.

При подключении backend извлекает во временный файл только выбранное ядро.
`GET /core/protocols` сообщает все три протокола как доступные в обеих
OpenWRT release-сборках. PaperFlux в OpenWRT-сборку не входит.

## TUN и маршрутизация

OpenWRT backend должен запускаться от root. При VPN он создаёт отдельный TUN
`lalune0`. Системный default route напрямую не заменяется: backend создаёт
policy table `10620`, помечает основной IPv4-трафик через `iptables`/`MARK`
(`0x1062/0xffff`) в `OUTPUT` и `PREROUTING` и направляет помеченные пакеты в
`lalune0`. Для TUN применяется `MASQUERADE`.

Процесс выбранного CSQTT-core запускается под отдельным UID. Для этого UID
ставится более приоритетное `ip rule ... lookup main`, поэтому транспорт самого
core не зацикливается обратно в VPN. Локальные/private/multicast IPv4-сети не
маркируются. Входящий WAN-трафик также не перенаправляется в TUN.

На firewall4 backend временно добавляет accept-правила в `inet fw4/forward` для
`lalune0`/VPN mark и удаляет их при disconnect. Для старого firewall3 остаются
совместимые `iptables FORWARD` rules.

Требования runtime: `/dev/net/tun`, `ip-full`, `iptables`/`iptables-nft` и
`nohup`. Установщики пытаются поставить недостающие пакеты автоматически.

## Установка

```sh
wget -O - https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

Установщик сам выбирает ARM64 или ramips backend и сохраняет его как
`~/.la-lune/lalune-openwrt-backend`. Три core уже находятся внутри бинарника.
Backend слушает `0.0.0.0:1062`; не публикуйте этот порт в WAN.

Проверка:

```sh
curl http://127.0.0.1:1062/ping
curl http://127.0.0.1:1062/core/protocols
```

Панель: `http://<IP роутера>:1062/panel`.

## Данные

Backend использует `~/.la-lune/` для `configs.db`, `settings.json`, `token.json`,
логов и PID-файла установщика. Встроенные core извлекаются только на время
запуска и не требуют постоянного файла `csqtt-client-aarch64`.
