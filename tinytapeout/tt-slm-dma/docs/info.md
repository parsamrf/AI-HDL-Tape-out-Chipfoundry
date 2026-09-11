<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This tile is the DMA engine of a small-language-model (SLM) inference SoC,
packaged as a stand-alone TinyTapeout project. The full SoC is too large for
a single TinyTapeout slot, so it was split into per-block tiles.

The engine is a descriptor-chained single-channel word copier. A descriptor
is 4 consecutive words — src, dst, len (bytes, multiple of 4), and
next_flags (b0 = next descriptor valid, b1 = raise done at chain stop; upper
bits = next descriptor address). `CTRL.start` latches DESC_PTR; the engine
fetches the descriptor over its SLB master port, copies word by word with one
outstanding transaction, and follows the chain. Misaligned src/dst/len or
DESC_PTR set the sticky `STATUS.err`. `done` and `err` clear via
`CTRL.clear`; `irq = done & irq_en`.

So the full descriptor-fetch/copy/chain path is exercisable stand-alone, the
tile pairs the engine with a 64-word scratch RAM that both the engine's SLB
master port and the SPI register bridge can reach:

- SPI 0x0000–0x000F: DMA CSRs — CTRL (0x00), STATUS (0x04, b0 busy / b1
  done / b2 err), DESC_PTR (0x08), CFG (0x0C, b0 irq_en)
- SPI 0x1000–0x10FF: the scratch RAM (the DMA master sees the same 64 words
  at any address, index = addr[7:2], so pointer values like 0x0000_10xx
  address it naturally)

The DMA master has RAM priority; the bridge holds its request during
arbitration, so the two can never deadlock. Both SLB ports could be
bus-connected if inter-tile wiring is available.

## How to test

1. Apply clock (25 MHz nominal; keep SCK below clk/8) and release `rst_n`
   with CS_n high.
2. SPI-write one or more chained descriptors and payload words into the
   scratch RAM window, set CFG.irq_en, write DESC_PTR, then CTRL = 1.
3. Poll STATUS until bit 1 (done) — or watch uio[0] (irq) — and read the
   copied words back through the RAM window.

The included cocotb test (`test/test.py`) runs a two-descriptor chained copy
and checks it word-exactly, verifies the irq pin, and confirms the error
path by starting with a misaligned DESC_PTR.

## External hardware

An SPI master (any MCU, or a Raspberry Pi's SPI pins) connected to
uio[4]=CS_n, uio[5]=SCK, uio[6]=MOSI, uio[3]=MISO. Optionally an LED/scope on
uio[0] (irq).
