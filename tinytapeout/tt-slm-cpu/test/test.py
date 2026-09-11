# SPDX-License-Identifier: Apache-2.0
# CPU tile: wait for the boot-ROM self-test to finish, then read the four
# 32-bit results a byte at a time through ui_in[3:0] and check them against
# the RV32IM golden values.
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


def bit(sig, idx):
    """X-tolerant single-bit read: only a clean '1' counts as 1."""
    s = sig.value.binstr
    return 1 if s[len(s) - 1 - idx] == "1" else 0


async def read_result(dut, idx):
    word = 0
    for lane in range(4):
        dut.ui_in.value = (idx << 2) | lane
        await ClockCycles(dut.clk, 2)
        word |= (int(dut.uo_out.value) & 0xFF) << (8 * lane)
    return word


@cocotb.test()
async def test_cpu_selftest(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 40, units="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    # boot ROM: 18 instructions incl. iterative MUL/DIV/REM — allow plenty
    done = 0
    for _ in range(400):
        await ClockCycles(dut.clk, 10)
        done = bit(dut.uio_out, 0)
        if done:
            break
    assert done == 1, "test_done never asserted"

    a, b = 0x00001234, 0x00005678
    mul = (a * b) & 0xFFFFFFFF
    div = -(100 // 7)      # RISC-V DIV truncates toward zero: -14
    rem = -100 - div * 7   # RISC-V REM: sign of dividend: -2
    exp = [mul, div & 0xFFFFFFFF, rem & 0xFFFFFFFF, mul]

    names = ["MUL", "DIV", "REM", "LW round-trip"]
    for i in range(4):
        got = await read_result(dut, i)
        assert got == exp[i], f"{names[i]}: got {got:#010x}, expected {exp[i]:#010x}"
        dut._log.info(f"{names[i]} = {got:#010x} OK")
