#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Universal OpenWRT backend build for the architectures that are NOT covered by
# the dedicated SDK scripts (build.sh = aarch64, build-ramips.sh = mipsel):
#
#   x86_64 | i386 | armv7 | armv5 | mips | riscv64
#
# Static musl binaries are cross-compiled with Rust + `zig cc` as the C
# compiler/linker (one pinned zig works for every target, no per-arch SDK).
# Builds the three pinned cores, embeds them in the backend and smoke-tests
# the result (natively or under qemu-user).
#
# Usage: build-multiarch.sh <abi> [cache-dir]
# Output: output/lalune-openwrt-backend-<abi>, output/lalune-openwrt-cores-<abi>.zip

set -euo pipefail
export LC_ALL=C

abi=${1:?usage: build-multiarch.sh <x86_64|i386|armv7|armv5|mips|riscv64> [cache-dir]}
backend_dir=$(cd -- "$(dirname -- "$0")" && pwd)
cache=${2:-$backend_dir/../../.cache/openwrt-multiarch}
mkdir -p "$cache" "$backend_dir/output"
cache=$(cd -- "$cache" && pwd)
work=$(mktemp -d "$cache/build.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

log() { printf '[openwrt-%s] %s\n' "$abi" "$*"; }
fail() { printf '[openwrt-%s][ERROR] %s\n' "$abi" "$*" >&2; exit 1; }

# ---- per-ABI table -----------------------------------------------------
# rust_target   Rust triple
# zig_target    zig -target triple
# zig_flags     extra CPU flags for the C compiler (soft-float/baseline CPU)
# patch_atomics 1 = target has no native 64-bit atomics (use portable-atomic)
# build_std     1 = tier-3 Rust target (needs -Z build-std)
# qemu          qemu-user binary (empty = run natively)
# elf_*         expected ELF header facts
case "$abi" in
    x86_64)  rust_target=x86_64-unknown-linux-musl;     zig_target=x86_64-linux-musl;   zig_flags="";                          patch_atomics=0; build_std=0; qemu="";            elf_class=ELF64; elf_data="little endian"; elf_machine="X86-64" ;;
    i386)    rust_target=i686-unknown-linux-musl;       zig_target=x86-linux-musl;      zig_flags="-mcpu=pentium4";            patch_atomics=0; build_std=0; qemu="qemu-i386";   elf_class=ELF32; elf_data="little endian"; elf_machine="Intel 80386" ;;
    armv7)   rust_target=armv7-unknown-linux-musleabihf; zig_target=arm-linux-musleabihf; zig_flags="-mcpu=cortex_a9";         patch_atomics=0; build_std=0; qemu="qemu-arm";    elf_class=ELF32; elf_data="little endian"; elf_machine="ARM" ;;
    armv5)   rust_target=armv5te-unknown-linux-musleabi; zig_target=arm-linux-musleabi;   zig_flags="-mcpu=arm926ej_s";        patch_atomics=1; build_std=0; qemu="qemu-arm";    elf_class=ELF32; elf_data="little endian"; elf_machine="ARM" ;;
    mips)    rust_target=mips-unknown-linux-musl;       zig_target=mips-linux-musl;     zig_flags="-mcpu=mips32r2 -msoft-float"; patch_atomics=1; build_std=1; qemu="qemu-mips";  elf_class=ELF32; elf_data="big endian";    elf_machine="MIPS" ;;
    riscv64) rust_target=riscv64gc-unknown-linux-musl;  zig_target=riscv64-linux-musl;  zig_flags="";                          patch_atomics=0; build_std=0; qemu="qemu-riscv64"; elf_class=ELF64; elf_data="little endian"; elf_machine="RISC-V" ;;
    *) fail "unknown abi '$abi'" ;;
esac
# The qemu CPU model used for the smoke tests.
case "$abi" in
    armv7) qemu_cpu="cortex-a9" ;;
    armv5) qemu_cpu="arm926" ;;
    mips)  qemu_cpu="24Kc" ;;
    # The i686 build needs SSE2 (ring/aws-lc): pentium4 class, qemu model with SSE2.
    i386)  qemu_cpu="core2duo" ;;
    *)     qemu_cpu="" ;;
esac

for cmd in curl tar xz sha256sum cargo rustup unzip zip readelf python3; do
    command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
done
if [ -n "$qemu" ]; then
    command -v "$qemu" >/dev/null 2>&1 || fail "missing $qemu (apt install qemu-user)"
fi

fetch() {
    local url=$1 destination=$2 expected_sha=$3
    if [ ! -f "$destination" ]; then
        curl --fail --location --retry 5 --retry-delay 3 --output "$work/download" "$url"
        printf '%s  %s\n' "$expected_sha" "$work/download" | sha256sum --check
        mv "$work/download" "$destination"
    else
        printf '%s  %s\n' "$expected_sha" "$destination" | sha256sum --check
    fi
}

