# RG DS Plus overclock (CPU 2160 MHz + GPU 900 MHz)

Target matches the shipped RG DS (72ece runs 2160/900). Two independent pieces.

## CPU 1992 -> 2160 MHz  (needs an ATF patch in uboot.img, NOT just DTB)

On RK3568 the CPU armclk PLL is owned by **ATF (BL31) via SCMI** (`clk_scmi_cpu`). The
kernel DT opp and the kernel `clk-rk3568.c` PLL table are *not* authoritative - ATF
clamps armclk to its own two tables. With only a DT `opp-2160000000`, `scaling_available_frequencies`
lists 2160 but `cpuinfo_cur_freq` stays pinned at 1992. rkbin ships BL31 as a prebuilt
blob (no source), so the OC is a deterministic **binary patch of the built FIT**, exactly
as the RG DS does (the RG DS `uboot.img` carries the 2160 entries; ours did not).

Two ATF tables inside the `atf-3` FIT image, and both are duplicated in the +0x200000 mirror
FIT copy. `2160 = 24 MHz * 90` (FBDIV 0x5a), band 0x33. The little-used **312 MHz** step is
replaced (the CPU rate list has no spare slot); **1992 is kept** - this is exactly what the
RG DS OC does:
- SCMI CPU rate list entry `{0x1298be00,0}` (312M) -> `{0x80befc00,0}` (2160M)
- PLL-config entry `{0x1298be00,1,0x4e,6,1,1,0,0}` -> `{0x80befc00,1,0x5a,1,1,1,0,0x33}`
- recompute the `atf-3` sha256 and write it into the hash node (empty RSA sig slot => no re-sign)

This is applied by **`apply_oc_atf.py`** (self-locates the atf-3 data + hash via the FIT/FDT,
so it survives rebuilds; patches both FIT copies). `build-uboot.sh` runs it automatically and
emits `out-plus/uboot_oc.img` alongside the stock `out-plus/uboot.img`. To apply by hand:

    python3 apply_oc_atf.py path/to/uboot.img     # patches in place, writes .bak, verifies with dumpimage -l

DT side (kernel): `arch/arm64/boot/dts/rockchip/rk3568-anbernic-rg-ds-plus.dts`
`&cpu0_opp_table { opp-2160000000 { opp-supported-hw = <0xf9 0xffff>; opp-hz = <2160000000>;
opp-microvolt = <1200000 1200000 1200000>; }; }` (0xf9 = this silicon's PVTM bin; 0x06 hides it).

## GPU 800 -> 900 MHz  (DT-only, ATF already allows <=1200)

`&gpu_opp_table { opp-900000000 { opp-supported-hw = <0xf9 0xffff>; opp-hz = <900000000>;
opp-microvolt = <1050000 1050000 1050000>; }; }`. Only the `0xf9` mask matters (0x06 excluded
our bin, capping GPU at 800). No ATF patch.

## Userspace
`/vendor/bin/setclock_max.sh` and `setclock_stock.sh` are the DYNAMIC variants (they read
`cpuinfo_max_freq` / `available_frequencies`), so they auto-pick 2160/900 - no edit needed.
Only `setclock_powersave.sh` is hardcoded (intentionally capped).

## Flash + verify
Flash `boot.img` (carries the opp-2160/opp-900 dtb) AND `uboot_oc.img` (the OC ATF).
Images are unsigned (vbmeta flags=2, no AVB). Verify on device:
- `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies` includes 2160000
- under load `cpuinfo_cur_freq` reaches 2160000 (not clamped to 1992000)
- `cat /sys/class/devfreq/fde60000.gpu/available_frequencies` includes 900000000

## Voltage note
2160 currently ships at 1200 mV (safe/generous; RG DS ran 2088 at ~1000 mV with an undervolt).
Undervolt can be added later (lower all three `opp-microvolt` fields + every `opp-microvolt-Lx`
bin together, or Rockchip AVS drifts it back up).
