# openwrt.sh — установщик LaLune для OpenWRT

Установщик определяет архитектуру пакетов роутера (`DISTRIB_ARCH` из
`/etc/openwrt_release`) и скачивает один backend-бинарник под неё:

| `DISTRIB_ARCH` | Сборка | Примеры |
|---|---|---|
| `aarch64_*` | `lalune-openwrt-backend` | Cudy, Xiaomi AX, Raspberry Pi |
| `x86_64` | `-x86_64` | мини-ПК, виртуальные машины |
| `i386_pentium4` | `-i386` | x86 с SSE2 |
| `mipsel_*` (кроме `mipsel_mips32`) | `-ramips` | mt7621, mt76x8, mt7620, Keenetic KN-1211 |
| `mips_*` (кроме `mips_mips32`) | `-mips` | ath79, lantiq, realtek |
| `arm_cortex-a5/a7/a8/a9/a15/a53*` | `-armv7` | ipq40xx, mvebu, bcm27xx |
| прочие `arm_*` | `-armv5` | arm926ej-s, xscale, arm1176 |

Не поддерживаются: PowerPC, MIPS64, LoongArch, RISC-V (backend не прошёл проверку
в эмуляторе), mips32r1 (Broadcom bmips) и
`i386_pentium-mmx` (нет SSE2).
В полной сборке встроены **CSQTT**, **CSQTTR** и **CSQTT 2.1.9**. Для роутеров
с малой памятью установщик использует лёгкую сборку и загружает выбранное ядро
по мере подключения, сохраняя на роутере только одно дополнительное ядро.
В лёгкой сборке CSQTTR кладёт приложение при установке; для первого запуска
CSQTT или CSQTT 2.1.9 роутеру нужен доступ к GitHub или его прокси. При смене
протокола загружается только выбранное ядро.

Keenetic KN-1211 использует `mipsel_24kc` (MT7628NN, 64 МБ RAM, 32 МБ flash).
При старом OpenWrt с firewall3 установщик оставляет iptables; на OpenWrt 22.03+
он использует firewall4/nftables. На старой прошивке установщик не ставит LuCI-
панель LaLune, но мобильное приложение подключается к API роутера напрямую.

## Установка

```sh
wget -O - https://raw.githubusercontent.com/mikhail384/LaLune/main/Installer/openwrt.sh | sh
```

или:

```sh
curl -fsSL https://raw.githubusercontent.com/mikhail384/LaLune/main/Installer/openwrt.sh | sh
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
- проверяет/ставит `ip-full`, `kmod-tun` и `nohup`; для firewall4 использует nftables,
  а для старого firewall3 — iptables и проверяет поддержку MASQUERADE;
- скачивает backend и делает его executable;
- останавливает предыдущий процесс, запускает новый через `nohup`;
- пишет PID в `~/.la-lune/backend.pid`, лог — в
  `~/.la-lune/LaLuneManager.log`.

В полной сборке отдельные core-файлы не скачиваются. В лёгкой сборке ядро
загружается при первом подключении; при смене протокола предыдущее отдельное
ядро удаляется, чтобы освободить место на flash.

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
