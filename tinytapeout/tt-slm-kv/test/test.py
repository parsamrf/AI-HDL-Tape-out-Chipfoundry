# SPDX-License-Identifier: Apache-2.0
# KV-cache tile: write/read words through the SPI register bridge, hitting
# all four interleaved banks (bank = addr[3:2]), the last word of each bank,
# and the address-aliasing behavior above the 1 KiB space.
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


@cocotb.test()
async def test_kv_tile(dut):
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

    # word 0 of each bank, word 15 of each bank, and two mid-range words
    # (BANK_WORDS = 16: bank = addr[3:2], in-bank word = addr[7:4])
    patterns = {
        0x0000: 0xDEADBEEF,   # bank 0, word 0
        0x0004: 0x11223344,   # bank 1, word 0
        0x0008: 0xA5A5A5A5,   # bank 2, word 0
        0x000C: 0x0F0F0F0F,   # bank 3, word 0
        0x00F0: 0xCAFEBABE,   # bank 0, word 15 (last word of the space)
        0x00FC: 0x87654321,   # bank 3, word 15
        0x0054: 0x13579BDF,   # bank 1, mid
        0x00A8: 0x2468ACE0,   # bank 2, mid
    }
    for a, d in patterns.items():
        await spi_frame(dut, 1, a, d)
    for a, d in patterns.items():
        got = await spi_frame(dut, 0, a)
        assert got == d, f"KV[{a:#06x}]: got {got:#010x}, expected {d:#010x}"

    # addresses above AW+3 alias: 0x0100 lands on the same word as 0x0000
    got = await spi_frame(dut, 0, 0x0100)
    assert got == patterns[0x0000], f"alias 0x0100: got {got:#010x}"

    # overwrite one word, confirm neighbors in other banks are untouched
    await spi_frame(dut, 1, 0x0004, 0x55AA55AA)
    assert (await spi_frame(dut, 0, 0x0004)) == 0x55AA55AA
    assert (await spi_frame(dut, 0, 0x0000)) == patterns[0x0000]
    assert (await spi_frame(dut, 0, 0x0008)) == patterns[0x0008]
    dut._log.info("KV cache OK: 4 banks, last words, aliasing, isolation")
