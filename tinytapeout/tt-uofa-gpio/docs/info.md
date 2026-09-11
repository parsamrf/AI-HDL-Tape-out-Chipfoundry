## How it works

A PicoRV32 CPU with a memory-mapped 32-bit GPIO block (per-pin direction,
byte write strobes, synchronized inputs). A hardwired boot ROM runs a
self-test: set the low byte to output, drive 0xA5, read the GPIO input port
(whose upper input byte comes from the chip's ui pins), and drive the
read-back value onto the outputs — proving the whole CPU-to-pin-and-back
chain with one end check. No firmware load is needed.

## How to test

Drive any byte on ui[7:0] before releasing reset. After reset, wait for
test_done (uio[0]); trap (uio[1]) must stay low; uo[7:0] must equal the
byte you drove. The cocotb test in `test/` does exactly this with 0x3C.

## External hardware

None; LEDs on uo[7:0] make the patterns visible.
