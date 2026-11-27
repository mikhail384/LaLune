#!/usr/bin/env bash
#
# Builds the LaLune VK token fetcher for Linux and Windows and stores the
# gzip-compressed binaries in Backend/Desktop/assets/, where the desktop
# launcher and CI expect them.
#
# The script is idempotent: every run rebuilds both artifacts and overwrites
# the previous ones. Intermediate binaries stay in a temporary directory next
# to this script and are removed on exit.
#
# Usage:
#   ./build.sh
#   GO_BIN=/path/to/go ./build.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
ASSETS_DIR="${REPO_ROOT}/Backend/Desktop/assets"
GO_BIN="${GO_BIN:-go}"

if ! command -v "${GO_BIN}" >/dev/null 2>&1; then
  echo "[build] go not found: install Go 1.22+ or set GO_BIN to the toolchain binary" >&2
  exit 1
fi
GO_BIN="$(command -v "${GO_BIN}")"

BUILD_DIR="$(mktemp -d "${SCRIPT_DIR}/.build.XXXXXX")"
cleanup() {
  rm -rf -- "${BUILD_DIR}"
}
trap cleanup EXIT

mkdir -p "${ASSETS_DIR}"

file_size() {
  wc -c <"$1" | tr -d '[:space:]'
}

build_target() {
  local goos="$1"
  local goarch="$2"
  local binary_name="$3"
  local gz_name="$4"

  local binary="${BUILD_DIR}/${binary_name}"
  local gz_tmp="${BUILD_DIR}/${gz_name}"
  local gz_out="${ASSETS_DIR}/${gz_name}"

  echo "[build] GOOS=${goos} GOARCH=${goarch} CGO_ENABLED=0 -> ${gz_name}"

  (
    cd "${SCRIPT_DIR}"
    GOOS="${goos}" GOARCH="${goarch}" CGO_ENABLED=0 \
      "${GO_BIN}" build -trimpath -ldflags "-s -w" -o "${binary}" .
  )

  gzip -9 -n -c "${binary}" >"${gz_tmp}"
  mv -f "${gz_tmp}" "${gz_out}"

  printf '[build] %-34s binary %10s bytes, gzip %10s bytes\n' \
    "${gz_name}" "$(file_size "${binary}")" "$(file_size "${gz_out}")"
}

build_target linux amd64 token-fetcher-linux-amd64 token-fetcher-linux-amd64.gz
build_target windows amd64 token-fetcher.exe token-fetcher-windows-amd64.exe.gz

echo "[build] artifacts in ${ASSETS_DIR}:"
ls -l "${ASSETS_DIR}/token-fetcher-linux-amd64.gz" "${ASSETS_DIR}/token-fetcher-windows-amd64.exe.gz"
