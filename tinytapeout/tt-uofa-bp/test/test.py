# SPDX-License-Identifier: Apache-2.0
# Boot the hardwired counted-loop self-test; read the results byte-by-byte.
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# result select -> expected value (result 2 is the timing-dependent
# predictor-taken cycle count and is bounded instead of exact-matched)
EXP_LOOP_COUNT = 0x00000008  # result 0: x1 after 8 loop iterations
EXP_SANITY     = 0x600D600D  # result 1: sanity constant
EXP_ROUNDTRIP  = 0x600D6015  # result 3: SW/LW round-trip of 8 + 0x600D600D

MAX_WAIT_CYCLES = 2000
RESET_CYCLES = 10


def bit(dut_sig, idx):
    """X-tolerant bit read: returns 1 only for a clean '1' (GL-sim safe)."""
    b = dut_sig.value.binstr
    return 1 if b[len(b) - 1 - idx] == "1" else 0



async def read_word(dut, res_sel):
    val = 0
    for byte in range(4):
        dut.ui_in.value = (res_sel << 2) | byte
        await ClockCycles(dut.clk, 2)
        val |= int(dut.uo_out.value) << (8 * byte)
    return val


@cocotb.test()
async def test_bp_selftest(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 40, units="ns")  # 25 MHz signoff clock
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, RESET_CYCLES)
    dut.rst_n.value = 1

    waited = 0
    for _ in range(MAX_WAIT_CYCLES):
        await ClockCycles(dut.clk, 1)
        waited += 1
        if bit(dut.uio_out, 0):
            break
    assert bit(dut.uio_out, 0), "test_done never asserted"
    assert not bit(dut.uio_out, 1), "CPU trapped"
    total_cycles = RESET_CYCLES + waited

    got0 = await read_word(dut, 0)
    assert got0 == EXP_LOOP_COUNT, f"result 0: {got0:#010x} != {EXP_LOOP_COUNT:#010x}"

    got1 = await read_word(dut, 1)
    assert got1 == EXP_SANITY, f"result 1: {got1:#010x} != {EXP_SANITY:#010x}"

    got3 = await read_word(dut, 3)
    assert got3 == EXP_ROUNDTRIP, f"result 3: {got3:#010x} != {EXP_ROUNDTRIP:#010x}"

    # result 2: cycles where the neural BHT predicted "taken" while the
    # self-test ran. Exact value is timing-dependent; the counter only runs
    # between reset release and test_done, so bound it instead.
    got2 = await read_word(dut, 2)
    assert got2 != 0, "predictor-taken cycle count is zero"
    assert got2 < total_cycles, (
        f"predictor count {got2} not < total run cycles {total_cycles}"
    )

    dut._log.info(
        f"loop count, sanity constant, RAM round-trip correct; "
        f"predictor-taken cycles = {got2} (bounded by {total_cycles})"
    )
