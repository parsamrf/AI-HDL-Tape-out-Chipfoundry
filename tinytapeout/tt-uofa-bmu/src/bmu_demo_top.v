/* --------------------------------------------------------------------------------------------
     PicoRV32 + Bit Manipulation Unit (BMU) boot-ROM demonstrator
     SPDX-License-Identifier: Apache-2.0

     The BMU is a combinational single-operand unit hung off the PicoRV32
     PCPI co-processor interface (see bmu_pcpi_wrapper.v). It executes
     custom-0 instructions {funct7=0000000, rs2, rs1, funct3, rd, 0001011}
     where funct3 selects the operation and only rs1 is read:
       000 = LZC (leading zero count, returns 32 for input 0)
       001 = TZC (trailing zero count, returns 32 for input 0)
       010 = bit reversal
       011 = popcount

     A hardwired boot ROM runs a self-test: it builds x1 = 0x00F0F0F0 and
     runs all four BMU ops on it, then stores the results to the result
     capture registers, which drive the chip outputs.

     Memory map:
       0x0000_0000 - 0x0000_00FF  boot ROM (hardwired self-test program)
       0x0000_2000 - 0x0000_200F  result capture registers -> chip outputs
     Every other address answers with rdata 0 (no unmapped-access hang).

     Expected results for x1 = 0x00F0F0F0
                        (= 0000_0000_1111_0000_1111_0000_1111_0000 binary):
       result_lzc = 0x00000008  (highest set bit is bit 23 -> 31-23 = 8)
       result_tzc = 0x00000004  (lowest set bit is bit 4)
       result_rev = 0x0F0F0F00  (bit k -> bit 31-k)
       result_pop = 0x0000000C  (12 bits set)
       test_done  = 1
----------------------------------------------------------------------------------------------*/

module bmu_demo_top (
    input  wire        clk,
    input  wire        resetn,
    output wire        trap,
    output reg         test_done,
    output reg  [31:0] result_lzc,
    output reg  [31:0] result_tzc,
    output reg  [31:0] result_rev,
    output reg  [31:0] result_pop
);

    // memory interface
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    reg  [31:0] mem_rdata;

    // Pico Co-Processor Interface (PCPI)
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
    // Boot ROM: hardwired BMU self-test program
    // ------------------------------------------------------------------
    // x1 = 0x00F0F0F0 (imm[11] of the ADDI is 0, so no sign-extension fixup)
    localparam [31:0] I_LUI_X1  = {20'h00F0F, 5'd1, 7'b0110111};
    localparam [31:0] I_ADDI_X1 = {12'h0F0, 5'd1, 3'b000, 5'd1, 7'b0010011};
    // BMU ops (custom-0): {funct7=0000000, rs2=x0, rs1=x1, funct3, rd}
    localparam [31:0] I_LZC_X3  = {7'b0000000, 5'd0, 5'd1, 3'b000, 5'd3, 7'b0001011};
    localparam [31:0] I_TZC_X4  = {7'b0000000, 5'd0, 5'd1, 3'b001, 5'd4, 7'b0001011};
    localparam [31:0] I_REV_X5  = {7'b0000000, 5'd0, 5'd1, 3'b010, 5'd5, 7'b0001011};
    localparam [31:0] I_POP_X6  = {7'b0000000, 5'd0, 5'd1, 3'b011, 5'd6, 7'b0001011};
    // x10 = 0x2000 (result base)
    localparam [31:0] I_LUI_X10 = {20'h00002, 5'd10, 7'b0110111};
    // result stores: sw xN, imm(x10)
    localparam [31:0] I_SW_X3_R0 = {7'b0000000, 5'd3, 5'd10, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_SW_X4_R4 = {7'b0000000, 5'd4, 5'd10, 3'b010, 5'b00100, 7'b0100011};
    localparam [31:0] I_SW_X5_R8 = {7'b0000000, 5'd5, 5'd10, 3'b010, 5'b01000, 7'b0100011};
    localparam [31:0] I_SW_X6_RC = {7'b0000000, 5'd6, 5'd10, 3'b010, 5'b01100, 7'b0100011};
    // jal x0, 0 (park)
    localparam [31:0] I_LOOP = 32'h0000006F;

    reg [31:0] rom_word;
    always @(*) begin
        case (mem_addr[7:2])
            6'd0:  rom_word = I_LUI_X1;
            6'd1:  rom_word = I_ADDI_X1;
            6'd2:  rom_word = I_LZC_X3;
            6'd3:  rom_word = I_TZC_X4;
            6'd4:  rom_word = I_REV_X5;
            6'd5:  rom_word = I_POP_X6;
            6'd6:  rom_word = I_LUI_X10;
            6'd7:  rom_word = I_SW_X3_R0;
            6'd8:  rom_word = I_SW_X4_R4;
            6'd9:  rom_word = I_SW_X5_R8;
            6'd10: rom_word = I_SW_X6_RC;
            6'd11: rom_word = I_LOOP;
            default: rom_word = 32'h0000_0013; // NOP
        endcase
    end

    // ------------------------------------------------------------------
    // Read-data return mux (address is held stable through the ready cycle)
    // ------------------------------------------------------------------
    always @(*) begin
        if (rom_sel) mem_rdata = rom_word;
        else         mem_rdata = 32'h0000_0000;
    end

    // ------------------------------------------------------------------
    // Result capture registers -> chip outputs
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            test_done  <= 1'b0;
            result_lzc <= 32'h0;
            result_tzc <= 32'h0;
            result_rev <= 32'h0;
            result_pop <= 32'h0;
        end else if (mem_valid && mem_ready && res_sel && mem_wstrb == 4'b1111) begin
            case (mem_addr[3:2])
                2'd0: result_lzc <= mem_wdata;
                2'd1: result_tzc <= mem_wdata;
                2'd2: result_rev <= mem_wdata;
                2'd3: begin
                    result_pop <= mem_wdata;
                    test_done  <= 1'b1;
                end
            endcase
        end
    end

    // ENABLE_PCPI is REQUIRED, or the BMU is dead logic and synthesis
    // deletes it from the netlist.
    picorv32 #(
        .ENABLE_PCPI(1),
        .ENABLE_MUL(0),
        .ENABLE_DIV(0),
        .ENABLE_FAST_MUL(0)
    ) cpu (
        .clk(clk),
        .resetn(resetn),
        .trap(trap),

        // Memory Interface
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),

        // PCPI
        .pcpi_valid(pcpi_valid),
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1),
        .pcpi_rs2(pcpi_rs2),
        .pcpi_wr(pcpi_wr),
        .pcpi_rd(pcpi_rd),
        .pcpi_wait(pcpi_wait),
        .pcpi_ready(pcpi_ready),

        // IRQ Interface (disabled; tied off so GLS sees no X sources)
        .irq(32'b0),
        .eoi()
    );

    // Bit Manipulation Unit on the PCPI bus
    bmu_pcpi_wrapper bmu_inst (
        .clk(clk),
        .resetn(resetn),
        .pcpi_valid(pcpi_valid),
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1),
        .pcpi_rs2(pcpi_rs2),
        .pcpi_ready(pcpi_ready),
        .pcpi_wr(pcpi_wr),
        .pcpi_wait(pcpi_wait),
        .pcpi_rd(pcpi_rd)
    );

endmodule
