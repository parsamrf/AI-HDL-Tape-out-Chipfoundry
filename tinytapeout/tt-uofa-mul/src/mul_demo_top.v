/* --------------------------------------------------------------------------
 * mul_demo_top.v
 * SPDX-License-Identifier: Apache-2.0
 *
 * PicoRV32 + external PCPI hardware multiplier demonstrator.
 *
 * The multiplier is a 32-cycle shift-and-add unit hung off the PCPI bus and
 * claims exactly the RV32M MUL encoding (opcode 0110011, funct3 000,
 * funct7 0000001). picorv32 is instantiated with ENABLE_PCPI(1) and the
 * internal MUL/DIV units disabled, so the external unit is the only thing
 * that can retire a MUL — without ENABLE_PCPI the multiplier is dead logic
 * and synthesis deletes it.
 *
 * A hardwired boot ROM runs a self-test program:
 *   x1 = 0x00001234, x2 = 0x00005678,  MUL x3,x1,x2  -> 0x06260060
 *   x4 = 0xFFFFFFFF, x5 = 2,           MUL x6,x4,x5  -> low word 0xFFFFFFFE
 *                                      (checks 64-bit overflow truncation)
 *   SRAM round-trip: sw x3 -> RAM word 0, lw back into x7
 *   store x3/x6/x7 to the result-capture registers; the last store also
 *   asserts test_done; park with jal x0,0.
 *
 * Memory map:
 *   0x0000_0000 - 0x0000_0FFF  boot ROM (hardwired self-test program)
 *   0x0000_1000 - 0x0000_1FFF  128 B SRAM (la_spram, 32 words x 32 bits)
 *   0x0000_2000 - 0x0000_2FFF  result capture registers -> chip outputs
 * Every other address answers with rdata 0 (no unmapped-access hang).
 *
 * Expected results (checked by test/test.py):
 *   result_mul1 = 0x06260060   (0x1234 * 0x5678)
 *   result_mul2 = 0xFFFFFFFE   (0xFFFFFFFF * 2, low 32 bits)
 *   result_sram = 0x06260060   (mul1 written to and read back from SRAM)
 *   test_done   = 1, trap = 0
 * ------------------------------------------------------------------------ */

