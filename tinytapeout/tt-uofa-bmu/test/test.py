# SPDX-License-Identifier: Apache-2.0
# Boot the hardwired BMU self-test; read all four results byte-by-byte.
#
# The ROM builds x1 = 0x00F0F0F0 and runs the four custom-0 BMU ops on it:
#   LZC: highest set bit is bit 23 -> 31-23 = 8
#   TZC: lowest set bit is bit 4  -> 4
#   REV: bit k -> bit 31-k        -> 0x0F0F0F00
#   POP: 12 bits set              -> 12
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

EXPECTED = {0: 0x00000008, 1: 0x00000004, 2: 0x0F0F0F00, 3: 0x0000000C}


async def read_word(dut, res_sel):
    val = 0
    for byte in range(4):
        dut.ui_in.value = (res_sel << 2) | byte
        await ClockCycles(dut.clk, 2)
        val |= int(dut.uo_out.value) << (8 * byte)
    return val


@cocotb.test()
async def test_bmu_selftest(dut):
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

    dut._log.info("all four BMU results correct (LZC/TZC/REV/POPCOUNT)")
