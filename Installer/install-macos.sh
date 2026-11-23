#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# One-command macOS installer. Downloads every required artifact first,
# then mounts the DMG and installs the app into /Applications.

set -euo pipefail

REPO_LALUNE="Endlad2/LaLune"
REPO_CSQTT="Endlad2/csqtt-core"
REPO_CSQTTR="Endlad2/csqttr-core"
REPO_TOTS="Endlad2/ToTS"

CSQTT_ASSET="client-macos-x86_64"
CSQTT_219_VERSION="2026.09.17.17.36"
URL_DMG="https://github.com/${REPO_LALUNE}/releases/latest/download/LaLune-macOS.dmg"
URL_CSQTT="https://github.com/${REPO_CSQTT}/releases/latest/download/${CSQTT_ASSET}"
URL_CSQTT_219="https://github.com/${REPO_CSQTT}/releases/download/${CSQTT_219_VERSION}/${CSQTT_ASSET}"
URL_CSQTTR="https://github.com/${REPO_CSQTTR}/releases/latest/download/${CSQTT_ASSET}"
URL_LATEST_CSQTT="https://raw.githubusercontent.com/${REPO_CSQTT}/refs/heads/main/LATEST"
URL_LATEST_CSQTTR="https://raw.githubusercontent.com/${REPO_CSQTTR}/refs/heads/main/LATEST"
URL_TOTS_ARM64="https://github.com/${REPO_TOTS}/releases/latest/download/tots-client-aarch64-apple-darwin.tar.gz"

APP_DIR="${HOME}/.la-lune"
APP_DEST="/Applications/LaLune.app"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lalune-macos.XXXXXX")"
MOUNT_POINT="${TMP_DIR}/mounted-dmg"
MOUNTED=0

c_green='\033[0;32m'; c_cyan='\033[0;36m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
step() { printf "${c_cyan}[*] %s${c_reset}\n" "$*"; }
ok() { printf "${c_green}[+] %s${c_reset}\n" "$*"; }
warn() { printf "${c_yellow}[!] %s${c_reset}\n" "$*"; }
fail() { printf "${c_red}[-] %s${c_reset}\n" "$*" >&2; exit 1; }

cleanup() {
  if [ "$MOUNTED" = "1" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

[ "$(uname -s)" = "Darwin" ] || fail "Этот установщик предназначен только для macOS."
command -v curl >/dev/null 2>&1 || fail "Нужен curl."
command -v hdiutil >/dev/null 2>&1 || fail "Не найден hdiutil."
command -v ditto >/dev/null 2>&1 || fail "Не найден ditto."

ARCH="$(uname -m)"
# `uname -m` reports x86_64 when the installer shell runs under Rosetta.
# Detect Apple Silicon hardware so the native ToTS arm64 binary is still fetched.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
  ARCH="arm64"
fi
case "$ARCH" in
  arm64|aarch64) TOTS_SUPPORTED=1 ;;
  x86_64) TOTS_SUPPORTED=0 ;;
  *) fail "Неподдерживаемая архитектура macOS: ${ARCH}" ;;
esac

mkdir -p "$TMP_DIR" "$MOUNT_POINT"

# Download phase: do not mount the DMG until all required downloads finish.
step "Скачиваю установочный образ LaLune и системные компоненты..."
curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 900 \
  -o "${TMP_DIR}/LaLune-macOS.dmg.part" "$URL_DMG"
mv "${TMP_DIR}/LaLune-macOS.dmg.part" "${TMP_DIR}/LaLune-macOS.dmg"

curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 600 \
  -o "${TMP_DIR}/csqtt-core" "$URL_CSQTT"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 600 \
  -o "${TMP_DIR}/csqtt-219" "$URL_CSQTT_219"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 600 \
  -o "${TMP_DIR}/csqttr-core" "$URL_CSQTTR"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 120 \
  -o "${TMP_DIR}/LATEST.Csqtt" "$URL_LATEST_CSQTT"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 120 \
  -o "${TMP_DIR}/LATEST.CSQTTR" "$URL_LATEST_CSQTTR"
printf '%s' "$CSQTT_219_VERSION" > "${TMP_DIR}/LATEST.CSQTT-2.1.9"

if [ "$TOTS_SUPPORTED" = "1" ]; then
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 900 \
    -o "${TMP_DIR}/tots-client-macos-arm64.tar.gz" "$URL_TOTS_ARM64"
else
  warn "ToTS desktop binary currently targets Apple Silicon; on Intel Mac it will be downloaded only if a compatible release is published."
fi

for file in "${TMP_DIR}/LaLune-macOS.dmg" "${TMP_DIR}/csqtt-core" \
            "${TMP_DIR}/csqtt-219" "${TMP_DIR}/csqttr-core" \
            "${TMP_DIR}/LATEST.Csqtt" "${TMP_DIR}/LATEST.CSQTTR"; do
  [ -s "$file" ] || fail "Файл скачан пустым: $(basename "$file")"
done
ok "Все необходимые файлы скачаны."

# Install binaries into the app's persistent data directory.
step "Подключаю DMG как диск..."
hdiutil attach "$TMP_DIR/LaLune-macOS.dmg" -readonly -nobrowse -mountpoint "$MOUNT_POINT" >/dev/null
MOUNTED=1

APP_SOURCE=""
for candidate in "$MOUNT_POINT"/*.app; do
  if [ -d "$candidate" ]; then
    APP_SOURCE="$candidate"
    break
  fi
done
[ -n "$APP_SOURCE" ] || fail "В DMG не найден .app bundle."

step "Устанавливаю LaLune в /Applications..."
sudo -v
sudo rm -rf "$APP_DEST"
sudo ditto "$APP_SOURCE" "$APP_DEST"

step "Устанавливаю ядра в ~/.la-lune..."
mkdir -p "$APP_DIR"
install -m 755 "${TMP_DIR}/csqtt-core" "$APP_DIR/csqtt-core"
install -m 755 "${TMP_DIR}/csqtt-219" "$APP_DIR/csqtt-219"
install -m 755 "${TMP_DIR}/csqttr-core" "$APP_DIR/csqttr-core"
install -m 644 "${TMP_DIR}/LATEST.Csqtt" "$APP_DIR/LATEST.Csqtt"
install -m 644 "${TMP_DIR}/LATEST.CSQTTR" "$APP_DIR/LATEST.CSQTTR"
install -m 644 "${TMP_DIR}/LATEST.CSQTT-2.1.9" "$APP_DIR/LATEST.CSQTT-2.1.9"

if [ "$TOTS_SUPPORTED" = "1" ]; then
  mkdir -p "${TMP_DIR}/tots-unpack"
  tar -xzf "${TMP_DIR}/tots-client-macos-arm64.tar.gz" -C "${TMP_DIR}/tots-unpack"
  TOTS_BIN="$(find "${TMP_DIR}/tots-unpack" -type f -name 'tots-client' -print -quit)"
  [ -n "$TOTS_BIN" ] || fail "В ToTS-архиве не найден tots-client."
  install -m 755 "$TOTS_BIN" "$APP_DIR/tots-client"
fi

hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0
ok "LaLune установлен: ${APP_DEST}"
printf '\nОткрой приложение из /Applications/LaLune.app.\n'
printf 'Данные и ядра: %s\n' "$APP_DIR"
if [ "$TOTS_SUPPORTED" = "0" ]; then
  warn "ToTS пока не поддерживает Intel macOS в опубликованном desktop-релизе."
fi
