#!/usr/bin/env bash
set -euo pipefail

# Keenetic 4G (KN-1211) QEMU Virtual Machine & Benchmark Script
# Target hardware: MediaTek MT7628N (MIPS 24Kc LE, 1 core, 64 MB RAM, 16 MB Flash)

OPENWRT_VER="${OPENWRT_VER:-23.05.5}"
WORKDIR="${WORKDIR:-$(pwd)/.kn1211-vm}"
RAM_MB="${RAM_MB:-64}"
OPENWRT_HOST="downloads.openwrt.org"
OPENWRT_PATH="/releases/${OPENWRT_VER}/targets/malta/le/openwrt-${OPENWRT_VER}-malta-le-vmlinux-initramfs.elf"
KERNEL_IMG="${WORKDIR}/openwrt-${OPENWRT_VER}-malta-le-vmlinux-initramfs.elf"

run_bench() {
  local bin_path="$1"
  if [[ ! -f "$bin_path" ]]; then
    echo "Error: Binary not found: $bin_path" >&2
    exit 1
  fi
  if ! command -v qemu-mipsel >/dev/null 2>&1; then
    echo "Error: qemu-mipsel not found. Please install qemu-user." >&2
    exit 1
  fi

  local size_bytes size_kb
  size_bytes=$(wc -c < "$bin_path")
  size_kb=$((size_bytes / 1024))
  echo "Binary size: ${size_bytes} bytes (${size_kb} KB)"

  local tmp_home
  tmp_home=$(mktemp -d)
  trap 'rm -rf "$tmp_home"' EXIT

  local start_ns end_ns elapsed_ms pid vm_rss
  start_ns=$(date +%s%N)
  HOME="$tmp_home" qemu-mipsel -cpu 24Kc "$bin_path" >/dev/null 2>&1 &
  pid=$!

  local ready=0
  for _ in $(seq 1 100); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Error: Process exited prematurely" >&2
      exit 1
    fi
    if curl -sf "127.0.0.1:1062/version" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.1
  done

  end_ns=$(date +%s%N)
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

  if [[ "$ready" -ne 1 ]]; then
    echo "Error: Timeout waiting for 127.0.0.1:1062/version after 10s" >&2
    kill "$pid" 2>/dev/null || true
    exit 1
  fi

  vm_rss=$(awk '/^VmRSS:/ {print $2}' "/proc/${pid}/status" 2>/dev/null || echo "0")
  echo "Cold start time: ${elapsed_ms} ms"
  echo "VmRSS: ${vm_rss} KB (KN-1211 limit: 65536 KB)"
  if [[ "$vm_rss" -gt 65536 ]]; then
    echo "Warning: VmRSS exceeds KN-1211 65536 KB RAM limit!" >&2
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

run_vm() {
  if ! command -v qemu-system-mipsel >/dev/null 2>&1; then
    echo "Error: qemu-system-mipsel not found. Please install qemu-system-mips." >&2
    exit 1
  fi

  mkdir -p "$WORKDIR"
  if [[ ! -f "$KERNEL_IMG" ]]; then
    echo "Downloading OpenWrt ${OPENWRT_VER} malta/le image from ${OPENWRT_HOST}..."
    curl -fL "https://${OPENWRT_HOST}${OPENWRT_PATH}" -o "$KERNEL_IMG"
  fi

  echo "Starting Keenetic KN-1211 QEMU VM (${RAM_MB} MB RAM)..."
  echo "Port forwarding: SSH 2222->22, LuCI 8080->80, LaLune API 1062->1062"
  exec qemu-system-mipsel \
    -M malta \
    -cpu 24Kc \
    -smp 1 \
    -m "${RAM_MB}M" \
    -kernel "$KERNEL_IMG" \
    -nographic \
    -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80,hostfwd=tcp::1062-:1062 \
    -device pcnet,netdev=net0
}

if [[ "${1:-}" == "--bench" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "Usage: $0 --bench <binary_path>" >&2
    exit 1
  fi
  run_bench "$2"
else
  run_vm
fi
