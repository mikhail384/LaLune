#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Сборка ядер ToTS и WDTToR из исходников для OpenWRT.
#
# Скрипт подключается через `source` из build.sh (aarch64), build-ramips.sh
# (mipsel) и build-multiarch.sh (zig). Он не настраивает тулчейн сам: вызывающий
# скрипт уже экспортировал CC_<target>, CARGO_TARGET_<TARGET>_LINKER,
# CARGO_ENCODED_RUSTFLAGS и определил функцию `build`, которая собирает
# текущий пакет под нужную цель (включая -Z build-std для tier-3).
#
# Использование:
#   source "$backend_dir/build-thirdparty-cores.sh"
#   build_tots_core "$work/tots-openwrt"
#   build_wdtt_core "$work/wdtt-core"

# Ревизии закреплены так же, как у CSQTT-ядер: сборка должна быть
# воспроизводимой, а не «что сейчас в main».
TOTS_REPO=Endlad2/ToTS
TOTS_COMMIT=${LALUNE_TOTS_COMMIT:-6149a28}
TOTS_SHA256=${LALUNE_TOTS_SHA256:-b1bc25ba8b60b8d6acdbb1764abd3675cb82eacef03a2e26189eff0d472489d9}

WDTT_REPO=Endlad2/wdtt-rslib
WDTT_COMMIT=${LALUNE_WDTT_COMMIT:-71dc0da}
WDTT_SHA256=${LALUNE_WDTT_SHA256:-09d2c62745a5a1d9c347b41d65f54f1909c581695af5396c7c55029970c65ed5}

# kolibri-net (зависимость провайдера MAX) использует AtomicI64, которого нет
# на MIPS32/armv5. Патчим исходник до сборки, как это делается для CSQTT.
KOLIBRI_REPO=KometTeam/kolibri
KOLIBRI_COMMIT=7ffa90e69204f6e07a38b0927ab62bf41b47bbe0

log_cores() { printf '[openwrt-cores] %s\n' "$*"; }

# Собирает текущий пакет под нужную цель.
#
# Использует переменные, которые выставил вызывающий скрипт:
#   rust_target   тройка Rust (обязательно)
#   rust_toolchain  например nightly-2026-11-06 (пусто = стабильный cargo)
#   build_std     1 = tier-3 цель, нужен -Z build-std
#   cores_locked  1 = передавать --locked (по умолчанию да; для [patch] — нет)
cores_cargo_build() {
    local toolchain=()
    if [ -n "${rust_toolchain:-}" ]; then
        toolchain=("+$rust_toolchain")
    fi
    local std_flag=()
    if [ "${build_std:-0}" = 1 ]; then
        std_flag=(-Z build-std=std,panic_abort)
    fi
    local locked=(--locked)
    if [ "${cores_locked:-1}" != 1 ]; then
        locked=()
    fi
    cargo "${toolchain[@]}" build "${locked[@]}" --release \
        --target "$rust_target" "${std_flag[@]}" "$@"
}
fail_cores() { printf '[openwrt-cores][ERROR] %s\n' "$*" >&2; exit 1; }

# Скачивает архив исходников и распаковывает в $work.
# $1 repo, $2 commit, $3 expected sha256 (может быть пустым), $4 каталог назначения.
fetch_source() {
    local repo=$1 commit=$2 expected=$3 dest=$4
    local zip="$cache/$(echo "$repo" | tr '/' '-')-$commit.zip"
    if [ ! -f "$zip" ]; then
        curl --fail --location --silent --show-error --retry 3 \
            --output "$zip.part" "https://github.com/$repo/archive/$commit.zip" ||
            fail_cores "cannot download $repo@$commit"
        if [ -n "$expected" ]; then
            printf '%s  %s\n' "$expected" "$zip.part" | sha256sum --check >&2 ||
                fail_cores "checksum mismatch for $repo@$commit"
        fi
        mv "$zip.part" "$zip"
    elif [ -n "$expected" ]; then
        printf '%s  %s\n' "$expected" "$zip" | sha256sum --check >&2 ||
            fail_cores "checksum mismatch for $repo@$commit"
    fi
    rm -rf "$dest"
    mkdir -p "$dest"
    unzip -q "$zip" -d "$dest" >&2
    local extracted
    extracted=$(find "$dest" -maxdepth 1 -mindepth 1 -type d | head -1)
    [ -n "$extracted" ] || fail_cores "cannot extract $repo@$commit"
    printf '%s\n' "$extracted"
}

