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

## Step 1 result: what the stock device tree says (and what is in the kernel now)
From `stock.dtb` (`video-codec@32000000`): registers `0x32000000` (0xc000), SPI 34, clocks
`clk_ahb_gate_vsp_eb` (AP AHB gate 2 = mainline `CLK_VSP_EB`) and `clk_vsp` (AP clock 28 = `CLK_VSP`,
a mux of the TWPLL 256 / 307.2 / 384 MHz outputs, as `vsp_parents` already has), resets
`0x2800` of AP AHB offset 4 (bits 11 and 13 = `RESET_AP_AHB_VSP_GLOBAL_SOFT_RST` and
`RESET_AP_AHB_VSP_SOFT_RST`), power domain `vsp-power-domain` (PMU `0x314`, force shutdown bit 25,
auto shutdown bit 24: the same layout as the MM domain at `0x2e8`). The stock DVFS table runs the
VSP at 256 MHz idle and 384 MHz at work. The VSP's IOMMU (`sprd,iommuvaul6-vsp`, iova `0x20000000`
+ 256 MiB) shares the first 0x80 bytes of the register window; the JPEG codec
(`0x36000000`, SPI 42, resets in MM AHB, power domain MM) has the same shape.

Patches 0038-0040: the AP_VSP power domain, the `video-codec@32000000` node, and `sprd-vsp.ko`
(`CONFIG_VIDEO_SPRD_VSP=m`, not loaded automatically), which powers the block (MM + VSP domains),
enables the clocks, releases the resets and dumps the first 0x200 bytes of registers:

    sudo modprobe sprd-vsp
    sudo cat /sys/kernel/debug/sprd-vsp/regs
    sudo dmesg | grep -i vsp

Send that output: the registers will show whether the block answers (a hang on `cat` or a bus
error means a missing power/clock/reset step) and which words look like version/status registers,
which is where the register-map work starts.

## Steps 2-3: what the stock AVC library shows so far (analysis only, no driver code yet)
`libomx_avcdec_hw_sprd.so` is stripped but exports ~150 symbols (`ARM_VSP_RST`, `VSP_CHECK_DDR_BUS_IDLE`,
`VSP_POLL_COMPLETE`, `H264Dec_cfg_bsm`, `print_debug_register_all`...). Registers reached through
`0x6120xxxx` constants (`tools/vsp-reg-scan.py`; subtract `0x61200000`, add to the `0x32000000` window):

| Offset | Seen in | What it looks like |
|--------|---------|--------------------|
| `0x1010` | `ARM_VSP_RST`, `H264DecDecode` | reset: written `0xd0` |
| `0x101c` | `VSP_CHECK_DDR_BUS_IDLE` | polled with mask `0x101` (AXI master idle) |
| `0x1004`, `0x100c`, `0x1020` | `VSP_DMA_TRANSFER` | DMA (table upload) |
| `0x1028` | `H264DecDecode_NALU` x4, debug dump | interrupt raw/status ("int_raw") |
| `0x1034` | `H264Dec_cfg_bsm` | bitstream-module configuration |
| `0x1400` | `H264Dec_Cfg_ScalingMatix` | scaling-list upload |
| `0x1800` | `init_contexts` | CABAC context init tables |
| `0x8000-0x8024` | `H264Dec_cfg_bsm`, `read_bits`, `ue_v`, `se_v`, `long_ue_v`, start-code search | the **bitstream module**: the library reads SPS/PPS/slice-header bits (`ue_v`, `se_v`) *through the hardware*, not from memory |

The last row matters for the design: header parsing in the stock stack goes through a hardware
bit-reader, so a V4L2 stateless driver (which receives already-parsed controls) must feed the same
bitstream to the module and load the parsed values into the decode registers itself. Only ~22 offsets
come out of the constant scan; the per-macroblock and reference-frame registers are addressed
through base-plus-immediate and need the disassembly read function by function
(`H264Dec_Process_slice`, `H264DecDecode_NALU`, `H264Dec_init_picture`).

The IOMMU side (step 2): `VSP_CHECK_MMU_STATUS` reads eight status registers whose offsets come from a
structure filled by the kernel module, so the MMU (`sprd,iommuvaul6-vsp`, first 0x80 bytes of the window)
layout is in `vsp.ko`, not the library. Until it is mapped, buffers have to be physically contiguous
(CMA) with the MMU left in bypass, which is the fallback the stock library itself has (`cfg_vaor_bypass_en`).

Honest status: steps 2-3 cannot be finished from the dumps alone. They need (a) the `regs` dump from
step 1 to confirm the block answers and to calibrate which offsets are real, then (b) a long,
function-by-function read of the library plus experiments on the phone (feed a known I-frame, compare
the output against ffmpeg). That is weeks of work, not a single patch.

## Step 4 (started ahead of 2-3): the JPEG codec bring-up
Steps 2-3 are paused until the step 1 dump exists. Step 4's other parts (HEVC, VP9, the encoders)
all need the register map of step 3, so they cannot start. The JPEG codec can: it is a separate
block with its own small register window, and the stock device tree describes it completely.
Patches 0041-0042 make `sprd-vsp.ko` bind `sprd,ums9230-jpg` as well (clocks and resets come from
the DT now) and add `jpeg-codec@36000000`: SPI 42, clocks `CLK_MM_CKG_EB`, `CLK_MM_JPG_EB`, `CLK_JPG`
(parent: 256 MHz TWPLL), reset `RESET_MM_AHB_JPG_SOFT_RST_MASK` (the stock mask `0x80000` = bit 19),
MM power domain. `/sys/kernel/debug/sprd-jpg/regs` dumps it; see `VSP_TESTS.md`, test 4b.
Baseline JPEG decode is far simpler than H.264 (no reference frames, no CABAC), so it is the
best first block to get real work out of. The stock `libjpeg`-side library is next to read.
