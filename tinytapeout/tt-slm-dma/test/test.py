# SPDX-License-Identifier: Apache-2.0
# DMA tile: place a two-descriptor chain and payload words in the scratch RAM
# through the SPI register bridge, start the engine, and verify the chained
# copy, the sticky done flag, the irq pin, and the error path on a
# misaligned descriptor.
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CS, SCK, MOSI = 4, 5, 6
MISO = 3

# bridge windows
CSR_CTRL, CSR_STATUS, CSR_DESC, CSR_CFG = 0x0000, 0x0004, 0x0008, 0x000C
RAM = 0x1000


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
async def test_dma_tile(dut):
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

    payload = [0xDEAD0001, 0xBEEF0002, 0xCAFE0003, 0xF00D0004]

    # descriptor 0 at RAM word 0 (DMA address 0x1000): copy 2 words
    # 0x1020 -> 0x1080, then chain to descriptor 1 at 0x1010
    await spi_frame(dut, 1, RAM + 0x00, 0x1020)          # src
    await spi_frame(dut, 1, RAM + 0x04, 0x1080)          # dst
    await spi_frame(dut, 1, RAM + 0x08, 8)               # len (bytes)
    await spi_frame(dut, 1, RAM + 0x0C, 0x1010 | 1)      # next valid
    # descriptor 1 at RAM word 4: copy 2 words 0x1028 -> 0x1088, stop + done
    await spi_frame(dut, 1, RAM + 0x10, 0x1028)
    await spi_frame(dut, 1, RAM + 0x14, 0x1088)
    await spi_frame(dut, 1, RAM + 0x18, 8)
    await spi_frame(dut, 1, RAM + 0x1C, 2)               # stop, raise done
    # payload at RAM words 8..11 (0x1020..0x102C)
    for i, w in enumerate(payload):
        await spi_frame(dut, 1, RAM + 0x20 + 4 * i, w)

    await spi_frame(dut, 1, CSR_CFG, 1)                  # irq_en
    await spi_frame(dut, 1, CSR_DESC, 0x1000)
    await spi_frame(dut, 1, CSR_CTRL, 1)                 # start

    status = 0
    for _ in range(60):
        status = await spi_frame(dut, 0, CSR_STATUS)
        if status & 2:
            break
    assert status & 2, f"DMA done never set (STATUS={status:#x})"
    assert not (status & 4), f"DMA err set (STATUS={status:#x})"
    assert ((int(dut.uio_out.value) >> 0) & 1) == 1, "irq not asserted"

    # chained copy landed at 0x1080..0x108C
    for i, w in enumerate(payload):
        got = await spi_frame(dut, 0, RAM + 0x80 + 4 * i)
        assert got == w, f"dst[{i}]: got {got:#010x}, expected {w:#010x}"
    # source untouched
    assert (await spi_frame(dut, 0, RAM + 0x20)) == payload[0]

    # error path: misaligned DESC_PTR sets STATUS.err and stops
    await spi_frame(dut, 1, CSR_CTRL, 2)                 # clear done+err
    assert ((await spi_frame(dut, 0, CSR_STATUS)) & 6) == 0
    await spi_frame(dut, 1, CSR_DESC, 0x1002)
    await spi_frame(dut, 1, CSR_CTRL, 1)
    status = 0
    for _ in range(20):
        status = await spi_frame(dut, 0, CSR_STATUS)
        if status & 4:
            break
    assert status & 4, f"DMA err never set (STATUS={status:#x})"
    dut._log.info("DMA OK: chained copy bit-exact, irq, error path")
