/* --------------------------------------------------------------------------------------------
                         ECE507 - Digital VLSI Design

			                     Project Work
								     by
			                Chakravarthy Anbazhagan
				              (chakra@arizona.edu)

     Pipelined High-Performance Bit-Slice Vector Processor Extension to picorv32 CPU core

     Our design implements 4x8bit SIMD vector operations on 32bit registers (see
     pcpi_vec_proc.v for the instruction set: custom-0 opcode, funct7=0000001,
     funct3 selects VADD8/VSUB8/VAND8/VOR8/VXOR8/VSADD8/VMUL8/VDOT8).

     ------------------------------------------------------------------------------
     Integration top reworked for tapeout (2026-08-31):
     the original top (a) never set ENABLE_PCPI, so synthesis deleted the entire
     vector unit from the netlist, (b) had no way to load or observe a program
     (uninitialized flop-RAM at the reset vector, no data outputs), and (c) fed
     the BYTE address into the word-addressed SRAM (only 128 of 512 words
     reachable, whole address space aliasing into 512 bytes).

     This version follows the same pattern as the co-processor design: a hardwired boot
     ROM runs a self-test program that exercises the vector unit (including the
     multicycle VDOT8 path) and the SRAM, and exposes the results as chip
     outputs so the silicon is testable.

     Memory map:
       0x0000_0000 - 0x0000_00FF  boot ROM (hardwired self-test program)
       0x0000_1000 - 0x0000_17FF  2 KB SRAM (32 x 512, word-indexed)
       0x0000_2000 - 0x0000_2013  result capture registers -> chip outputs
     Every other address answers with rdata 0 (no unmapped-access hang).

     Expected results (also checked by test/tb_picorv32_vec_proc_top.v):
       result_vadd8  = 0x06080A0C   (0x01020304 +8 0x05060708)
       result_vsadd8 = 0xFFFFFFFF   (0xF0F0F0F0 sat+8 0xF0F0F0F0)
       result_vmul8  = 0x050C1520   (0x01020304 *8 0x05060708, low bytes)
       result_vdot8  = 0x00000046   (dot product 4*8+3*7+2*6+1*5 = 70)
       result_sram   = 0x06080A0C   (VADD8 result written to and read back
                                     from SRAM word 0x1000)
       test_done     = 1
----------------------------------------------------------------------------------------------*/

