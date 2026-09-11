## How it works

A PicoRV32 CPU with a bit-manipulation unit (BMU) on the PCPI co-processor
interface, exposing custom-0 instructions for leading-zero count,
trailing-zero count, bit reverse, and population count. A hardwired boot ROM
runs all four ops on 0x00F0F0F0 and latches the results; no firmware load is
needed.

Expected: LZC = 8, TZC = 4, REV = 0x0F0F0F00, POPCOUNT = 12.

## How to test

After reset, wait for test_done (uio[0]); trap (uio[1]) must stay low.
ui[3:2] selects the result word (in the order above), ui[1:0] the byte,
uo[7:0] shows it. The cocotb test in `test/` checks all four words exactly.

## External hardware

None.
