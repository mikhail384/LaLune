# OpenWrt в LaLune Frontend

Кнопка **«Подключить OpenWrt»** устанавливает backend и LuCI-панель по SSH
либо подключает Frontend к уже работающему backend.

## Установка по SSH

1. Frontend подключается к роутеру по SSH и определяет `DISTRIB_ARCH`.
2. Устанавливает `ip-full`, `kmod-tun`, `firewall4`, `nftables`,
   `kmod-nf-nat`, `kmod-nft-nat`, `rpcd`, `luci-light`, `luci-base`,
   `uhttpd`/`uhttpd-mod-ubus`/`uhttpd-mod-ucode`, `uclient-fetch` и `jsonfilter`.
3. До запуска VPN проверяет, что ядро реально принимает правило nftables
   `masquerade`. Если `kmod-nft-nat` не соответствует текущему ядру, установка
   завершается с понятной ошибкой вместо создания частично работающего TUN.
4. Устанавливает архитектурный `lalune-openwrt-backend[-<abi>]`.
5. Устанавливает `luci-app-lalune`: меню LuCI, ACL, rpcd API bridge и страницу
   управления. Архив панели передаётся из приложения, поэтому роутеру не нужно
   отдельно скачивать UI с GitHub.
6. Перезапускает backend и проверяет `http://<router>:1062/ping`.

После установки LuCI-панель находится в **Службы → LaLune VPN**. Она использует
локальный API `127.0.0.1:1062` через rpcd/ubus и даёт управление профилями,
Connect/Disconnect/Reconnect, статус, трафик и последние логи.

Standalone API и его маршруты не меняются: Android/Windows/macOS-клиент по-прежнему
может подключаться к `http://<router>:1062` и управлять тем же backend.

## Маршрутизация и NAT

OpenWrt backend сначала использует native nftables NAT. Это устраняет зависимость
от `iptables-nft`-совместимости `xt_MASQUERADE`, которая вызывала ошибку
`Extension MASQUERADE revision 0 not supported` и последующий `RULE_APPEND` для
`LALUNE_NAT`. Legacy iptables оставлен только как fallback для старых систем.

## Подключение из приложения

Frontend проверяет `/ping` и `/core/protocols`, затем переключает `ApiClient` на
API роутера. LuCI и мобильный/desktop-клиент используют один backend и общее
хранилище профилей.