# ---- pinned zig --------------------------------------------------------
zig_version=0.13.0
zig_archive="zig-linux-x86_64-$zig_version.tar.xz"
fetch "https://ziglang.org/download/$zig_version/$zig_archive" "$cache/$zig_archive" \
    d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea
zig_dir="$cache/zig-linux-x86_64-$zig_version"
if [ ! -d "$zig_dir" ]; then
    tar -xJf "$cache/$zig_archive" -C "$cache"
fi
export PATH="$zig_dir:$PATH"
export ZIG_GLOBAL_CACHE_DIR="$cache/zig-cache"
export ZIG_LOCAL_CACHE_DIR="$cache/zig-cache-local"

# zig cc wrappers (cargo/cc-rs need single executables)
mkdir -p "$work/bin"
# cc-rs appends `--target=<rust-triple>` (e.g. x86_64-unknown-linux-musl) which
# zig cannot parse, so the wrappers drop it and pass the zig triple instead.
for tool in cc c++; do
    name=zigcc; [ "$tool" = "c++" ] && name=zigcxx
    cat > "$work/bin/$name" <<EOF
#!/bin/sh
for a in "\$@"; do
    shift
    case "\$a" in
        --target=*|-target=*) ;;
        # rustc's i686 pre-link arg; zig's -target already selects 32-bit x86.
        -melf_i386|-Wl,-melf_i386) ;;
        *) set -- "\$@" "\$a" ;;
    esac
done
exec zig $tool -target $zig_target $zig_flags "\$@"
EOF
done
printf '#!/bin/sh\nexec zig ar "$@"\n' > "$work/bin/zigar"
chmod +x "$work/bin/zigcc" "$work/bin/zigcxx" "$work/bin/zigar"

upper=$(printf '%s' "$rust_target" | tr 'a-z-' 'A-Z_')
lower=$(printf '%s' "$rust_target" | tr '-' '_')
export "CARGO_TARGET_${upper}_LINKER=$work/bin/zigcc"
export "CC_${lower}=$work/bin/zigcc"
export "CXX_${lower}=$work/bin/zigcxx"
export "AR_${lower}=$work/bin/zigar"
export CARGO_PROFILE_RELEASE_STRIP=true
# zig supplies musl, crt objects and libunwind: do not let rustc add its own
# self-contained copies (duplicate _start/_init symbols otherwise).
printf -v rustflags '%s\037' -C target-feature=+crt-static -C link-self-contained=no
export CARGO_ENCODED_RUSTFLAGS="${rustflags%$'\037'}"
# Flaky networks: more retries, no "transfer too slow" aborts.
export CARGO_NET_RETRY=10
export CARGO_HTTP_TIMEOUT=600
export CARGO_HTTP_LOW_SPEED_LIMIT=0
export CARGO_HTTP_MULTIPLEXING=false

# ---- Rust toolchain (same nightly as the ramips build) -----------------
rust_toolchain=nightly-2026-11-06
retry() {  # retry <attempts> <command...>: rustup/crates mirrors drop connections now and then
    local attempts=$1 n=1; shift
    until "$@"; do
        [ "$n" -lt "$attempts" ] || return 1
        log "retry $n/$attempts: $*"; n=$((n + 1)); sleep 5
    done
}
retry 5 rustup toolchain install "$rust_toolchain" --profile minimal --component rust-src
if [ "$build_std" = 0 ]; then
    retry 5 rustup target add --toolchain "$rust_toolchain" "$rust_target"
fi

build() {
    if [ "$build_std" = 1 ]; then
        cargo "+$rust_toolchain" build --locked --release --target "$rust_target" -Z build-std=std,panic_abort "$@"
    else
        cargo "+$rust_toolchain" build --locked --release --target "$rust_target" "$@"
    fi
}

verify_elf() {
    local binary=$1 header program_headers dynamic
    header=$(readelf -h "$binary")
    program_headers=$(readelf -l "$binary")
    dynamic=$(readelf -d "$binary" 2>&1 || true)
    if ! grep -q "Class:.*$elf_class" <<< "$header" ||
       ! grep -q "Data:.*$elf_data" <<< "$header" ||
       ! grep -q "Machine:.*$elf_machine" <<< "$header" ||
       grep -q 'INTERP' <<< "$program_headers" ||
       grep -q '(NEEDED)' <<< "$dynamic"; then
        printf 'Unexpected ELF ABI or linkage: %s\n%s\n%s\n%s\n' "$binary" "$header" "$program_headers" "$dynamic" >&2
        exit 1
    fi
    sha256sum "$binary"
}

