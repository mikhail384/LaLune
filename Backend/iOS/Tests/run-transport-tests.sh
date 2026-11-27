#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Автономная сборка и запуск тестов чистых частей iOS-транспорта на Linux.
#
# Собираются только Foundation-only файлы: TunnelTypes.swift, PacketCodec.swift,
# Ipv4Routing.swift, IncyConfig.swift, TunnelResolver.swift + тестовые
# transport_stubs.swift, transport_resolver_tests.swift и transport_main.swift.
# Network.framework / AVFoundation сюда не тянутся.
#
# Использование:
#   Backend/iOS/Tests/run-transport-tests.sh            # собрать и запустить
#   KEEP_BUILD=1 Backend/iOS/Tests/run-transport-tests.sh
#
# Кеш модулей и TMPDIR держим внутри репозитория, чтобы ничего не писать в $HOME.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${IOS_DIR}/../.." && pwd)"

SWIFTC="${REPO_ROOT}/.swift-tools/swift-5.10.1-RELEASE-ubuntu22.04/usr/bin/swiftc"
if [[ ! -x "${SWIFTC}" ]]; then
  echo "не найден swiftc: ${SWIFTC}" >&2
  echo "ожидается репозиторный тулчейн в .swift-tools/" >&2
  exit 2
fi

BUILD_DIR="${SCRIPT_DIR}/.build-transport"
export CLANG_MODULE_CACHE_PATH="${REPO_ROOT}/.scratch/module-cache"
export TMPDIR="${REPO_ROOT}/.scratch/tmp"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${TMPDIR}" "${BUILD_DIR}"

SOURCES=(
  "${IOS_DIR}/TunnelTypes.swift"
  "${IOS_DIR}/PacketCodec.swift"
  "${IOS_DIR}/Ipv4Routing.swift"
  "${IOS_DIR}/IncyConfig.swift"
  "${IOS_DIR}/TunnelResolver.swift"
  "${SCRIPT_DIR}/transport_stubs.swift"
  "${SCRIPT_DIR}/transport_resolver_tests.swift"
  "${SCRIPT_DIR}/transport_main.swift"
)

for source in "${SOURCES[@]}"; do
  if [[ ! -f "${source}" ]]; then
    echo "не найден исходник: ${source}" >&2
    exit 2
  fi
done

BIN="${BUILD_DIR}/transport-tests"

echo "== swiftc: $("${SWIFTC}" --version | head -n 1)"
echo "== сборка: ${#SOURCES[@]} файлов"
"${SWIFTC}" \
  -O \
  -warnings-as-errors \
  -module-name TransportTests \
  -o "${BIN}" \
  "${SOURCES[@]}"

echo "== запуск"
"${BIN}"
status=$?

if [[ "${KEEP_BUILD:-0}" != "1" ]]; then
  rm -rf "${BUILD_DIR}"
fi

exit "${status}"
