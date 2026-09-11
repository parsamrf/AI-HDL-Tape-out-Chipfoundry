# SPDX-License-Identifier: Apache-2.0
# Boot the hardwired multiplier self-test; read all three results byte-by-byte.
#
# Expected values (computed by hand from the ROM program):
#   MUL1: 0x1234 * 0x5678       = 0x06260060
#   MUL2: 0xFFFFFFFF * 2        = 0x1_FFFF_FFFE -> low word 0xFFFFFFFE
#   SRAM: MUL1 written to and read back from RAM word 0 = 0x06260060
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

EXPECTED = {0: 0x06260060, 1: 0xFFFFFFFE, 2: 0x06260060}


async def read_word(dut, res_sel):
    val = 0
    for byte in range(4):
        dut.ui_in.value = (res_sel << 2) | byte
        await ClockCycles(dut.clk, 2)
        val |= int(dut.uo_out.value) << (8 * byte)
    return val


@cocotb.test()
async def test_mul_selftest(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 40, units="ns")  # 25 MHz signoff clock
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    # Each MUL takes ~35 cycles in the shift-and-add unit; 2000 cycles is
    # ample headroom for the whole ROM program.
    for _ in range(2000):
        await ClockCycles(dut.clk, 1)
        if int(dut.uio_out.value) & 1:
            break
    assert int(dut.uio_out.value) & 1, "test_done never asserted"
    assert not (int(dut.uio_out.value) >> 1) & 1, "CPU trapped"

    for sel, exp in EXPECTED.items():
        got = await read_word(dut, sel)
        assert got == exp, f"result {sel}: {got:#010x} != {exp:#010x}"

    dut._log.info("all three results correct (both MULs and SRAM round-trip)")
