# SPDX-License-Identifier: Apache-2.0
# SPI write/readback round-trip through the harness bridge.
# Frame (mode 0, one command per CS frame):
#   7 bits: RW (1=write), addr[5:0] MSB-first, then 32 data bits MSB-first.
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CS, SCK, MOSI = 4, 5, 6  # uio_in bits
MISO = 3                 # uio_out bit


def set_bit(val, bit, b):
    return (val | (1 << bit)) if b else (val & ~(1 << bit))


async def spi_cmd(dut, rw, addr, wdata=0):
    """One command frame; returns read data for rw=0."""
    v = int(dut.uio_in.value)
    v = set_bit(v, CS, 0)
    v = set_bit(v, SCK, 0)
    dut.uio_in.value = v
    await ClockCycles(dut.clk, 8)
    rd = 0
    bits = [(rw, None)] + [((addr >> i) & 1, None) for i in range(5, -1, -1)]
    bits += [((wdata >> i) & 1 if rw else 0, i) for i in range(31, -1, -1)]
    for b, ridx in bits:
        v = set_bit(v, MOSI, b)
        v = set_bit(v, SCK, 0)
        dut.uio_in.value = v
        await ClockCycles(dut.clk, 8)
        if not rw and ridx is not None:
            rd |= (int(dut.uio_out.value) >> MISO & 1) << ridx
        v = set_bit(v, SCK, 1)
        dut.uio_in.value = v
        await ClockCycles(dut.clk, 8)
    v = set_bit(v, SCK, 0)
    dut.uio_in.value = v
    await ClockCycles(dut.clk, 8)
    v = set_bit(v, CS, 1)
    dut.uio_in.value = v
    await ClockCycles(dut.clk, 16)
    return rd


@cocotb.test()
async def test_spi_readback(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 28, units="ns")  # 35.7 MHz signoff clock
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 1 << CS  # CS idle high, SCK low
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)

    # REG_CTRL (addr 0x00): write 1, read back 1; write 0, read back 0
    await spi_cmd(dut, 1, 0x00, 1)
    assert await spi_cmd(dut, 0, 0x00) == 1, "CTRL readback != 1"
    await spi_cmd(dut, 1, 0x00, 0)
    assert await spi_cmd(dut, 0, 0x00) == 0, "CTRL readback != 0"

    # REG_THRESHOLD (addr 0x0C) has a nonzero reset value
    thr = await spi_cmd(dut, 0, 0x0C)
    assert thr != 0, "THRESHOLD reset value must be nonzero"
    dut._log.info(f"SPI readback OK (THRESHOLD reset = {thr:#x})")
