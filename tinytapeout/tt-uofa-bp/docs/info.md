## How it works

A PicoRV32 CPU with a perceptron neural branch-history table (BHT) trained
from the CPU's live trace port. A hardwired boot ROM runs a counted loop
(eight taken branches), does a store/load round-trip through the on-tile
RAM, and latches results; the BHT's live prediction is brought out on a pin
and the number of predicted-taken cycles during the run is captured as a
result word. No firmware load is needed.

Expected: loop count = 8, sanity word = 0x600D600D, RAM round-trip =
0x600D6015; predictor-taken count is timing-dependent (bounded, nonzero).

## How to test

After reset, wait for test_done (uio[0]); trap (uio[1]) must stay low;
uio[2] shows the live prediction. ui[3:2] selects the result word, ui[1:0]
the byte, uo[7:0] shows it. The cocotb test in `test/` checks the exact
words and bounds the predictor count.

## External hardware

None.
