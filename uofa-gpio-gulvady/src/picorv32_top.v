/*
 * picorv32_top.v - Top-level SoC wrapper
 *
 * ECE 407 Final Project - PicoRV32 + 2KB SRAM + custom GPIO MMIO peripheral.
 * Team: Kedar Gulvady, Ali Alsaffar, Joseph McLaughlin
 *
 * Memory map
 * --------------------------------------------------------------------------
 *   0x0000_0000 - 0x0000_07FF   2 KiB SRAM   (sky130_sram_2k_1rw1r_32x512_8)
 *   0x0300_0000 - 0x0300_000F   GPIO peripheral (4 x 32-bit registers)
 *   anything else                unmapped (CPU will hang on access)
 * --------------------------------------------------------------------------
 *
 * Reset vector  : 0x0000_0000 (start at the bottom of SRAM)
 * Stack pointer : 0x0000_0800 (top of SRAM, grows downward)
 *
 * The SRAM is a 1-cycle synchronous-read macro, so ram_ready is registered
 * one cycle after ram_sel goes high (matches the PicoSoC pattern).  The
 * GPIO peripheral asserts mem_ready combinationally.
 */

`default_nettype none
`timescale 1ns / 1ps

module picorv32_top (
    input  wire         clk,
    input  wire         resetn,
    output wire         trap,

    // GPIO pads (32 bidirectional pins exposed as out / oe / in triplet;
    // the actual tri-state happens at the IO ring, outside this module).
    output wire [31:0]  gpio_o,
    output wire [31:0]  gpio_oe,
    input  wire [31:0]  gpio_i
);

    // ------------------------------------------------------------------
    // CPU <-> bus signals
    // ------------------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    // ------------------------------------------------------------------
    // Address decode
    // ------------------------------------------------------------------
    //   SRAM range : addr[31:11] == 0  (i.e. addr < 0x800)
    //   GPIO range : addr[31:24] == 8'h03
    // ------------------------------------------------------------------
    wire ram_sel  = mem_valid && (mem_addr[31:11] == 21'd0);
    wire gpio_sel = mem_valid && (mem_addr[31:24] == 8'h03);

    // Default responder: picorv32 has no bus timeout, so an access that
    // matches neither window must still be answered or the CPU hangs
    // until hard reset. Unmapped reads return 0, writes are dropped.
    reg  err_ready;
    always @(posedge clk) begin
        if (!resetn)
            err_ready <= 1'b0;
        else
            err_ready <= mem_valid && !ram_sel && !gpio_sel && !err_ready;
    end

    // ------------------------------------------------------------------
    // SRAM macro wiring
    //   sky130_sram_2kbyte_1rw1r_32x512_8 has 1-cycle synchronous read.
    //   ram_ready pulses high for one cycle, on the cycle after ram_sel
    //   first goes high (PicoSoC convention).
    // ------------------------------------------------------------------
    reg         ram_ready;
    wire [31:0] ram_rdata;

    always @(posedge clk) begin
        if (!resetn)
            ram_ready <= 1'b0;
        else
            ram_ready <= ram_sel && !ram_ready;
    end

    // ------------------------------------------------------------------
    // GPIO peripheral
    // ------------------------------------------------------------------
    wire        gpio_ready;
    wire [31:0] gpio_rdata;

    gpio #(.WIDTH(32), .ADDR_BITS(4)) u_gpio (
        .clk        (clk),
        .resetn     (resetn),
        .mem_valid  (gpio_sel),
        .mem_ready  (gpio_ready),
        .mem_addr   (mem_addr[3:0]),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (gpio_rdata),
        .gpio_o     (gpio_o),
        .gpio_oe    (gpio_oe),
        .gpio_i     (gpio_i)
    );

    // ------------------------------------------------------------------
    // Bus return path (PicoSoC-style cascaded ternary mux + OR of readys)
    // ------------------------------------------------------------------
    assign mem_ready = ram_ready | gpio_ready | err_ready;
    assign mem_rdata = ram_ready  ? ram_rdata  :
                       gpio_ready ? gpio_rdata :
                                    32'h0000_0000;

    // ------------------------------------------------------------------
    // PicoRV32 CPU core
    // Configured small: no IRQ, no MUL/DIV, no compressed ISA.
    // BARREL_SHIFTER is enabled so shift operations are single-cycle
    // (matches the picorv32 (large) configuration's shift behavior but
    // without the area cost of MUL/DIV).
    // ------------------------------------------------------------------
    picorv32 #(
        .ENABLE_COUNTERS    (1),
        .ENABLE_COUNTERS64  (1),
        .ENABLE_REGS_16_31  (1),
        .ENABLE_REGS_DUALPORT(1),
        .LATCHED_MEM_RDATA  (0),
        .TWO_STAGE_SHIFT    (1),
        .BARREL_SHIFTER     (1),
        .TWO_CYCLE_COMPARE  (0),
        .TWO_CYCLE_ALU      (0),
        .COMPRESSED_ISA     (0),
        .CATCH_MISALIGN     (1),
        .CATCH_ILLINSN      (1),
        .ENABLE_PCPI        (0),
        .ENABLE_MUL         (0),
        .ENABLE_FAST_MUL    (0),
        .ENABLE_DIV         (0),
        .ENABLE_IRQ         (0),
        .ENABLE_IRQ_QREGS   (0),
        .ENABLE_IRQ_TIMER   (0),
        .ENABLE_TRACE       (0),
        .REGS_INIT_ZERO     (0),
        .MASKED_IRQ         (32'h0000_0000),
        .LATCHED_IRQ        (32'hffff_ffff),
        .PROGADDR_RESET     (32'h0000_0000),
        .PROGADDR_IRQ       (32'h0000_0010),
        .STACKADDR          (32'h0000_0800)
    ) cpu (
        .clk         (clk),
        .resetn      (resetn),
        .trap        (trap),

        .mem_valid   (mem_valid),
        .mem_instr   (mem_instr),
        .mem_ready   (mem_ready),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_wstrb   (mem_wstrb),
        .mem_rdata   (mem_rdata),

        // Look-ahead, PCPI, IRQ, formal, and trace ports left dangling
        .mem_la_read (),
        .mem_la_write(),
        .mem_la_addr (),
        .mem_la_wdata(),
        .mem_la_wstrb(),

        .pcpi_valid  (),
        .pcpi_insn   (),
        .pcpi_rs1    (),
        .pcpi_rs2    (),
        .pcpi_wr     (1'b0),
        .pcpi_rd     (32'b0),
        .pcpi_wait   (1'b0),
        .pcpi_ready  (1'b0),

        .irq         (32'b0),
        .eoi         (),

        .trace_valid (),
        .trace_data  ()
    );

    // ------------------------------------------------------------------
    // SRAM macro instance
    //   Word-addressed: addr0 = mem_addr[10:2] gives us 512 words.
    //   csb0 is active-low chip select; tied low when ram_sel is high.
    //   web0 is active-low write enable; low when any wstrb bit is set.
    //   wmask0 carries the byte strobes through to the macro.
    //   Port 1 (read-only) is unused - csb1 tied high.
    // ------------------------------------------------------------------
    sky130_sram_2kbyte_1rw1r_32x512_8 sram (
        // Port 0 - read/write
        .clk0   (clk),
        .csb0   (~ram_sel),
        .web0   (~(|mem_wstrb)),
        .wmask0 (mem_wstrb),
        .addr0  (mem_addr[10:2]),
        .din0   (mem_wdata),
        .dout0  (ram_rdata),
        // Port 1 - unused
        .clk1   (clk),
        .csb1   (1'b1),
        .addr1  (9'b0),
        .dout1  ()
    );

endmodule

`default_nettype wire
