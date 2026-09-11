<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This tile is the banked KV-cache controller of a small-language-model (SLM)
inference SoC, packaged as a stand-alone TinyTapeout project. The full SoC is
too large for a single TinyTapeout slot, so it was split into per-block
tiles.

The controller word-interleaves four single-port RAM banks (bank select =
addr[3:2]) behind a two-requestor arbiter: an SLB read/write port (the SoC
CPU's port) and a read-only port for the GEMM engine, with fixed SLB-first
priority per bank. Each port runs a registered IDLE → GRANT → RESP flow, so
`req_ready`/`rsp_valid` are pure functions of registered state — no
combinational valid/ready loops, and the design is deadlock- and
starvation-free by construction.

In this tile the banks are shrunk to 16 words each (256 B total; the
controller is parametric and otherwise unchanged) and the GEMM port is tied
off. The SLB port is exposed through a 32-bit SPI register bridge: the whole
KV space reads and writes like memory at SPI addresses 0x0000–0x00FF, and
addresses above the space alias back onto it. Both SLB ports could be
bus-connected if inter-tile wiring is available.

## How to test

1. Apply clock (25 MHz nominal; keep SCK below clk/8) and release `rst_n`
   with CS_n high.
2. SPI-write words anywhere in 0x0000–0x00FC and read them back. Consecutive
   word addresses land in different physical banks.

The included cocotb test (`test/test.py`) writes word 0 and word 15 of every
bank plus mid-range words, reads everything back, verifies the aliasing
above the 256 B space, and checks bank isolation on overwrite.

## External hardware

An SPI master (any MCU, or a Raspberry Pi's SPI pins) connected to
uio[4]=CS_n, uio[5]=SCK, uio[6]=MOSI, uio[3]=MISO.
