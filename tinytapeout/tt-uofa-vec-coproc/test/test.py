# SPDX-License-Identifier: Apache-2.0
# Boot the hardwired vector self-test, then read all four results byte-by-byte.
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

EXPECTED = {0: 0x06080A0C, 1: 0x04040404, 2: 0x01020300, 3: 0x0506070C}


async def read_word(dut, res_sel):
    val = 0
    for byte in range(4):
        dut.ui_in.value = (res_sel << 2) | byte
        await ClockCycles(dut.clk, 2)
        val |= int(dut.uo_out.value) << (8 * byte)
    return val


@cocotb.test()
async def test_vector_selftest(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 40, units="ns")  # 25 MHz signoff clock
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    # wait for test_done (uio_out[0]); ROM program takes ~100 cycles
    for _ in range(500):
        await ClockCycles(dut.clk, 1)
        if int(dut.uio_out.value) & 1:
            break
    assert int(dut.uio_out.value) & 1, "test_done never asserted"
    assert not (int(dut.uio_out.value) >> 1) & 1, "CPU trapped"

    for sel, exp in EXPECTED.items():
        got = await read_word(dut, sel)
        assert got == exp, f"result {sel}: {got:#010x} != {exp:#010x}"

    dut._log.info("all four vector results correct")
