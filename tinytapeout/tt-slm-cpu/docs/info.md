<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This tile is the RV32IM CPU core of a small-language-model (SLM) inference SoC,
packaged as a stand-alone TinyTapeout project. The full SoC is too large for a
single TinyTapeout slot, so it was split into per-block tiles; this one carries
the control processor.

The core is a multi-cycle RV32IM implementation with an iterative
multiply/divide unit, machine-mode CSRs, and a load/store unit that speaks the
SoC's internal SLB request/response bus. For stand-alone operation the tile
wraps the core with:

- an 18-instruction hardwired **boot ROM** on the fetch port, and
- a small **data RAM (32 words) + result-register file** on the SLB data port.

On release from reset the CPU runs a self-test from the ROM:

1. `MUL` — 0x00001234 × 0x00005678 (RV32M multiply)
2. `DIV` — −100 ÷ 7 (signed divide, truncates toward zero → −14)
3. `REM` — −100 rem 7 (sign of dividend → −2)
4. a `SW`/`LW` round-trip through the data RAM

The four 32-bit results are latched into result registers; the final store
asserts `test_done`. Results are then readable a byte at a time on `uo_out`:
`ui_in[3:2]` selects the result (0=MUL, 1=DIV, 2=REM, 3=LW round-trip) and
`ui_in[1:0]` selects the byte lane.

The core's native SLB data port is the same bus used by the accelerator tiles
from this SoC (GEMM, softmax, RMSNorm, KV cache, DMA), so the family could be
reconnected into the original SoC topology if inter-tile wiring is available.

## How to test

1. Apply a 25 MHz clock (any frequency works; the design is fully synchronous)
   and release `rst_n`.
2. Wait for `uio[0]` (`test_done`) to go high — a few hundred cycles, dominated
   by the iterative multiply/divide.
3. Set `ui_in[3:0]` to select result and byte lane; read the byte on `uo_out`.
   Expected: result0 = 0x06260060, result1 = 0xFFFFFFF2, result2 = 0xFFFFFFFE,
   result3 = 0x06260060.

The included cocotb test (`test/test.py`) automates exactly this sequence.

## External hardware

None required. Optionally, LEDs on `uo_out` and `uio[0]`, and DIP switches on
`ui_in[3:0]` to browse the result bytes.
