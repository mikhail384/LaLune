#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Проверка выбора сборки backend по DISTRIB_ARCH роутера.
# Использование: test-abi.sh <openwrt.sh>
# Функция lalune_abi вырезается из установщика, поэтому тест проверяет
# именно тот код, который выполнится на роутере (ash/busybox).
set -eu

src=${1:?usage: test-abi.sh <openwrt.sh>}
fn=$(mktemp)
trap 'rm -f "$fn"' EXIT
sed -n '/^lalune_abi()/,/^}/p' "$src" > "$fn"
[ -s "$fn" ] || { echo "lalune_abi() not found in $src" >&2; exit 1; }
# shellcheck disable=SC1090
. "$fn"

failed=0
check() {
    got=$(lalune_abi "$1" 2>/dev/null) || got=UNSUPPORTED
    if [ "$got" != "$2" ]; then
        echo "FAIL: '$1' -> $got (expected $2)"
        failed=1
    fi
}

# aarch64
for a in aarch64_generic aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76; do check "$a" aarch64; done
# x86
check x86_64 x86_64
check i386_pentium4 i386
check i386_pentium-mmx UNSUPPORTED   # no SSE2
# mips little-endian (ramips, mt7621/mt76x8/mt7620/rt305x)
for a in mipsel_24kc mipsel_24kc_24kf mipsel_74kc mipsel_24kec_dsp mipsel_1004kc_dsp; do check "$a" ramips; done
# mips big-endian (ath79, lantiq, realtek, ...)
for a in mips_24kc mips_74kc mips_4kec; do check "$a" mips; done
# mips32r1 (Broadcom bmips): not supported by the mips32r2 builds
check mipsel_mips32 UNSUPPORTED
check mips_mips32 UNSUPPORTED
# arm with VFP (cortex-a5/a7/a8/a9/a15/a53, ipq40xx, mvebu, bcm27xx 32-bit)
for a in arm_cortex-a7 arm_cortex-a7_neon-vfpv4 arm_cortex-a9 arm_cortex-a9_neon arm_cortex-a9_vfpv3-d16 \
         arm_cortex-a15_neon-vfpv4 arm_cortex-a5_vfpv4 arm_cortex-a8_vfpv3 arm_cortex-a53_neon-vfpv4; do
    check "$a" armv7
done
# arm older cores (soft-float static build runs on all of them)
for a in arm_arm926ej-s arm_xscale arm_arm1176jzf-s_vfp arm_mpcore arm_fa526 arm_arm920t; do check "$a" armv5; done
# riscv64: not shipped yet (backend did not pass the smoke test under qemu)
check riscv64_riscv64 UNSUPPORTED
# not supported
for a in powerpc_464fp powerpc_8540 powerpc64_e5500 mips64_octeonplus mips64_octeon loongarch64_generic ""; do
    check "$a" UNSUPPORTED
done

[ "$failed" = 0 ] || exit 1
echo "abi mapping OK"
