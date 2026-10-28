# Video codec (VSP) and JPEG: what the stock dump shows

From `tools/dump-stock-codec.sh` run on the stock Android 5.4 system (Infinix X6525).

## The hardware
| Block | MMIO | Interrupt (hwirq) | Stock node |
|-------|------|-------------------|------------|
| Video codec (VSP) | `0x32000000`, 0xc000 | 66 (SPI 34) | `video-codec@32000000`, misc device `/dev/sprd_vsp` |
| JPEG codec | `0x36000000`, 0xc000 | 74 (SPI 42) | `jpg-codec@36000000`, `/dev/sprd_jpg` |

The VSP has its own Unisoc IOMMU (`sprd,iommuvaul6-vsp`) and a DVFS devfreq (`vsp-dvfs`).
Mainline already has the pieces around it: `CLK_VSP`, `CLK_VSP_EB`, `CLK_JPG`,
`UMS9230_POWER_DOMAIN_AP_VSP` and the VSP/JPG resets. It has no DT node and no driver.

## How the stock stack works
- The kernel side (`vsp.ko`, `jpg.ko`, `sprd-vsp-pw-domain.ko`) is thin: power and clock
  gating (`clk_vsp`, `clk_ahb_vsp`, `clk_emc_vsp`, `clk_mm_eb`, `clk_axi_gate_vsp`,
  `clk_ahb_gate_vsp_eb`, `clk_vsp_ahb_mmu_eb`, `clk_vsp_mq_ahb_eb`, parents 76.8/128/153.6/
  192/307.2/384 MHz), a `vsp-dev-eb-syscon` enable register, dma-buf to IOVA mapping, a
  frequency level, and ioctls `VSP_ACQUAIRE/RELEASE/ENABLE/DISABLE/RESET/COMPLETE/HW_INFO/
  GET_FREQ/GET_IOVA/FREE_IOVA/SET_SCENE_MODE`. `VSP_COMPLETE` sleeps until the interrupt.
- The decoding is driven from **userspace**. `libomx_avcdec_hw_sprd.so` (and the hevc, vp9,
  vpx, m4v/h263 decoders, plus avc/hevc encoders) contain `H264Dec_ProcessSPS`,
  `H264Dec_Process_slice`, the DPB and reference-list code and `H264Dec_cfg_bsm`: they parse
  the headers, manage the DPB and write the VSP registers directly through an mmap, then wait
  on the interrupt. Only these libraries know the register map.

## What that means for mainline
That split is the shape of a V4L2 *stateless* decoder: userspace (ffmpeg/GStreamer) already
parses SPS/PPS/slices and hands the driver parsed controls; the driver programs the engine.
So a native driver is realistic, but the register-level programming has to be reverse
engineered from those libraries (no documentation), codec by codec, starting with H.264.

Stages:
1. DT node (`reg`, SPI 34, clocks, power domain, resets, `vsp-dev-eb-syscon`, IOMMU) and a
   bring-up driver that powers the block and reads its version (`GET_HW_MINOR_Version`).
   Needs the stock device tree: re-run `tools/dump-stock-codec.sh`, it now saves `stock.dtb`.
2. A Unisoc IOMMU (VAU) driver or a contiguous-memory fallback for the buffers.
3. Register map for H.264 decode from `libomx_avcdec_hw_sprd.so`, then a stateless V4L2 driver.
4. HEVC and VP9 the same way; JPEG and the encoders last.

An alternative that needs no register work is a compatibility `/dev/sprd_vsp` driver plus the
stock libraries under Waydroid, but that does not give native Linux players hardware decode
and means shipping the vendor blobs.
