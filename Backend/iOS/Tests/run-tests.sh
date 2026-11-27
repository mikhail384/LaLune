#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Builds and runs the off-device tests for the userspace tunnel data plane
# (TCP stack, UDP NAT, DNS wire format). Linux + the Swift toolchain vendored
# under .swift-tools are required; nothing is written outside the repository.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SWIFTC="${REPO_ROOT}/.swift-tools/swift-5.10.1-RELEASE-ubuntu22.04/usr/bin/swiftc"

if [[ ! -x "${SWIFTC}" ]]; then
  echo "error: swiftc not found at ${SWIFTC}" >&2
  exit 1
fi

# The sandbox only allows writes inside the repository.
export CLANG_MODULE_CACHE_PATH="${REPO_ROOT}/.scratch/module-cache"
export TMPDIR="${REPO_ROOT}/.scratch/tmp"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${TMPDIR}" "${REPO_ROOT}/.scratch/tests"

cd "${REPO_ROOT}"

"${SWIFTC}" -O \
  -module-cache-path "${CLANG_MODULE_CACHE_PATH}" \
  -o .scratch/tests/run \
  Backend/iOS/PacketCodec.swift \
  Backend/iOS/TunnelTypes.swift \
  Backend/iOS/DnsMessage.swift \
  Backend/iOS/TcpStack.swift \
  Backend/iOS/UdpNat.swift \
  Backend/iOS/Tests/main.swift

exec ./.scratch/tests/run
