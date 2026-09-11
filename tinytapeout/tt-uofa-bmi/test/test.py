# SPDX-License-Identifier: Apache-2.0
# Boot the hardwired BMI self-test; read all four results byte-by-byte.
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# result_sel -> expected value (hand-computed from bmi_unit.v for
# x1 = 0x0F0F00FF, x2 = 0x00FF00F0):
#   0 POPCOUNT(x1) = 16 one bits           -> 0x00000010
#   1 LZCOUNT(x1)  = 4 leading zeros       -> 0x00000004
#   2 REVERSE(x1)                          -> 0xFF00F0F0
#   3 ANDNOT: x1 & ~x2 = 0x0F0F00FF & 0xFF00FF0F -> 0x0F00000F
EXPECTED = {0: 0x00000010, 1: 0x00000004, 2: 0xFF00F0F0, 3: 0x0F00000F}


async def read_word(dut, res_sel):
    val = 0
    for byte in range(4):
        dut.ui_in.value = (res_sel << 2) | byte
        await ClockCycles(dut.clk, 2)
        val |= int(dut.uo_out.value) << (8 * byte)
    return val


@cocotb.test()
async def test_bmi_selftest(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 40, units="ns")  # 25 MHz signoff clock
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    for _ in range(2000):
        await ClockCycles(dut.clk, 1)
        if int(dut.uio_out.value) & 1:
            break
    assert int(dut.uio_out.value) & 1, "test_done never asserted"
    assert not (int(dut.uio_out.value) >> 1) & 1, "CPU trapped"

    for sel, exp in EXPECTED.items():
        got = await read_word(dut, sel)
        assert got == exp, f"result {sel}: {got:#010x} != {exp:#010x}"

    dut._log.info("all four BMI results correct")
