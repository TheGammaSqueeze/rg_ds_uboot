#!/bin/bash
#
# build-uboot.sh - build the RG DS Plus bootloader chain from source.
#
# The RG DS Plus is a Rockchip RK3568 with 1 GB LPDDR3 and NO eMMC (microSD
# boot). U-Boot proper and trust are shared with the RG DS (built the rk3568
# way and carrying the AVB-off / always-unlocked / dual-DSI-panel patches);
# only the loader differs: it must init 1 GB LPDDR3, so it is rebuilt with the
# GENERIC rk3568 1056 MHz DDR blob instead of make.sh's 1560 MHz LP4 default.
#
#   out/uboot.img   U-Boot proper FIT (bundles u-boot + ATF/BL31 + OP-TEE)
#   out/loader.img  DDR init (generic rk3568 1056 MHz) + SPL, from rkbin
# (trust is bundled inside uboot.img on rk356x - there is no separate trust.img,
#  matching the RG DS build.)
#
# Usage: rgdsplus/build-uboot.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UDIR="$(cd "$HERE/.." && pwd)"                 # u-boot tree root
OUT="$UDIR/out-plus"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
RKBIN="${RKBIN:-$UDIR/../rkbin}"
PLUS_INI="RKBOOT/RK3568MINIALL_RGDSPLUS.ini"   # generated below (generic 1056 MHz DDR)

log() { printf '>> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v "${CROSS}gcc" >/dev/null || die "aarch64 toolchain not found (${CROSS}gcc)"
[ -d "$RKBIN/RKBOOT" ] || die "rkbin not found at $RKBIN"
[ -f "$RKBIN/RKBOOT/RK3568MINIALL.ini" ] || die "stock RK3568MINIALL.ini missing in rkbin"
if [ ! -e "$UDIR/../rkbin/RKBOOT" ]; then ln -sfn "$RKBIN" "$UDIR/../rkbin"; fi

# Derive the Plus loader ini from the stock rk3568 ini: swap the 1560 MHz LP4
# DDR blob for the generic 1056 MHz (LPDDR3-capable, auto-detect) and give it a
# distinct output name. Keeps rkbin pristine (nothing committed into it).
log "generating $PLUS_INI (generic 1056 MHz DDR) from RK3568MINIALL.ini"
sed -e 's#bin/rk35/rk3568_ddr_1560MHz_v1.26.bin#bin/rk35/rk3568_ddr_1056MHz_v1.26.bin#g' \
    -e 's#PATH=rk356x_loader_v1.26.114.bin#PATH=rk356x_loader_rgdsplus_1056_v1.26.114.bin#' \
    "$RKBIN/RKBOOT/RK3568MINIALL.ini" > "$RKBIN/$PLUS_INI"
RKBIN="$(cd "$UDIR/../rkbin" && pwd)"
mkdir -p "$OUT"

# ---- 1. u-boot proper + trust (rk3568 target, shared with RG DS) -----------
CC_PREFIX="$(command -v "${CROSS}gcc")"; CC_PREFIX="${CC_PREFIX%gcc}"
log "building u-boot proper + trust (rk3568) with ${CROSS}gcc"
cd "$UDIR"
./make.sh rk3568 CROSS_COMPILE="$CC_PREFIX"

# ---- 2. loader with the generic rk3568 1056 MHz DDR (LPDDR3-capable) -------
log "building RG DS Plus loader (generic 1056 MHz DDR) from $PLUS_INI"
cd "$RKBIN"
./tools/boot_merger "$PLUS_INI"
RKLOADER="$(ls -t "$RKBIN"/rk356x_loader_rgdsplus_*.bin 2>/dev/null | head -1)"
[ -f "$RKLOADER" ] || die "loader build produced no rk356x_loader_rgdsplus_*.bin"
cp "$RKLOADER" "$OUT/loader.img"
log "loader: $(basename "$RKLOADER") -> out-plus/loader.img"

# ---- 3. collect ------------------------------------------------------------
[ -f "$UDIR/uboot.img" ] && cp "$UDIR/uboot.img" "$OUT/" && log "copied uboot.img -> out-plus/uboot.img"

cat <<EOF

Done. RG DS Plus bootloader chain in $OUT :
   out-plus/loader.img   DDR init (generic rk3568 1056 MHz) + SPL  -> SD LBA 64
   out-plus/uboot.img    U-Boot FIT (u-boot + ATF + OP-TEE)        -> uboot partition
EOF
