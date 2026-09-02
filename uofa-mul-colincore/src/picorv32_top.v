`timescale 1 ns / 1 ps
/*
 * picorv32_top.v
 * ECE 407 - PicoRV32 + Hardware Multiplier + la_spram SRAM
 * =========================================================
 * Top-level SoC wrapper using lambdalib la_spram.
 * lambdalib maps la_spram to the correct sky130 SRAM macro automatically.
 *
 *  Instantiates:
 *    1. picorv32      - RISC-V CPU core (ENABLE_PCPI=1)
 *    2. multiplier    - ECE 407 hardware multiplier wired via PCPI
 *    3. la_spram      - 2KB SRAM (32-bit wide, 512 words)
 */

module picorv32_top (
    input  clk,
    input  resetn,
    output trap
);

    // -----------------------------------------------------------------------
    // Native memory bus
    // -----------------------------------------------------------------------
    // instance outputs must be nets, not regs (IEEE 1364; iverilog rejects
    // the reg form even though Yosys tolerated it)
    wire        mem_valid, mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;

    // Single-cycle SRAM: mem_ready one cycle after mem_valid
    always @(posedge clk) begin
        if (!resetn)
            mem_ready <= 1'b0;
        else
            mem_ready <= mem_valid;
    end

    // -----------------------------------------------------------------------
    // PCPI bus - connects picorv32 to the external hardware multiplier
    // -----------------------------------------------------------------------
    wire        pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    // -----------------------------------------------------------------------
    // ECE 407 Hardware Multiplier (external PCPI co-processor)
    // -----------------------------------------------------------------------
    // picorv32 offers EVERY undecodable instruction to the PCPI, so the
    // multiplier must claim only its own encoding (RV32M MUL: opcode
    // 0110011, funct3 000, funct7 0000001). Without this decode, any
    // illegal instruction "succeeded" as rs1*rs2 ~35 cycles later and
    // CATCH_ILLINSN never fired.
    wire pcpi_insn_mul = (pcpi_insn[6:0]   == 7'b0110011) &&
                         (pcpi_insn[14:12] == 3'b000)     &&
                         (pcpi_insn[31:25] == 7'b0000001);

    multiplier ece407 (
        .clk    (clk),
        .resetn (resetn),
        .start  (pcpi_valid & pcpi_insn_mul & ~pcpi_ready),
        .a      (pcpi_rs1),
        .b      (pcpi_rs2),
        .out    (pcpi_rd),
        .done   (pcpi_ready),
        .busy   (pcpi_wait)
    );
    assign pcpi_wr = pcpi_ready;

    // -----------------------------------------------------------------------
    // PicoRV32 CPU core
    // -----------------------------------------------------------------------
    picorv32 #(
        .ENABLE_PCPI(1)
    ) rv32_soc (
        .clk        (clk),
        .resetn     (resetn),
        .trap       (trap),
        .mem_valid  (mem_valid),
        .mem_instr  (mem_instr),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata),
        .mem_la_read  (),
        .mem_la_write (),
        .mem_la_addr  (),
        .mem_la_wdata (),
        .mem_la_wstrb (),
        .pcpi_valid (pcpi_valid),
        .pcpi_insn  (pcpi_insn),
        .pcpi_rs1   (pcpi_rs1),
        .pcpi_rs2   (pcpi_rs2),
        .pcpi_wr    (pcpi_wr),
        .pcpi_rd    (pcpi_rd),
        .pcpi_wait  (pcpi_wait),
        .pcpi_ready (pcpi_ready),
        .trace_valid(),
        .trace_data ()
    );

    // -----------------------------------------------------------------------
    // la_spram: 2KB SRAM (512 words x 32 bits)
    // lambdalib maps this to the sky130 SRAM macro automatically.
    // -----------------------------------------------------------------------
    la_spram #(
        .DW(32),   // data width
        .AW(9)     // address width (2^9 = 512 words = 2KB)
    ) sram (
        .clk     (clk),
        .ce      (1'b1),
        .we      ((mem_wstrb != 0)),
        .wmask   (mem_wstrb),
        // word index: picorv32 issues BYTE addresses; wiring mem_addr
        // straight in truncated to addr[8:0] and made CPU words land in
        // SRAM words 0,4,8,... (128/512 words usable, address space
        // wrapping every 0x200 bytes - stack clobbered code)
        .addr    (mem_addr[10:2]),
        .din     (mem_wdata),
        .dout    (mem_rdata),
        .selctrl (1'b0),
        .ctrl    ('b0),
        .status  ()
    );

endmodule