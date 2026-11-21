#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# openwrt.sh — установщик LaLune для OpenWRT (aarch64, x86_64, i386, mips/mipsel, arm).
# Оба backend-бинарника уже содержат CSQTT, CSQTTR и CSQTT 2.1.9.

set -e

BACKEND_BASE="https://github.com/Endlad2/LaLune/releases/latest/download"
BACKEND_URL=""
LUCI_APP_URL="$BACKEND_BASE/luci-app-lalune.tar.gz"
LUCI_APP_ARCHIVE="/tmp/luci-app-lalune.tar.gz"
BACKEND_NAME="lalune-openwrt-backend"

APP_DIR="${HOME}/.la-lune"
BACKEND_PATH="${APP_DIR}/${BACKEND_NAME}"
BACKEND_PID="${APP_DIR}/backend.pid"
BACKEND_LOG="${APP_DIR}/LaLuneManager.log"

FORCE=0
MODE="install"
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --stop)     MODE="stop" ;;
        --status)   MODE="status" ;;
        -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    esac
done

log()  { printf "[openwrt] %s\n" "$*"; }
warn() { printf "[openwrt][WARN] %s\n" "$*" >&2; }
fail() { printf "[openwrt][ERROR] %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

PKG_UPDATED=0
install_packages() {
    if have apk; then
        apk add "$@"
    elif have opkg; then
        if [ "$PKG_UPDATED" -eq 0 ]; then
            opkg update >/dev/null 2>&1 || true
            PKG_UPDATED=1
        fi
        opkg install "$@"
    else
        return 1
    fi
}

install_package() { install_packages "$1"; }

download() {
    url="$1"; dest="$2"; tmp="${dest}.part"
    rm -f "$tmp"
    log "download: $url"
    if ! (
        if have curl; then
            curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 300 -o "$tmp" "$url"
        elif have wget; then
            wget -O "$tmp" "$url"
        elif have uclient-fetch; then
            uclient-fetch -O "$tmp" "$url"
        else
            fail "нужен curl, wget или uclient-fetch"
        fi
    ) || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        fail "не удалось скачать $url"
    fi
    mv -f "$tmp" "$dest"
}

read_pid() {
    [ -f "$BACKEND_PID" ] || return 1
    pid=$(cat "$BACKEND_PID" 2>/dev/null | tr -d ' \n\r')
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

stop_backend() {
    pid=$(read_pid 2>/dev/null || true)
    if [ -n "$pid" ]; then
        log "останавливаю backend (PID=$pid)"
        kill "$pid" 2>/dev/null || true
        i=0
        while [ $i -lt 6 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.5; i=$((i+1)); done
        kill -0 "$pid" 2>/dev/null && { warn "SIGKILL"; kill -9 "$pid" 2>/dev/null || true; }
    fi
    rm -f "$BACKEND_PID"
}

case "$MODE" in
    stop) stop_backend; log "stopped."; exit 0 ;;
    status)
        pid=$(read_pid 2>/dev/null || true)
        if [ -n "$pid" ]; then
            echo "LaLune OpenWRT backend: running (PID=$pid)"
        else
            echo "LaLune OpenWRT backend: not running"
        fi
        exit 0 ;;
esac

# Выбор сборки backend по архитектуре пакетов OpenWrt (DISTRIB_ARCH).
# Статический musl-бинарник один на архитектуру (не на SoC): mt7621, mt76x8,
# ath79 и т.д. используют одну и ту же сборку. Функция проверяется в CI.
lalune_abi() {
    case "${1:-}" in
        aarch64_*) echo aarch64 ;;
        x86_64) echo x86_64 ;;
        # i386 build needs SSE2 (pentium4 class); pentium-mmx is not supported.
        i386_pentium-mmx) return 1 ;;
        i386_*) echo i386 ;;
        # mips32r1 (Broadcom bmips) не поддерживается: сборки под mips32r2.
        mipsel_mips32|mips_mips32) return 1 ;;
        mipsel_*) echo ramips ;;
        mips_*) echo mips ;;
        arm_cortex-a5*|arm_cortex-a7*|arm_cortex-a8*|arm_cortex-a9*|arm_cortex-a15*|arm_cortex-a17*|arm_cortex-a53*|arm_cortex-a72*|arm_neoverse*) echo armv7 ;;
        arm_*) echo armv5 ;;
        *) return 1 ;;
    esac
}

unset DISTRIB_TARGET DISTRIB_ARCH
[ -r /etc/openwrt_release ] && . /etc/openwrt_release
arch="$(uname -m 2>/dev/null || true)"
abi=""
[ -n "${DISTRIB_ARCH:-}" ] && abi="$(lalune_abi "$DISTRIB_ARCH" || true)"
if [ -z "$abi" ]; then
    # Нет /etc/openwrt_release: определяем по uname (mips по uname не различить).
    case "$arch" in
        aarch64|arm64) abi=aarch64 ;;
        x86_64) abi=x86_64 ;;
        i386|i486|i586|i686) abi=i386 ;;
        armv7*|armv8l) abi=armv7 ;;
        armv5*|armv6*) abi=armv5 ;;
    esac