# Патчит kolibri-net на portable-atomic и возвращает путь к патченному каталогу.
# Нужен только целям без нативных 64-битных атомиков.
prepare_kolibri() {
    local patched="$cache/kolibri-$KOLIBRI_COMMIT-patched"
    if [ -d "$patched" ]; then
        printf '%s\n' "$patched"
        return 0
    fi
    local src
    src=$(fetch_source "$KOLIBRI_REPO" "$KOLIBRI_COMMIT" "" "$work/kolibri-src")
    python3 - "$src/kolibri-net" <<'PY'
import pathlib, sys
net = pathlib.Path(sys.argv[1])
signaling = net / "src/calls/signaling.rs"
text = signaling.read_text(encoding="utf-8")
text = text.replace(
    "use std::sync::atomic::{AtomicI64, Ordering};",
    "use portable_atomic::AtomicI64;\nuse std::sync::atomic::Ordering;",
)
signaling.write_text(text, encoding="utf-8")

manifest = net / "Cargo.toml"
text = manifest.read_text(encoding="utf-8")
if "portable-atomic" not in text:
    text = text.replace("[dependencies]\n", '[dependencies]\nportable-atomic = "1"\n', 1)
    manifest.write_text(text, encoding="utf-8")
PY
    mkdir -p "$patched"
    cp -r "$src/." "$patched/"
    printf '%s\n' "$patched"
}

# Патч нужен только там, где в std нет AtomicI64.
target_needs_portable_atomics() {
    case "${rust_target:-}" in
        mips-*|mipsel-*|armv5te-*|i686-*) return 0 ;;
        *) return 1 ;;
    esac
}

# Собирает tots-openwrt и кладёт бинарник в $1.
build_tots_core() {
    local dest=$1
    local src
    src=$(fetch_source "$TOTS_REPO" "$TOTS_COMMIT" "$TOTS_SHA256" "$work/tots-src")
    log_cores "ToTS source: $TOTS_REPO@$TOTS_COMMIT"

    local patch_arg=()
    if target_needs_portable_atomics; then
        local kolibri
        kolibri=$(prepare_kolibri)
        log_cores "patching kolibri-net for 32-bit atomics: $kolibri"
        patch_arg=(--config "patch.\"https://github.com/KometTeam/kolibri\".kolibri-net.path=\"$kolibri/kolibri-net\"")
    fi

    (
        cd "$src"
        export CARGO_TARGET_DIR="$cache/target-cores-${abi:-aarch64}/tots-$TOTS_COMMIT"
        # --locked снимаем: [patch] переписывает источник kolibri в lock-файле.
        # --locked снимаем, когда подключён [patch]: он переписывает источник
        # kolibri в lock-файле.
        cores_locked=1
        if [ ${#patch_arg[@]} -gt 0 ]; then cores_locked=0; fi
        cores_cargo_build --bin tots-openwrt "${patch_arg[@]}"
        install -m 755 "$CARGO_TARGET_DIR/${rust_target}/release/tots-openwrt" "$dest"
    )
    log_cores "ToTS core built: $dest"
}

# Собирает wdtt-rslib (бинарник называется wdtt-rslib) и кладёт его в $1.
build_wdtt_core() {
    local dest=$1
    local src
    src=$(fetch_source "$WDTT_REPO" "$WDTT_COMMIT" "$WDTT_SHA256" "$work/wdtt-src")
    log_cores "WDTToR source: $WDTT_REPO@$WDTT_COMMIT"

    (
        cd "$src"
        export CARGO_TARGET_DIR="$cache/target-cores-${abi:-aarch64}/wdtt-$WDTT_COMMIT"
        cores_cargo_build --bin wdtt-rslib
        install -m 755 "$CARGO_TARGET_DIR/${rust_target}/release/wdtt-rslib" "$dest"
    )
    log_cores "WDTToR core built: $dest"
}
