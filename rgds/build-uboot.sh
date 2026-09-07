#!/bin/bash
#
# build-uboot.sh - build the RG DS bootloader chain from source.
#
# The RG DS is a Rockchip RK3566 (rk356x). This produces the standard split:
#
#   out/uboot.img   U-Boot proper (FIT: u-boot + ATF/BL31 + OP-TEE)  -> 'uboot' part
#   out/trust.img   ATF (BL31) + OP-TEE (BL32), from rkbin           -> 'trust' part
#   out/loader.img  DDR init + SPL, from rkbin                       -> maskrom / loader
#
# U-Boot proper and trust are shared across rk356x and are built the rk3568 way.
# The loader MUST use the rk3566 DDR init (1056 MHz); the rk3568 default
# (1560 MHz) does not match RG DS silicon, so the loader is rebuilt from
# RK3566MINIALL.ini and overrides make.sh's rk3568 loader.
#
# This u-boot carries the RG DS dual-panel parity patches (see rgds/README.md);
# a stock/upstream u-boot lights only one of the two DSI panels and boots blank.
#
# Requirements:
#   - aarch64 GCC cross toolchain (aarch64-linux-gnu-gcc), or set $CROSS_COMPILE.
#   - Rockchip rkbin, as a sibling ../rkbin (make.sh's convention). If it is not
#     present this script clones rockchip-linux/rkbin and pins the known-good
#     commit. Override with $RKBIN to point at an existing checkout.
#
# Usage:
#   rgds/build-uboot.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UDIR="$(cd "$HERE/.." && pwd)"                 # u-boot tree root
OUT="$UDIR/out"

CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
RKBIN_COMMIT="3e288fe"                          # rockchip-linux/rkbin, known-good for this build
RKBIN="${RKBIN:-$UDIR/../rkbin}"                # make.sh expects ../rkbin

log() { printf '>> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v "${CROSS}gcc" >/dev/null || die "aarch64 toolchain not found (${CROSS}gcc); set CROSS_COMPILE"

# ---- ensure rkbin at ../rkbin ----------------------------------------------
if [ ! -d "$RKBIN/RKBOOT" ]; then
  if [ "$RKBIN" = "$UDIR/../rkbin" ]; then
    log "cloning rockchip-linux/rkbin -> $RKBIN (pinned $RKBIN_COMMIT)"
    git clone https://github.com/rockchip-linux/rkbin.git "$RKBIN"
    git -C "$RKBIN" checkout "$RKBIN_COMMIT"
  else
    die "RKBIN=$RKBIN has no RKBOOT/ (not an rkbin checkout)"
  fi
fi
# make.sh looks for ../rkbin relative to the u-boot dir; link it in if needed.
if [ ! -e "$UDIR/../rkbin/RKBOOT" ]; then
  ln -sfn "$RKBIN" "$UDIR/../rkbin"
fi
RKBIN="$(cd "$UDIR/../rkbin" && pwd)"
log "rkbin: $RKBIN ($(git -C "$RKBIN" rev-parse --short HEAD 2>/dev/null || echo '?'))"

mkdir -p "$OUT"

# ---- 1. build u-boot proper + trust (rk3568 target) ------------------------
# make.sh hardcodes a Rockchip prebuilt GCC; force the system toolchain instead.
CC_PREFIX="$(command -v "${CROSS}gcc")"; CC_PREFIX="${CC_PREFIX%gcc}"
log "building u-boot proper + trust (rk3568) with ${CROSS}gcc"
cd "$UDIR"
./make.sh rk3568 CROSS_COMPILE="$CC_PREFIX"

# ---- 2. override the loader with rk3566 DDR (1056 MHz) ----------------------
log "building rk3566 loader (1056 MHz DDR) from RK3566MINIALL.ini"
cd "$RKBIN"
./tools/boot_merger RKBOOT/RK3566MINIALL.ini
RKLOADER="$(ls -t "$RKBIN"/*_loader_*.bin 2>/dev/null | head -1)"
[ -f "$RKLOADER" ] || die "loader build produced no *_loader_*.bin"
cp "$RKLOADER" "$OUT/loader.img"
log "loader: $(basename "$RKLOADER") -> out/loader.img"

# ---- 3. collect the artifacts ----------------------------------------------
for f in uboot.img trust.img; do
  [ -f "$UDIR/$f" ] && cp "$UDIR/$f" "$OUT/" && log "copied $f -> out/$f"
done

cat <<EOF

Done. Bootloader chain in $OUT :

   out/uboot.img    U-Boot proper (FIT)   -> flash to the 'uboot' partition
   out/trust.img    ATF + OP-TEE          -> flash to the 'trust' partition
   out/loader.img   DDR init + SPL        -> maskrom (RKDevTool / rkdeveloptool)

Flash uboot/trust in fastbootd, or the full chain from maskrom. On the RG DS a
bad bootloader recovers only over USB maskrom with Rockchip's tool.
EOF
