## How it works

A PicoRV32 CPU with a bit-manipulation instruction unit on the PCPI
co-processor interface (custom-0 opcode, funct7=0, single-cycle response;
unclaimed encodings correctly trap in the CPU). A hardwired boot ROM runs
POPCOUNT, LZCOUNT, BIT-REVERSE and AND-NOT on 0x0F0F00FF (second operand
0x00FF00F0) and latches the results; no firmware load is needed.

Expected: POPCOUNT = 0x10, LZCOUNT = 4, REVERSE = 0xFF00F0F0,
ANDNOT = 0x0F00000F.

## How to test

After reset, wait for test_done (uio[0]); trap (uio[1]) must stay low.
ui[3:2] selects the result word (in the order above), ui[1:0] the byte,
uo[7:0] shows it. The cocotb test in `test/` checks all four words exactly.

## External hardware

None.
