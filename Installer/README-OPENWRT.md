# openwrt.sh — установщик LaLune для OpenWRT

Установщик определяет архитектуру пакетов роутера (`DISTRIB_ARCH` из
`/etc/openwrt_release`) и скачивает один backend-бинарник под неё:

| `DISTRIB_ARCH` | Сборка | Примеры |
|---|---|---|
| `aarch64_*` | `lalune-openwrt-backend` | Cudy, Xiaomi AX, Raspberry Pi |
| `x86_64` | `-x86_64` | мини-ПК, виртуальные машины |
| `i386_pentium4` | `-i386` | x86 с SSE2 |
| `mipsel_*` (кроме `mipsel_mips32`) | `-ramips` | mt7621, mt76x8, mt7620 |
| `mips_*` (кроме `mips_mips32`) | `-mips` | ath79, lantiq, realtek |
| `arm_cortex-a5/a7/a8/a9/a15/a53*` | `-armv7` | ipq40xx, mvebu, bcm27xx |
| прочие `arm_*` | `-armv5` | arm926ej-s, xscale, arm1176 |

Не поддерживаются: PowerPC, MIPS64, LoongArch, RISC-V (backend не прошёл проверку
в эмуляторе), mips32r1 (Broadcom bmips) и
`i386_pentium-mmx` (нет SSE2).
Внутри всех backend уже встроены **CSQTT**, **CSQTTR** и **CSQTT 2.1.9**.

## Установка

```sh
wget -O - https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

или:

```sh
curl -fsSL https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

Флаги:

```sh
sh openwrt.sh --force
sh openwrt.sh --stop
sh openwrt.sh --status
```

## Что делает

- создаёт `~/.la-lune/`;
- выбирает `lalune-openwrt-backend[-<abi>]` по `DISTRIB_ARCH` (таблица выше);
- проверяет/ставит `ip-full`, `kmod-tun`, `iptables-nft`/`iptables` и `nohup`;
- скачивает backend и делает его executable;
- останавливает предыдущий процесс, запускает новый через `nohup`;
- пишет PID в `~/.la-lune/backend.pid`, лог — в
  `~/.la-lune/LaLuneManager.log`.

Отдельные core-файлы не скачиваются.

## VPN routing

При подключении backend создаёт `lalune0`, маркирует основной IPv4-трафик
через iptables и policy-routes его в отдельную таблицу через TUN. Транспорт
самого core исключается по отдельному UID, чтобы не возникала рекурсия VPN.

## Проверка

```sh
curl http://127.0.0.1:1062/ping
curl http://127.0.0.1:1062/core/protocols
ip link show lalune0            # когда VPN подключён
ip -4 rule show                 # policy rules LaLune
iptables -t mangle -S           # MARK rules LaLune
```

Панель доступна в доверенной LAN по `http://<IP роутера>:1062/panel`.