module mul_demo_top (
    input  wire        clk,
    input  wire        resetn,
    output wire        trap,
    output reg         test_done,
    output reg  [31:0] result_mul1,
    output reg  [31:0] result_mul2,
    output reg  [31:0] result_sram
);

    // ------------------------------------------------------------------
    // Native memory bus
    // ------------------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    reg  [31:0] mem_rdata;

    // PCPI bus - connects picorv32 to the external hardware multiplier
    wire        pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    // ------------------------------------------------------------------
    // Address decode
    // ------------------------------------------------------------------
    wire rom_sel = (mem_addr[31:12] == 20'h00000);
    wire ram_sel = (mem_addr[31:12] == 20'h00001);
    wire res_sel = (mem_addr[31:12] == 20'h00002);

    // Single-pulse ready one cycle after mem_valid; every address is
    // answered so an unmapped access can never hang the CPU.
    always @(posedge clk) begin
        if (!resetn)
            mem_ready <= 1'b0;
        else
            mem_ready <= mem_valid && !mem_ready;
    end

    // ------------------------------------------------------------------
    // Boot ROM: hardwired multiplier self-test program
    // ------------------------------------------------------------------
    // x1 = 0x00001234
    localparam [31:0] I_LUI_X1  = {20'h00001, 5'd1, 7'b0110111};
    localparam [31:0] I_ADDI_X1 = {12'h234, 5'd1, 3'b000, 5'd1, 7'b0010011};
    // x2 = 0x00005678
    localparam [31:0] I_LUI_X2  = {20'h00005, 5'd2, 7'b0110111};
    localparam [31:0] I_ADDI_X2 = {12'h678, 5'd2, 3'b000, 5'd2, 7'b0010011};
    // mul x3, x1, x2   ({funct7=0000001, rs2, rs1, funct3=000, rd, 0110011})
    localparam [31:0] I_MUL_X3  = {7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0110011};
    // x4 = 0xFFFFFFFF (addi x4, x0, -1), x5 = 2
    localparam [31:0] I_ADDI_X4 = {12'hFFF, 5'd0, 3'b000, 5'd4, 7'b0010011};
    localparam [31:0] I_ADDI_X5 = {12'h002, 5'd0, 3'b000, 5'd5, 7'b0010011};
    // mul x6, x4, x5 -> 0x1_FFFF_FFFE, low word 0xFFFFFFFE
    localparam [31:0] I_MUL_X6  = {7'b0000001, 5'd5, 5'd4, 3'b000, 5'd6, 7'b0110011};
    // x9 = 0x1000 (SRAM base), x10 = 0x2000 (result base)
    localparam [31:0] I_LUI_X9  = {20'h00001, 5'd9,  7'b0110111};
    localparam [31:0] I_LUI_X10 = {20'h00002, 5'd10, 7'b0110111};
    // SRAM round-trip: sw x3, 0(x9); lw x7, 0(x9)
    localparam [31:0] I_SW_X3_SRAM = {7'b0000000, 5'd3, 5'd9, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_LW_X7_SRAM = {12'h000, 5'd9, 3'b010, 5'd7, 7'b0000011};
    // result stores: sw xN, imm(x10); the store to offset 8 asserts test_done
    localparam [31:0] I_SW_X3_R0 = {7'b0000000, 5'd3, 5'd10, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_SW_X6_R4 = {7'b0000000, 5'd6, 5'd10, 3'b010, 5'b00100, 7'b0100011};
    localparam [31:0] I_SW_X7_R8 = {7'b0000000, 5'd7, 5'd10, 3'b010, 5'b01000, 7'b0100011};
    // jal x0, 0 (park)
    localparam [31:0] I_LOOP = 32'h0000006F;

    reg [31:0] rom_word;
    always @(*) begin
        case (mem_addr[7:2])
            6'd0:  rom_word = I_LUI_X1;
            6'd1:  rom_word = I_ADDI_X1;
            6'd2:  rom_word = I_LUI_X2;
            6'd3:  rom_word = I_ADDI_X2;
            6'd4:  rom_word = I_MUL_X3;
            6'd5:  rom_word = I_ADDI_X4;
            6'd6:  rom_word = I_ADDI_X5;
            6'd7:  rom_word = I_MUL_X6;
            6'd8:  rom_word = I_LUI_X9;
            6'd9:  rom_word = I_SW_X3_SRAM;
            6'd10: rom_word = I_LW_X7_SRAM;
            6'd11: rom_word = I_LUI_X10;
            6'd12: rom_word = I_SW_X3_R0;
            6'd13: rom_word = I_SW_X6_R4;
            6'd14: rom_word = I_SW_X7_R8;
            6'd15: rom_word = I_LOOP;
            default: rom_word = 32'h0000_0013; // NOP
        endcase
    end

    // ------------------------------------------------------------------
    // Read-data return mux. la_spram registers dout, so the SRAM select is
    // registered to line up with it; the address is held stable through
    // the ready cycle so rom_sel can stay combinational.
    // ------------------------------------------------------------------
    wire [31:0] ram_rdata;
    reg         ram_sel_q;
    always @(posedge clk) begin
        if (!resetn)
            ram_sel_q <= 1'b0;
        else
            ram_sel_q <= mem_valid && ram_sel;
    end

    always @(*) begin
        if (rom_sel)        mem_rdata = rom_word;
        else if (ram_sel_q) mem_rdata = ram_rdata;
        else                mem_rdata = 32'h0000_0000;
    end

    // ------------------------------------------------------------------
    // Result capture registers -> chip outputs
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            test_done   <= 1'b0;
            result_mul1 <= 32'h0;
            result_mul2 <= 32'h0;
            result_sram <= 32'h0;
        end else if (mem_valid && mem_ready && res_sel && mem_wstrb == 4'b1111) begin
            case (mem_addr[3:2])
                2'd0: result_mul1 <= mem_wdata;
                2'd1: result_mul2 <= mem_wdata;
                2'd2: begin
                    result_sram <= mem_wdata;
                    test_done   <= 1'b1;
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Hardware multiplier (external PCPI co-processor).
    // picorv32 offers EVERY undecodable instruction to the PCPI, so the
    // multiplier must claim only its own encoding (RV32M MUL: opcode
    // 0110011, funct3 000, funct7 0000001); anything else falls through to
    // CATCH_ILLINSN as intended.
    // ------------------------------------------------------------------
    wire pcpi_insn_mul = (pcpi_insn[6:0]   == 7'b0110011) &&
                         (pcpi_insn[14:12] == 3'b000)     &&
                         (pcpi_insn[31:25] == 7'b0000001);

    multiplier mul_unit (
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

    // ------------------------------------------------------------------
    // PicoRV32 CPU core. ENABLE_PCPI is REQUIRED (the multiplier is dead
    // logic without it); the internal MUL/DIV units stay disabled so the
    // external unit is what gets exercised.
    // ------------------------------------------------------------------
    picorv32 #(
        .ENABLE_PCPI(1),
        .ENABLE_MUL(0),
        .ENABLE_DIV(0),
        .ENABLE_FAST_MUL(0)
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
        // IRQ interface (disabled; tied off so GLS sees no X sources)
        .irq        (32'b0),
        .eoi        (),
        .trace_valid(),
        .trace_data ()
    );

    // ------------------------------------------------------------------
    // Data SRAM at 0x1000: la_spram, 32 words x 32 bits, word-indexed
    // (mem_addr[6:2]). la_spram has no chip-select input, so the write
    // enable is gated with ram_sel — otherwise a store to the result
    // registers at 0x2000 would alias into RAM word 0 — and the read-back
    // is muxed by the registered select above.
    // ------------------------------------------------------------------
    la_spram #(
        .DW(32),
        .AW(5)
    ) sram (
        .clk     (clk),
        .ce      (1'b1),
        .we      (mem_valid && ram_sel && (mem_wstrb != 0)),
        .wmask   (mem_wstrb),
        .addr    (mem_addr[6:2]),
        .din     (mem_wdata),
        .dout    (ram_rdata),
        .selctrl (1'b0),
        .ctrl    (8'b0),
        .status  ()
    );

    wire _unused = &{mem_instr, 1'b0};

endmodule
