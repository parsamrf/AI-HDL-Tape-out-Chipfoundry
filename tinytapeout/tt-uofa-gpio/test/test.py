# SPDX-License-Identifier: Apache-2.0
# Boot the GPIO self-test: CPU sets direction, drives 0xA5, reads the input
# byte back through GPIO_IN, and drives the read-back value on the outputs.
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

LOOPBACK = 0x3C


def bit(sig, idx):
    b = sig.value.binstr
    return 1 if b[len(b) - 1 - idx] == "1" else 0


@cocotb.test()
async def test_gpio_selftest(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 40, units="ns")  # 25 MHz signoff clock
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = LOOPBACK  # GPIO input byte, stable before reset release
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    for _ in range(500):
        await ClockCycles(dut.clk, 1)
        if bit(dut.uio_out, 0):
            break
    assert bit(dut.uio_out, 0), "test_done never asserted"
    assert not bit(dut.uio_out, 1), "CPU trapped"

    await ClockCycles(dut.clk, 2)
    got = int(dut.uo_out.value)
    assert got == LOOPBACK, f"GPIO out {got:#04x} != loopback {LOOPBACK:#04x}"
    dut._log.info("full CPU->GPIO->pin->GPIO->CPU loop verified")
