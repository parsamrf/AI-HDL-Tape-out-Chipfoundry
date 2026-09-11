## How it works

A PicoRV32 CPU with a multicycle SIMD vector processor (custom-0 opcode,
funct7=1) supporting lane-wise add/saturating-add/multiply and a 4x8-bit
dot product. A hardwired boot ROM runs a self-test: VADD8, VSADD8
(saturation proven with 0xF0F0F0F0), VMUL8, VDOT8, plus a store/load
round-trip through the on-tile RAM; five 32-bit results are latched.

Expected: VADD8=0x06080A0C, VSADD8=0xFFFFFFFF, VMUL8=0x050C1520,
VDOT8=0x00000046, SRAM=0x06080A0C.

## How to test

After reset, wait for test_done (uio[0]); trap (uio[1]) must stay low.
ui[4:2] selects the result word (0-4 as above), ui[1:0] the byte, uo shows
it. The cocotb test in `test/` checks all five words exactly.

## External hardware

None.