fi
[ -n "$abi" ] || fail "Неподдерживаемая архитектура: uname=$arch, OpenWrt=${DISTRIB_TARGET:-?} (${DISTRIB_ARCH:-?}). Поддерживаются: aarch64, x86_64, i386 (SSE2), mips/mipsel, arm."
case "$abi" in
    aarch64) BACKEND_URL="$BACKEND_BASE/lalune-openwrt-backend" ;;
    *) BACKEND_URL="$BACKEND_BASE/lalune-openwrt-backend-$abi" ;;
esac
log "router: ${DISTRIB_TARGET:-?} (${DISTRIB_ARCH:-$arch}) -> build $abi"

log "app dir: $APP_DIR"
mkdir -p "$APP_DIR"

# Runtime requirements: the backend creates lalune0 and installs policy routing
# plus native nftables NAT for router/LAN traffic.
if ! ip -N -4 rule show >/dev/null 2>&1; then
    install_package ip-full || true
fi
ip -N -4 rule show >/dev/null 2>&1 || fail "установите ip-full для policy routing"

if [ ! -c /dev/net/tun ]; then
    install_package kmod-tun || true
    have modprobe && modprobe tun || true
fi
[ -c /dev/net/tun ] || fail "установите kmod-tun для TUN"

# OpenWrt 22.03+ is firewall4/nftables. Install the native nft CLI and the
# kernel NAT modules instead of relying on the incomplete iptables-nft
# MASQUERADE compatibility extension (the source of LALUNE_NAT RULE_APPEND).
install_packages firewall4 nftables kmod-nf-nat kmod-nft-nat rpcd luci-light luci-base uhttpd uhttpd-mod-ubus uhttpd-mod-ucode uclient-fetch jsonfilter \
    || fail "не удалось установить nftables/NAT/LuCI зависимости; проверьте feeds и совпадение kmod с ядром"
/etc/init.d/firewall enable >/dev/null 2>&1 || true
/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || true
have nft || fail "пакет nftables установлен, но команда nft не найдена"
nft list tables >/dev/null 2>&1 || fail "nft не может обращаться к netfilter; проверьте kmod-nft-core/kmod-nft-nat"

# Probe the actual kernel masquerade target before starting the VPN.
nft delete table ip lalune_probe >/dev/null 2>&1 || true
if ! nft -f - <<'NFT'
table ip lalune_probe {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "lo" masquerade
    }
}
NFT
then
    nft delete table ip lalune_probe >/dev/null 2>&1 || true
    fail "ядро не поддерживает nft masquerade; установите kmod-nf-nat и kmod-nft-nat именно для текущего kernel"
fi
nft delete table ip lalune_probe >/dev/null 2>&1 || true

install_luci_panel() {
    log "installing LuCI panel and authenticated rpcd API bridge"
    if [ ! -s "$LUCI_APP_ARCHIVE" ]; then
        download "$LUCI_APP_URL" "$LUCI_APP_ARCHIVE"
    fi
    tar -tzf "$LUCI_APP_ARCHIVE" >/dev/null 2>&1 || fail "архив luci-app-lalune повреждён"
    tar -xzf "$LUCI_APP_ARCHIVE" -C /
    chmod 755 /usr/libexec/rpcd/lalune
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
    /etc/init.d/uhttpd enable >/dev/null 2>&1 || true
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
    log "LuCI panel installed: Services -> LaLune VPN"
}
install_luci_panel

if ! have nohup; then
    install_package coreutils-nohup || true
fi
have nohup || fail "установите coreutils-nohup"

if [ -s "$BACKEND_PATH" ] && [ "$FORCE" -eq 0 ]; then
    log "backend уже есть: $BACKEND_PATH"
else
    download "$BACKEND_URL" "$BACKEND_PATH"
    chmod +x "$BACKEND_PATH"
    log "backend установлен: $BACKEND_PATH"
fi

stop_backend

log "запускаю backend..."
cd "$APP_DIR"
if have setsid; then
    setsid nohup "$BACKEND_PATH" >>"$BACKEND_LOG" 2>&1 &
else
    nohup "$BACKEND_PATH" >>"$BACKEND_LOG" 2>&1 &
fi
new_pid=$!
echo "$new_pid" > "$BACKEND_PID"
sleep 1

if kill -0 "$new_pid" 2>/dev/null; then
    log "backend запущен (PID=$new_pid)"
    rm -f "$LUCI_APP_ARCHIVE"
    log "  api: http://0.0.0.0:1062/ping"
    log "  cores: CSQTT / CSQTTR / CSQTT 2.1.9 встроены в backend"
else
    warn "backend не запустился, смотри $BACKEND_LOG"
    rm -f "$BACKEND_PID"
    tail -n 30 "$BACKEND_LOG" 2>/dev/null || true
    exit 1
fi
