# SPDX-License-Identifier: Apache-2.0
# Softmax tile: drive the SPI register bridge, run one softmax over 8 signed
# INT8 inputs, check probabilities against the spec's fixed-point reference
# (p_i = min(127, floor(e_i*255/sum)), e_i = 2^((x_i-max)/16)) within +/-3.
import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CS, SCK, MOSI = 4, 5, 6
MISO = 3


def set_bit(v, b, x):
    return (v | (1 << b)) if x else (v & ~(1 << b))


async def spi_frame(dut, rw, addr, wdata=0):
    """One frame: 32-bit cmd {RW, 2'b10, 13'b0, addr[15:0]}, 32 data bits."""
    v = int(dut.uio_in.value)
    v = set_bit(v, CS, 0)
    v = set_bit(v, SCK, 0)
    dut.uio_in.value = v
    await ClockCycles(dut.clk, 6)
    cmd = (rw << 31) | (0b10 << 29) | (addr & 0xFFFF)
    rd = 0
    for i in range(31, -1, -1):          # command word
        v = set_bit(v, MOSI, (cmd >> i) & 1)
        v = set_bit(v, SCK, 0)
        dut.uio_in.value = v
        await ClockCycles(dut.clk, 4)
        v = set_bit(v, SCK, 1)
        dut.uio_in.value = v
        await ClockCycles(dut.clk, 4)
    await ClockCycles(dut.clk, 8)        # bridge SLB round-trip settle
    for i in range(31, -1, -1):          # data word
        v = set_bit(v, MOSI, (wdata >> i) & 1 if rw else 0)
        v = set_bit(v, SCK, 0)
        dut.uio_in.value = v
        await ClockCycles(dut.clk, 4)
        if not rw:
            rd |= ((int(dut.uio_out.value) >> MISO) & 1) << i
        v = set_bit(v, SCK, 1)
        dut.uio_in.value = v
        await ClockCycles(dut.clk, 4)
    v = set_bit(v, SCK, 0)
    dut.uio_in.value = v
    await ClockCycles(dut.clk, 4)
    v = set_bit(v, CS, 1)
    dut.uio_in.value = v
    await ClockCycles(dut.clk, 10)
    return rd


def golden(xs):
    mx = max(xs)
    es = [2.0 ** ((x - mx) / 16.0) for x in xs]
    sm = sum(es)
    return [min(127, int(255.0 * e / sm)) for e in es]


@cocotb.test()
async def test_softmax_tile(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 40, units="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 1 << CS
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)

    xs = [10, -20, 3, 0, -128, 55, 7, -1]          # signed INT8 inputs
    n = len(xs)

    # scratch at 0x0100 + 4*i, input in [7:0]
    for i, x in enumerate(xs):
        await spi_frame(dut, 1, 0x0100 + 4 * i, x & 0xFF)
    # CFG (0x0008): N in [6:0]
    await spi_frame(dut, 1, 0x0008, n)
    # CTRL (0x0000): clear_done then start
    await spi_frame(dut, 1, 0x0000, 2)
    await spi_frame(dut, 1, 0x0000, 1)

    # poll STATUS (0x0004) bit1 = done
    status = 0
    for _ in range(60):
        status = await spi_frame(dut, 0, 0x0004)
        if status & 2:
            break
    assert status & 2, f"softmax done never set (STATUS={status:#x})"

    ref = golden(xs)
    total = 0
    for i in range(n):
        p = (await spi_frame(dut, 0, 0x0100 + 4 * i)) & 0xFF
        total += p
        assert abs(p - ref[i]) <= 3, f"p[{i}]={p} vs ref {ref[i]} (+/-3)"
    assert total <= 255, f"probability sum {total} exceeds budget"
    dut._log.info(f"softmax OK: probs within +/-3 of reference, sum={total}")
