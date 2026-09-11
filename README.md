# AI-HDL Tapeout — sky130A, signed-off GDSII

11 designs, SkyWater sky130A, LibreLane 3.0.5 / OpenROAD. Sign-off September 2026.

| Design | GDSII | DRC | LVS | Metrics |
|---|---|---|---|---|
| slm-soc | [gds.xz](slm-soc/gds/kgubbi_slm_soc.gds.xz) | [0 violations](slm-soc/signoff/drc.magic.rpt) | [clean](slm-soc/signoff/lvs.netgen.rpt) | [metrics](slm-soc/signoff/metrics.json) |
| itims-spi | [gds](itims-spi/gds/tt_um_itims_spi.gds) | [0 violations](itims-spi/signoff/drc.magic.rpt) | [clean](itims-spi/signoff/lvs.netgen.rpt) | [metrics](itims-spi/signoff/metrics.json) |
| necrl-aes128 | [gds](necrl-aes128/gds/tt_um_necrl_aes128.gds) | [0 violations](necrl-aes128/signoff/drc.magic.rpt) | [clean](necrl-aes128/signoff/lvs.netgen.rpt) | [metrics](necrl-aes128/signoff/metrics.json) |
| uofa-traffic | [gds](uofa-traffic/gds/tt_um_uofa_traffic.gds) | [0 violations](uofa-traffic/signoff/drc.magic.rpt) | [clean](uofa-traffic/signoff/lvs.netgen.rpt) | [metrics](uofa-traffic/signoff/metrics.json) |
| uofa-mul-colincore | [gds.xz](uofa-mul-colincore/gds/picorv32_top.gds.xz) | [0 violations](uofa-mul-colincore/signoff/drc.magic.rpt) | [clean](uofa-mul-colincore/signoff/lvs.netgen.rpt) | [metrics](uofa-mul-colincore/signoff/metrics.json) |
| uofa-gpio-gulvady | [gds.xz](uofa-gpio-gulvady/gds/picorv32_top.gds.xz) | [0 violations](uofa-gpio-gulvady/signoff/drc.magic.rpt) | [clean](uofa-gpio-gulvady/signoff/lvs.netgen.rpt) | [metrics](uofa-gpio-gulvady/signoff/metrics.json) |
| uofa-vec-chakravarthy | [gds.xz](uofa-vec-chakravarthy/gds/picorv32_vec_proc_top.gds.xz) | [0 violations](uofa-vec-chakravarthy/signoff/drc.magic.rpt) | [clean](uofa-vec-chakravarthy/signoff/lvs.netgen.rpt) | [metrics](uofa-vec-chakravarthy/signoff/metrics.json) |
| uofa-vec-feng | [gds](uofa-vec-feng/gds/picorv32_vec_all_program_top.gds) | [0 violations](uofa-vec-feng/signoff/drc.magic.rpt) | [clean](uofa-vec-feng/signoff/lvs.netgen.rpt) | [metrics](uofa-vec-feng/signoff/metrics.json) |
| uofa-bmu-palma | [gds](uofa-bmu-palma/gds/toplevel.gds) | [0 violations](uofa-bmu-palma/signoff/drc.magic.rpt) | [clean](uofa-bmu-palma/signoff/lvs.netgen.rpt) | [metrics](uofa-bmu-palma/signoff/metrics.json) |
| uofa-bmi-zane | [gds](uofa-bmi-zane/gds/uofa_bmi_soc.gds) | [0 violations](uofa-bmi-zane/signoff/drc.magic.rpt) | [clean](uofa-bmi-zane/signoff/lvs.netgen.rpt) | [metrics](uofa-bmi-zane/signoff/metrics.json) |
| uofa-bp-rumsey | [gds.xz](uofa-bp-rumsey/gds/picorv32_bp_top.gds.xz) | [0 violations](uofa-bp-rumsey/signoff/drc.magic.rpt) | [clean](uofa-bp-rumsey/signoff/lvs.netgen.rpt) | [metrics](uofa-bp-rumsey/signoff/metrics.json) |

All designs: Magic DRC **0 violations**, Netgen LVS **"Circuits match uniquely"**.
RTL + hardening config under each design's `src/`. Large GDS are xz-compressed
(`xz -dk <file>`). Apache-2.0.

## TinyTapeout-format projects (`tinytapeout/`)

For MPW integration via the ChipFoundry flow, each design is also provided as
a complete [chipdiscover-verilog-template](https://github.com/chipfoundry/chipdiscover-verilog-template)
project under `tinytapeout/`: `tt_um_*` top with the standard TinyTapeout
pinout, completed `info.yaml` (v6, tile size set), datasheet `docs/info.md`,
and cocotb tests in `test/` (all passing locally with the exact commands the
template's `test` workflow runs).

| Project | top_module | tiles |
|---|---|---|
| [tt-uofa-traffic](tinytapeout/tt-uofa-traffic) | tt_um_uofa_traffic | 1x1 |
| [tt-itims-spi](tinytapeout/tt-itims-spi) | tt_um_itims_spi | 2x2 |
| [tt-necrl-aes128](tinytapeout/tt-necrl-aes128) | tt_um_necrl_aes128 | 4x2 |
| [tt-uofa-vec-coproc](tinytapeout/tt-uofa-vec-coproc) | tt_um_vec_coproc | 4x2 |
| [tt-uofa-vec-proc](tinytapeout/tt-uofa-vec-proc) | tt_um_vec_proc | 8x2 |
| [tt-uofa-mul](tinytapeout/tt-uofa-mul) | tt_um_mul_soc | 8x2 |
| [tt-uofa-gpio](tinytapeout/tt-uofa-gpio) | tt_um_gpio_soc | 8x2 |
| [tt-uofa-bp](tinytapeout/tt-uofa-bp) | tt_um_bp_soc | 8x2 |
| [tt-uofa-bmu](tinytapeout/tt-uofa-bmu) | tt_um_bmu_soc | 6x2 |
| [tt-uofa-bmi](tinytapeout/tt-uofa-bmi) | tt_um_bmi_soc | 6x2 |

To submit one for tapeout, create a public repo from the template, copy the
project's contents over it, and enable GitHub Actions (`test` → `gds` →
`precheck` → `gl_test` run on push).

The SLM accelerator SoC is too large for any single tile (~20x an 8x2), so it
was additionally split into six single-block TinyTapeout tiles (RV32IM CPU,
GEMM, softmax, RMSNorm, KV cache, DMA) with each block's native CSR bus port
exposed over a 32-bit SPI register bridge; those tile projects are submitted
separately for MPW integration.