module picorv32_vec_proc_top (
    input  wire        clk,
    input  wire        resetn,
    output wire        trap,
    output reg         test_done,
    output reg  [31:0] result_vadd8,
    output reg  [31:0] result_vsadd8,
    output reg  [31:0] result_vmul8,
    output reg  [31:0] result_vdot8,
    output reg  [31:0] result_sram
);

    // declare all the wire nets used for interconnect
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    reg  [31:0] mem_rdata;

    // Look-Ahead Interface
    wire        mem_la_read;
    wire        mem_la_write;
    wire [31:0] mem_la_addr;
    wire [31:0] mem_la_wdata;
    wire [ 3:0] mem_la_wstrb;

    // Pico Co-Processor Interface (PCPI)
    wire        pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    // Trace Interface
    wire        trace_valid;
    wire [35:0] trace_data;

    // ------------------------------------------------------------------
    // Address decode
    // ------------------------------------------------------------------
    wire rom_sel  = (mem_addr[31:12] == 20'h00000);
    wire sram_sel = (mem_addr[31:12] == 20'h00001);
    wire res_sel  = (mem_addr[31:12] == 20'h00002);

    // Single-pulse ready one cycle after mem_valid; every address is
    // answered so an unmapped access can never hang the CPU.
    always @(posedge clk) begin
        if (!resetn)
            mem_ready <= 1'b0;
        else
            mem_ready <= mem_valid && !mem_ready;
    end

    // ------------------------------------------------------------------
    // Boot ROM: hardwired vector self-test program
    // ------------------------------------------------------------------
    // x1 = 0x01020304
    localparam [31:0] I_LUI_X1   = {20'h01020, 5'd1, 7'b0110111};
    localparam [31:0] I_ADDI_X1  = {12'h304, 5'd1, 3'b000, 5'd1, 7'b0010011};
    // x2 = 0x05060708
    localparam [31:0] I_LUI_X2   = {20'h05060, 5'd2, 7'b0110111};
    localparam [31:0] I_ADDI_X2  = {12'h708, 5'd2, 3'b000, 5'd2, 7'b0010011};
    // x8 = 0xF0F0F0F0 (saturation stimulus)
    localparam [31:0] I_LUI_X8   = {20'hF0F0F, 5'd8, 7'b0110111};
    localparam [31:0] I_ADDI_X8  = {12'h0F0, 5'd8, 3'b000, 5'd8, 7'b0010011};
    // vector ops: {funct7=0000001, rs2, rs1, funct3, rd, custom-0}
    localparam [31:0] I_VADD8_X3  = {7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0001011};
    localparam [31:0] I_VSADD8_X4 = {7'b0000001, 5'd8, 5'd8, 3'b101, 5'd4, 7'b0001011};
    localparam [31:0] I_VMUL8_X5  = {7'b0000001, 5'd2, 5'd1, 3'b110, 5'd5, 7'b0001011};
    localparam [31:0] I_VDOT8_X6  = {7'b0000001, 5'd2, 5'd1, 3'b111, 5'd6, 7'b0001011};
    // x9 = 0x1000 (SRAM base), x10 = 0x2000 (result base)
    localparam [31:0] I_LUI_X9   = {20'h00001, 5'd9,  7'b0110111};
    localparam [31:0] I_LUI_X10  = {20'h00002, 5'd10, 7'b0110111};
    // SRAM round-trip: sw x3, 0(x9); lw x7, 0(x9)
    localparam [31:0] I_SW_X3_SRAM = {7'b0000000, 5'd3, 5'd9, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_LW_X7_SRAM = {12'h000, 5'd9, 3'b010, 5'd7, 7'b0000011};
    // result stores: sw xN, imm(x10)
    localparam [31:0] I_SW_X3_R0 = {7'b0000000, 5'd3, 5'd10, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_SW_X4_R4 = {7'b0000000, 5'd4, 5'd10, 3'b010, 5'b00100, 7'b0100011};
    localparam [31:0] I_SW_X5_R8 = {7'b0000000, 5'd5, 5'd10, 3'b010, 5'b01000, 7'b0100011};
    localparam [31:0] I_SW_X6_RC = {7'b0000000, 5'd6, 5'd10, 3'b010, 5'b01100, 7'b0100011};
    localparam [31:0] I_SW_X7_R10 = {7'b0000000, 5'd7, 5'd10, 3'b010, 5'b10000, 7'b0100011};
    // jal x0, 0 (park)
    localparam [31:0] I_LOOP = 32'h0000006F;

    reg [31:0] rom_word;
    always @(*) begin
        case (mem_addr[7:2])
            6'd0:  rom_word = I_LUI_X1;
            6'd1:  rom_word = I_ADDI_X1;
            6'd2:  rom_word = I_LUI_X2;
            6'd3:  rom_word = I_ADDI_X2;
            6'd4:  rom_word = I_LUI_X8;
            6'd5:  rom_word = I_ADDI_X8;
            6'd6:  rom_word = I_VADD8_X3;
            6'd7:  rom_word = I_VSADD8_X4;
            6'd8:  rom_word = I_VMUL8_X5;
            6'd9:  rom_word = I_VDOT8_X6;
            6'd10: rom_word = I_LUI_X9;
            6'd11: rom_word = I_SW_X3_SRAM;
            6'd12: rom_word = I_LW_X7_SRAM;
            6'd13: rom_word = I_LUI_X10;
            6'd14: rom_word = I_SW_X3_R0;
            6'd15: rom_word = I_SW_X4_R4;
            6'd16: rom_word = I_SW_X5_R8;
            6'd17: rom_word = I_SW_X6_RC;
            6'd18: rom_word = I_SW_X7_R10;
            6'd19: rom_word = I_LOOP;
            default: rom_word = 32'h0000_0013; // NOP
        endcase
    end

    // ------------------------------------------------------------------
    // Read-data return mux (address is held stable through the ready cycle)
    // ------------------------------------------------------------------
    wire [31:0] sram_rdata;
    always @(*) begin
        if (rom_sel)       mem_rdata = rom_word;
        else if (sram_sel) mem_rdata = sram_rdata;
        else               mem_rdata = 32'h0000_0000;
    end

    // ------------------------------------------------------------------
    // Result capture registers -> chip outputs
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            test_done     <= 1'b0;
            result_vadd8  <= 32'h0;
            result_vsadd8 <= 32'h0;
            result_vmul8  <= 32'h0;
            result_vdot8  <= 32'h0;
            result_sram   <= 32'h0;
        end else if (mem_valid && mem_ready && res_sel && mem_wstrb == 4'b1111) begin
            case (mem_addr[4:2])
                3'd0: result_vadd8  <= mem_wdata;
                3'd1: result_vsadd8 <= mem_wdata;
                3'd2: result_vmul8  <= mem_wdata;
                3'd3: result_vdot8  <= mem_wdata;
                3'd4: begin
                    result_sram <= mem_wdata;
                    test_done   <= 1'b1;
                end
                default: ;
            endcase
        end
    end

    // instantiate picorv32 module - ENABLE_PCPI is REQUIRED, or the vector
    // unit is dead logic and synthesis deletes it (this happened: the first
    // hardened netlist contained zero vec_proc cells)
    picorv32 #(
        .ENABLE_PCPI(1),
        .ENABLE_MUL(0),
        .ENABLE_DIV(0),
        .ENABLE_FAST_MUL(0)
    ) rv32_soc (
		   .clk(clk),
		   .resetn(resetn),
		   .trap(trap),
		   .mem_valid(mem_valid),
		   .mem_instr(mem_instr),
		   .mem_ready(mem_ready),

		   .mem_addr(mem_addr),
		   .mem_wdata(mem_wdata),
		   .mem_wstrb(mem_wstrb),
           .mem_rdata(mem_rdata),

            // look-Ahead Interface
		   .mem_la_read(mem_la_read),
		   .mem_la_write(mem_la_write),
		   .mem_la_addr(mem_la_addr),
		   .mem_la_wdata(mem_la_wdata),
		   .mem_la_wstrb(mem_la_wstrb),

   		    // Pico Co-Processor Interface (PCPI)
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
           .eoi(),
            // Trace Interface
	       .trace_valid(trace_valid),
	       .trace_data(trace_data)
	);

    /* data SRAM at 0x1000: word-indexed (mem_addr[10:2] - wiring the byte
       address in truncated to addr[8:0] and wrapped the whole address space
       into 512 bytes), chip-selected only for this window so stores to the
       result registers cannot alias into it */
    sram_behav sram (
     .clk  (clk),
     .csb0  (!(mem_valid && sram_sel)),
     .web0  (!(mem_wstrb != 0)),
     .wmask0(mem_wstrb),
     .addr0 ({23'b0, mem_addr[10:2]}),
     .din0  (mem_wdata),
     .dout0 (sram_rdata)
    );

	// instantiate our pipelined, vector processor module
    pcpi_vec_proc vec_proc (
    .clk        (clk),
    .resetn     (resetn),
    .pcpi_valid (pcpi_valid),
    .pcpi_insn  (pcpi_insn),
    .pcpi_rs1   (pcpi_rs1),
    .pcpi_rs2   (pcpi_rs2),
    .pcpi_wr    (pcpi_wr),
    .pcpi_rd    (pcpi_rd),
    .pcpi_wait  (pcpi_wait),
    .pcpi_ready (pcpi_ready)
   );

endmodule
