#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# openwrt.sh — установщик LaLune для OpenWRT (aarch64, x86_64, i386, mips/mipsel, arm).
# Оба backend-бинарника уже содержат CSQTT, CSQTTR и CSQTT 2.1.9.

set -e

BACKEND_BASE="https://github.com/mikhail384/LaLune/releases/latest/download"
BACKEND_URL=""
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

install_package() {
    pkg="$1"
    if have apk; then
        apk add "$pkg"
    elif have opkg; then
        opkg update >/dev/null 2>&1 || true
        opkg install "$pkg"
    else
        return 1
    fi
}

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

# Runtime requirements are now identical on ARM64 and ramips: the backend
# creates lalune0 and routes router/LAN traffic with iptables fwmark rules.
if ! ip -N -4 rule show >/dev/null 2>&1; then
    install_package ip-full || true
fi
ip -N -4 rule show >/dev/null 2>&1 || fail "установите ip-full для policy routing"

if [ ! -c /dev/net/tun ]; then
    install_package kmod-tun || true
    have modprobe && modprobe tun || true
fi
[ -c /dev/net/tun ] || fail "установите kmod-tun для TUN"

if ! have iptables && ! have iptables-nft; then
    install_package iptables-nft || install_package iptables || true
fi
(have iptables || have iptables-nft) || fail "установите iptables-nft (нужны mangle/MARK и nat/MASQUERADE)"

# NAT для клиентов LAN: на сборках без xt_MASQUERADE iptables пишет
# "Extension MASQUERADE revision 0 not supported". Модули ядра ставим
# по возможности (версия kmod должна совпадать с ядром), ошибки не фатальны.
for pkg in kmod-ipt-nat kmod-nft-nat kmod-nft-compat iptables-mod-nat-extra iptables-mod-extra kmod-ipt-extra; do
    install_package "$pkg" >/dev/null 2>&1 || true
done

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
    log "  api: http://0.0.0.0:1062/ping"
    log "  cores: CSQTT / CSQTTR / CSQTT 2.1.9 встроены в backend"
else
    warn "backend не запустился, смотри $BACKEND_LOG"
    rm -f "$BACKEND_PID"
    tail -n 30 "$BACKEND_LOG" 2>/dev/null || true
    exit 1
fi
