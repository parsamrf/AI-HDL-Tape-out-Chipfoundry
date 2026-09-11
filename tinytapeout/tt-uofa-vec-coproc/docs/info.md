## How it works

A PicoRV32 CPU with a single-cycle SIMD vector co-processor on the PCPI
interface, running a hardwired boot program that executes VADD8, VSUB8,
VAND and VOR on two packed 4x8-bit operands (0x01020304, 0x05060708) and
latches the four 32-bit results. The chip is fully self-contained: no
firmware load is needed.

Expected results: VADD8=0x06080A0C, VSUB8=0x04040404, VAND=0x01020300,
VOR=0x0506070C.

## How to test

After reset, wait for test_done (uio[0]); trap (uio[1]) must stay low. Then
read any byte of any result: ui[3:2] selects the result word, ui[1:0]
selects the byte, uo[7:0] shows it. The cocotb test in `test/` does exactly
this and checks all 16 bytes.

## External hardware

None.
