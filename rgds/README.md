# RG DS u-boot

U-Boot for the Anbernic RG DS (Rockchip RK3566, two independent 640x480 DSI
panels), built entirely from source with full functional parity to the stock
bootloader: both panels light, the CPU 2160 / GPU 900 overclock works, and the
GPT / `/data` are left intact.

Base: `rockchip-linux/u-boot` at commit `32d8dd5e` (the Dec 2025 point the shipped
u-boot was built from), plus the RG DS dual-panel patches on top (commit on the
`main` branch of this repo).

## Why the patches are needed

A plain build of upstream rockchip-linux/u-boot brings up both VOPs and DSI links
but leaves **both panels blank**: the stock u-boot carries Anbernic dual-panel
additions that are absent from upstream. Three changes reproduce them:

1. **`drivers/video/drm/rockchip_display.c`** - skip `rockchip_display_fixup_dts()`.
   That fixup forces every connector onto VOP `endpoint@0` and disables
   `endpoint@1`. The RG DS drives two independent panels (vp0->dsi0, vp1->dsi1),
   so the fixup collapses the second panel. Skipping it preserves the device
   tree's independent dual-DSI routing.

2. **`drivers/video/drm/rockchip_panel.c`** - request and assert a second panel
   enable line, `enable1-gpios`, alongside `enable-gpios`. Upstream ignores it;
   without it the second panel stays dark.

3. **`arch/arm/mach-rockchip/board.c` + `configs/rk3568_defconfig`** - the panel
   power rails are `gpio-leds` (`backlight_0_power` / `backlight_1_power`) with
   `default-state = "on"`, but u-boot has no automatic `default-state` handling.
   Enable `CONFIG_LED` / `CONFIG_LED_GPIO` and probe all LED devices before the
   display initialises, so the rails are powered first (otherwise DSI/VOP come up
   but the panels are unpowered and blank).

The overclock needs no u-boot change: the rkbin BL31 (ATF) already supports the
2160 MHz PLL. The OC lives in the kernel device tree, not here.

## Verified boot disabled + fastboot fix

`configs/rk3568_defconfig` also carries two changes so custom images flash and
boot without friction:

- **AVB / boot-image hash disabled** (`# CONFIG_ANDROID_AVB is not set`,
  `# CONFIG_ANDROID_BOOT_IMAGE_HASH is not set`). Stock u-boot recomputes the
  Android boot-header SHA1 `id` and refuses to boot if it does not match, so a
  re-packed boot image is rejected unless the `id` is written exactly the way
  u-boot recomputes it. Disabling verification lets any locally built boot image
  boot as-is. (The companion kernel repo also patches its boot-image `id` to the
  u-boot-correct value, so its images boot on a stock AVB-on u-boot too.)
- **Fastboot buffer relocated** `0x00c00800` -> `0x20000000`
  (`CONFIG_FASTBOOT_BUF_ADDR`, size `0x08000000`). The default buffer overlaps
  the kernel load region, so `fastboot usb 0` from the u-boot console failed with
  `Sysmem Error: "FASTBOOT" ... alloc is overlap with existence "KERNEL"` after a
  boot attempt. Moving it into free DRAM fixes fastboot.

## Build

```
rgds/build-uboot.sh
```

This builds U-Boot proper + trust the rk3568 way, then overrides the loader with
the **rk3566** DDR init (1056 MHz) - the rk3568 default (1560 MHz) does not match
RG DS silicon. It needs an `aarch64-linux-gnu-` toolchain and Rockchip's `rkbin`;
if `../rkbin` is absent it is cloned and pinned automatically (override with
`$RKBIN`). Output:

```
out/uboot.img    U-Boot proper (FIT)   -> 'uboot' partition
out/trust.img    ATF + OP-TEE          -> 'trust' partition
out/loader.img   DDR init + SPL        -> maskrom (RKDevTool / rkdeveloptool)
```

## Flash

`uboot.img` / `trust.img` flash in fastbootd; the full chain (with `loader.img`)
flashes from USB maskrom. A bad bootloader on the RG DS recovers **only** over USB
maskrom with Rockchip's tool, so keep a known-good `uboot.img` and the stock
firmware handy before flashing.
