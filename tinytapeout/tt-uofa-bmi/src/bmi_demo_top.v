/* --------------------------------------------------------------------------------------------
     PicoRV32 + Bit-Manipulation Instruction (BMI) co-processor demonstrator

     The BMI unit hangs off the PicoRV32 PCPI port and implements six
     single-cycle bit-manipulation ops on the custom-0 opcode (0001011),
     funct7 = 0000000, funct3 selecting the operation (see bmi_unit.v):
       000 POPCOUNT   001 PARITY   010 BIT-REVERSE
       011 LZCOUNT    100 TZCOUNT  101 AND-NOT (rs1 & ~rs2)

     Integration top for tapeout: a hardwired boot ROM runs a self-test
     program that exercises four of the BMI ops and latches the results
     into capture registers driving chip outputs, so the silicon is
     testable without any external memory.

     Memory map:
       0x0000_0000 - 0x0000_00FF  boot ROM (hardwired self-test program)
       0x0000_2000 - 0x0000_200F  result capture registers -> chip outputs
     Every other address answers with rdata 0 (no unmapped-access hang).

     Self-test program: x1 = 0x0F0F00FF, x2 = 0x00FF00F0, then
       result_popcnt = POPCOUNT(x1) = 0x00000010  (16 one bits)
       result_clz    = LZCOUNT(x1)  = 0x00000004  (4 leading zeros)
       result_rev    = REVERSE(x1)  = 0xFF00F0F0
       result_andn   = x1 & ~x2     = 0x0F00000F
       test_done     = 1 (set by the final result store)
----------------------------------------------------------------------------------------------*/

module bmi_demo_top (
    input  wire        clk,
    input  wire        resetn,
    output wire        trap,
    output reg         test_done,
    output reg  [31:0] result_popcnt,
    output reg  [31:0] result_clz,
    output reg  [31:0] result_rev,
    output reg  [31:0] result_andn
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
    // Boot ROM: hardwired BMI self-test program
    // ------------------------------------------------------------------
    // x1 = 0x0F0F00FF (imm[11] of the ADDI is 0, so no sign extension)
    localparam [31:0] I_LUI_X1  = {20'h0F0F0, 5'd1, 7'b0110111};
    localparam [31:0] I_ADDI_X1 = {12'h0FF, 5'd1, 3'b000, 5'd1, 7'b0010011};
    // x2 = 0x00FF00F0 (second operand for AND-NOT; imm[11] again 0)
    localparam [31:0] I_LUI_X2  = {20'h00FF0, 5'd2, 7'b0110111};
    localparam [31:0] I_ADDI_X2 = {12'h0F0, 5'd2, 3'b000, 5'd2, 7'b0010011};
    // BMI ops: {funct7=0000000, rs2, rs1, funct3, rd, custom-0}
    localparam [31:0] I_POPCNT_X3 = {7'b0000000, 5'd0, 5'd1, 3'b000, 5'd3, 7'b0001011};
    localparam [31:0] I_CLZ_X4    = {7'b0000000, 5'd0, 5'd1, 3'b011, 5'd4, 7'b0001011};
    localparam [31:0] I_REV_X5    = {7'b0000000, 5'd0, 5'd1, 3'b010, 5'd5, 7'b0001011};
    localparam [31:0] I_ANDN_X6   = {7'b0000000, 5'd2, 5'd1, 3'b101, 5'd6, 7'b0001011};
    // x10 = 0x2000 (result capture base)
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
            6'd2:  rom_word = I_LUI_X2;
            6'd3:  rom_word = I_ADDI_X2;
            6'd4:  rom_word = I_POPCNT_X3;
            6'd5:  rom_word = I_CLZ_X4;
            6'd6:  rom_word = I_REV_X5;
            6'd7:  rom_word = I_ANDN_X6;
            6'd8:  rom_word = I_LUI_X10;
            6'd9:  rom_word = I_SW_X3_R0;
            6'd10: rom_word = I_SW_X4_R4;
            6'd11: rom_word = I_SW_X5_R8;
            6'd12: rom_word = I_SW_X6_RC;
            6'd13: rom_word = I_LOOP;
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
            test_done     <= 1'b0;
            result_popcnt <= 32'h0;
            result_clz    <= 32'h0;
            result_rev    <= 32'h0;
            result_andn   <= 32'h0;
        end else if (mem_valid && mem_ready && res_sel && mem_wstrb == 4'b1111) begin
            case (mem_addr[3:2])
                2'd0: result_popcnt <= mem_wdata;
                2'd1: result_clz    <= mem_wdata;
                2'd2: result_rev    <= mem_wdata;
                2'd3: begin
                    result_andn <= mem_wdata;
                    test_done   <= 1'b1;
                end
            endcase
        end
    end

    // instantiate picorv32 - ENABLE_PCPI is REQUIRED, or the BMI unit is
    // dead logic and synthesis deletes it from the netlist
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

    // instantiate the BMI co-processor on the PCPI port, exactly as in the
    // original integration harness (combinational single-cycle response;
    // claims custom-0 only for funct7==0 and funct3 <= 101)
    bmi_pcpi bmi (
        .clk       (clk),
        .resetn    (resetn),
        .pcpi_valid(pcpi_valid),
        .pcpi_insn (pcpi_insn),
        .pcpi_rs1  (pcpi_rs1),
        .pcpi_rs2  (pcpi_rs2),
        .pcpi_wr   (pcpi_wr),
        .pcpi_rd   (pcpi_rd),
        .pcpi_wait (pcpi_wait),
        .pcpi_ready(pcpi_ready)
    );

endmodule
