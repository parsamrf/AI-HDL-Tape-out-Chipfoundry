<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This tile is the INT8 GEMM engine of a small-language-model (SLM) inference
SoC, packaged as a stand-alone TinyTapeout project. The full SoC is too large
for a single TinyTapeout slot, so it was split into per-block tiles.

> **Area note:** this project is simulation-complete and its cocotb suite
> passes, but the 64-PE systolic array synthesizes to ~0.44 mm² of sky130 HD
> standard cells — ~1.5x the largest TinyTapeout tile — so it cannot harden
> into a standard slot and needs a custom placement or a future run.

The engine computes `R[m][n] = requant(sum_k A[m][k] * W[k][n])` on an 8×8
weight-stationary systolic array: A is M×8 signed INT8 (M = 1..16 in this
tile build — the SoC block supports up to 64; the activation/result buffers
are depth-reduced to fit the tile budget), W is 8×8
signed INT8, accumulation is INT32, and results are requantized to INT8
through a multiply/arithmetic-shift/zero-point stage
(`sat8(((acc*SCALE) >>> SHIFT) + ZP)`).

The block's own CSR interface (its SLB bus slave port) is exposed through a
32-bit SPI register bridge, so a host can drive the identical register map the
SoC's CPU uses. One SPI frame is a 32-bit command `{RW, 2'b10, 13'b0,
addr[15:0]}` followed by 32 data bits, MSB first.

Register map (all offsets SPI addresses):

| Offset | Register | Notes |
|--------|----------|-------|
| 0x0000 | CTRL     | W: b0 start, b1 clear_done |
| 0x0004 | STATUS   | R: b0 busy, b1 done (sticky) |
| 0x0008 | CFG      | b0 src_sel (keep 0 = local buffer), b1 irq_en |
| 0x000C | DIMS     | [6:0] M |
| 0x0010 | SCALE    | signed 32-bit requant multiplier |
| 0x0014 | SHIFT    | [4:0] arithmetic right shift |
| 0x0018 | ZP       | signed 8-bit zero point |
| 0x0100–0x013C | weight buffer | 16 words, word i byte j = W[f/8][f%8], f = 4i+j |
| 0x0200–0x027C | activation buffer | 32 words; row m in words {2m, 2m+1} |
| 0x0400–0x047C | result buffer | 32 words; same packing as activations |

The KV-cache read port used by `CFG.src_sel = 1` in the full SoC is tied off
to a zero-data responder in this tile, so no register setting can hang the
engine. The SLB port itself could be bus-connected if inter-tile wiring is
available.

## How to test

1. Apply clock (25 MHz nominal; the SPI bridge samples with the system clock,
   so keep SCK below clk/8) and release `rst_n` with CS_n high.
2. Write the 16 weight words and 2·M activation words, then DIMS, SCALE,
   SHIFT, ZP, and CFG (set b1 for irq).
3. Write CTRL = 2 (clear), then CTRL = 1 (start).
4. Poll STATUS until bit 1 (done); read the M result rows at 0x0400.

The included cocotb test (`test/test.py`) runs a 2×8 · 8×8 GEMM with mixed
signs and saturation and checks all 16 outputs bit-exactly against a Python
golden model.

## External hardware

An SPI master (any MCU, or a Raspberry Pi's SPI pins) connected to
uio[4]=CS_n, uio[5]=SCK, uio[6]=MOSI, uio[3]=MISO. Optionally an LED/scope on
uio[0] (irq).
