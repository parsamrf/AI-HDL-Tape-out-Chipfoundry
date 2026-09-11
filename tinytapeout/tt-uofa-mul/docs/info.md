## How it works

A PicoRV32 CPU with an external shift-and-add hardware multiplier attached
over the PCPI co-processor interface (exact RV32M MUL decode; ~35 cycles per
multiply). A hardwired boot ROM runs a self-test: 0x1234 x 0x5678, an
overflow case 0xFFFFFFFF x 2 (checks low-word truncation), and a store/load
round-trip through the on-tile 128-byte RAM. Three 32-bit results are
latched; no firmware load is needed.

Expected: MUL1 = 0x06260060, MUL2 = 0xFFFFFFFE, SRAM = 0x06260060.

## How to test

After reset, wait for test_done (uio[0]); trap (uio[1]) must stay low.
ui[3:2] selects the result word (0=MUL1, 1=MUL2, 2=SRAM), ui[1:0] the byte,
uo[7:0] shows it. The cocotb test in `test/` checks all three words exactly.

## External hardware

None.
