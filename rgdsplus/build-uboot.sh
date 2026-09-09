#!/bin/bash
#
# build-uboot.sh - build the RG DS Plus bootloader chain.
#
# The RG DS Plus is a Rockchip RK3568 with 1 GB LPDDR3 and NO eMMC (microSD
# boot). U-Boot proper + trust are shared with the RG DS (built the rk3568 way,
# carrying the AVB-off / always-unlocked / dual-DSI-panel patches).
#
# The LOADER (DDR init + SPL) is the one board-specific piece and the biggest
# boot risk on 1 GB LPDDR3. Rather than guess a generic rkbin DDR blob, we use
# the STOCK idbloader extracted from the shipping RG DS Plus SD card, whose DDR
# init (v1.25 "typ") is the authoritative training for THIS panel/DRAM. We wrap
# it with our AVB-off u-boot proper: the stock SPL loads our uboot.img FIT.
#
#   rgdsplus/stock-idbloader.img   stock DDR init + SPL (LBA 64..16383 of the
#                                  stock SD), committed in-tree.
#   out-plus/loader.img            = the stock idbloader          -> SD LBA 64
#   out-plus/uboot.img             our U-Boot FIT (u-boot+ATF+OP-TEE) -> uboot part
#
# (trust is bundled inside uboot.img on rk356x - no separate trust.img.)
#
# Fallback if the stock idbloader is unavailable: build a loader from rkbin with
# the generic rk3568 1056 MHz DDR blob (see build-uboot-genericddr.sh.note).
#
# Usage: rgdsplus/build-uboot.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UDIR="$(cd "$HERE/.." && pwd)"                 # u-boot tree root
OUT="$UDIR/out-plus"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
STOCK_IDB="$HERE/stock-idbloader.img"          # extracted from the stock SD

log() { printf '>> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v "${CROSS}gcc" >/dev/null || die "aarch64 toolchain not found (${CROSS}gcc)"
[ -f "$STOCK_IDB" ] || die "stock idbloader missing at $STOCK_IDB (extract LBA 64..16383 of the stock RG DS Plus SD)"
mkdir -p "$OUT"

# ---- 1. u-boot proper + trust (rk3568 target, shared with RG DS) -----------
CC_PREFIX="$(command -v "${CROSS}gcc")"; CC_PREFIX="${CC_PREFIX%gcc}"
log "building u-boot proper + trust (rk3568) with ${CROSS}gcc"
cd "$UDIR"
./make.sh rk3568 CROSS_COMPILE="$CC_PREFIX"

# ---- 2. loader = the stock idbloader (proven LPDDR3 DDR init + stock SPL) ---
log "using stock idbloader for the loader (LPDDR3 DDR init v1.25)"
cp "$STOCK_IDB" "$OUT/loader.img"

# ---- 3. collect ------------------------------------------------------------
[ -f "$UDIR/uboot.img" ] && cp "$UDIR/uboot.img" "$OUT/" && log "copied uboot.img -> out-plus/uboot.img"

# ---- 4. overclock variant: ATF CPU 2160 MHz --------------------------------
# RK3568 armclk is ATF(BL31)-owned via SCMI; rkbin ships BL31 as a blob, so the
# CPU OC is a deterministic binary patch of the built FIT (rate list + PLL-config
# + FIT sha), matching the shipped RG DS. apply_oc_atf.py self-locates the atf-3
# node so it is reproducible across rebuilds. Pair with the DT opp-2160000000.
if [ -f "$OUT/uboot.img" ] && command -v python3 >/dev/null; then
  cp "$OUT/uboot.img" "$OUT/uboot_oc.img"
  python3 "$HERE/apply_oc_atf.py" "$OUT/uboot_oc.img" && \
    log "built out-plus/uboot_oc.img (CPU 2160 MHz OC)" || \
    { log "OC patch FAILED - shipping stock uboot only"; rm -f "$OUT/uboot_oc.img"; }
fi

cat <<EOF

Done. RG DS Plus bootloader chain in $OUT :
   out-plus/loader.img   stock idbloader (LPDDR3 DDR init v1.25 + SPL)  -> SD LBA 64
   out-plus/uboot.img    our U-Boot FIT (u-boot + ATF + OP-TEE), stock 1992  -> uboot partition
   out-plus/uboot_oc.img same FIT, ATF patched for CPU 2160 MHz OC (flash this for OC)
EOF
