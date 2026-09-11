# SPDX-License-Identifier: Apache-2.0
# GEMM tile: load an 8x8 INT8 weight matrix and a 2x8 activation matrix
# through the SPI register bridge, run the systolic engine, and check the
# requantized INT8 results bit-exactly:
#   R[m][n] = sat8( ((sum_k A[m][k]*W[k][n]) * SCALE >>> SHIFT) + ZP )
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


def sat8(v):
    return max(-128, min(127, v))


def pack4(bs):
    return sum((b & 0xFF) << (8 * j) for j, b in enumerate(bs))


@cocotb.test()
async def test_gemm_tile(dut):
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

    # W[k][n]: mix of signs, includes an identity-ish diagonal
    W = [[(3 if k == n else ((k - n) % 7) - 3) for n in range(8)] for k in range(8)]
    A = [[5, -3, 2, 0, -1, 4, -128, 7],
         [1, 1, -2, 3, 127, -5, 0, -9]]
    M = len(A)
    scale, shift, zp = 3, 2, -5

    # weight buffer: 16 words, word i byte j = W_flat[4i+j], flat f = k*8+n
    Wf = [W[f // 8][f % 8] for f in range(64)]
    for i in range(16):
        await spi_frame(dut, 1, 0x0100 + 4 * i, pack4(Wf[4 * i:4 * i + 4]))
    # activation buffer: row m in words {2m, 2m+1}, byte j = A[m][4*(w&1)+j]
    for m in range(M):
        for w in range(2):
            await spi_frame(dut, 1, 0x0200 + 4 * (2 * m + w),
                            pack4(A[m][4 * w:4 * w + 4]))

    await spi_frame(dut, 1, 0x000C, M)                    # DIMS
    await spi_frame(dut, 1, 0x0010, scale & 0xFFFFFFFF)   # SCALE
    await spi_frame(dut, 1, 0x0014, shift)                # SHIFT
    await spi_frame(dut, 1, 0x0018, zp & 0xFF)            # ZP
    await spi_frame(dut, 1, 0x0008, 2)                    # CFG: local src, irq_en
    await spi_frame(dut, 1, 0x0000, 2)                    # CTRL: clear_done
    await spi_frame(dut, 1, 0x0000, 1)                    # CTRL: start

    status = 0
    for _ in range(80):
        status = await spi_frame(dut, 0, 0x0004)
        if status & 2:
            break
    assert status & 2, f"GEMM done never set (STATUS={status:#x})"
    assert ((int(dut.uio_out.value) >> 0) & 1) == 1, "irq not asserted"

    # bit-exact golden: requant((A@W)[m][n])
    ref = [[sat8(((sum(A[m][k] * W[k][n] for k in range(8)) * scale) >> shift) + zp)
            for n in range(8)] for m in range(M)]

    for m in range(M):
        got = []
        for w in range(2):
            word = await spi_frame(dut, 0, 0x0400 + 4 * (2 * m + w))
            for j in range(4):
                b = (word >> (8 * j)) & 0xFF
                got.append(b - 256 if b & 0x80 else b)
        assert got == ref[m], f"row {m}: got {got}, expected {ref[m]}"
        dut._log.info(f"GEMM row {m} bit-exact: {got}")