run_target() {  # run a target binary natively or under qemu-user
    if [ -n "$qemu" ]; then
        if [ -n "$qemu_cpu" ]; then "$qemu" -cpu "$qemu_cpu" "$@"; else "$qemu" "$@"; fi
    else
        "$@"
    fi
}

build_core() (
    local repo=$1 commit=$2 expected_sha=$3 name=$4
    local zip="$cache/$repo-$commit.zip"
    fetch "https://github.com/Endlad2/$repo/archive/$commit.zip" "$zip" "$expected_sha"
    unzip -q "$zip" -d "$work"
    cd "$work/$repo-$commit/rust-client"
    if [ "$patch_atomics" = 1 ]; then
        python3 "$backend_dir/ramips-core-portability.py" .
    fi
    python3 "$backend_dir/musl-core-portability.py" .
    export CARGO_TARGET_DIR="$cache/target-cores-$abi/$repo-$commit"
    build --bin client
    install -m 755 "$CARGO_TARGET_DIR/$rust_target/release/client" "$work/$name"
    verify_elf "$work/$name"
    local status=0 out
    out=$(timeout 60 bash -c "$(declare -f run_target); qemu='$qemu'; qemu_cpu='$qemu_cpu'; run_target '$work/$name'" 2>&1) || status=$?
    if [ "$status" -ne 1 ] || ! grep -Fq -- '-peer' <<< "$out"; then
        printf 'Core startup check failed: %s (status %s)\n%s\n' "$name" "$status" "$out" >&2
        exit 1
    fi
    log "core $name OK"
)

# Same three source revisions as the aarch64/ramips builds.
build_core csqtt-core 181a0d9f162bb8040c255496af0aeb14828e612e \
    2e658ce1225c691b93430efdd15cc0832fe91f208585103a23b2305a925d58c1 csqtt-client
build_core csqttr-core afab4c1f279c3e132699130b95184e628f7dda1c \
    58fb9d29c5a12f3ab44260a90d22fbb53714c2d620f6eb5a64a189a1ec1927a7 csqttr-client
build_core csqtt-core eda00fce6343430b40413da01791946dccb9c6ff \
    f1c7427b4bd67ecb181c2a01eeb3455bb8959bedbe91dd29ef08650a7c10f530 csqtt-219

(
    cd "$work"
    zip -9 -X openwrt-cores.zip csqtt-client csqttr-client csqtt-219
    unzip -t openwrt-cores.zip
)
export LALUNE_OPENWRT_CORES="$work/openwrt-cores.zip"
export CARGO_TARGET_DIR="$cache/target-backend-$abi"
cd "$backend_dir"
log "building backend with embedded cores"
build --bin lalune-openwrt-backend
binary="$CARGO_TARGET_DIR/$rust_target/release/lalune-openwrt-backend"
verify_elf "$binary"

# ---- smoke test: /ping and bundled core list ---------------------------
smoke_home=$(mktemp -d "$work/home.XXXXXX")
# HOME is inherited (also by qemu-user); do not wrap in `env`, qemu would try to
# run the host `env` binary as the guest program.
HOME="$smoke_home" run_target "$binary" >"$smoke_home/backend.log" 2>&1 &
backend_pid=$!
cleanup_smoke() { kill "$backend_pid" 2>/dev/null || true; wait "$backend_pid" 2>/dev/null || true; }
ok=0
smoke_tries=150
[ "$abi" = riscv64 ] && smoke_tries=450   # qemu-riscv64 is by far the slowest emulator
for _ in $(seq 1 "$smoke_tries"); do  # qemu-user is slow to start a 20 MB static binary
    if curl -fsS -o "$smoke_home/ping.json" http://127.0.0.1:1062/ping 2>/dev/null; then ok=1; break; fi
    kill -0 "$backend_pid" 2>/dev/null || break
    sleep 1
done
if [ "$ok" != 1 ]; then
    cleanup_smoke
    cat "$smoke_home/backend.log" >&2
    fail "backend did not answer /ping"
fi
curl -fsS http://127.0.0.1:1062/core/protocols -o "$smoke_home/protocols.json"
python3 - "$smoke_home" <<'PY'
import json, sys
home = sys.argv[1]
ping = json.load(open(home + "/ping.json"))
assert ping.get("ok") and ping.get("platform") == "openwrt", ping
protocols = json.load(open(home + "/protocols.json"))
ids = sorted(p["id"] for p in protocols)
assert all(p.get("bundled") for p in protocols), protocols
assert ids == ["CSQTT", "CSQTT 2.1.9", "CSQTTR"], ids
print("smoke OK:", ping.get("arch"), ids)
PY
cleanup_smoke

install -m 755 "$binary" "output/lalune-openwrt-backend-$abi"
cp "$LALUNE_OPENWRT_CORES" "output/lalune-openwrt-cores-$abi.zip"
log "done: output/lalune-openwrt-backend-$abi"
