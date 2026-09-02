module picorv32_vec_all_program_top (
    input clk,
    input resetn,
    output trap,
    output reg test_done,
    output reg [31:0] result_vadd8,
    output reg [31:0] result_vsub8,
    output reg [31:0] result_vand,
    output reg [31:0] result_vor
);

    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    wire        mem_la_read;
    wire        mem_la_write;
    wire [31:0] mem_la_addr;
    wire [31:0] mem_la_wdata;
    wire [3:0]  mem_la_wstrb;

    wire        pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    wire [31:0] irq;
    wire [31:0] eoi;
    wire        trace_valid;
    wire [35:0] trace_data;

    assign irq = 32'b0;

    // x1 = 0x01020304
    localparam [31:0] INST_LUI_X1_A  = {20'h01020, 5'd1, 7'b0110111};
    localparam [31:0] INST_ADDI_X1_A = {12'h304, 5'd1, 3'b000, 5'd1, 7'b0010011};

    // x2 = 0x05060708
    localparam [31:0] INST_LUI_X2_A  = {20'h05060, 5'd2, 7'b0110111};
    localparam [31:0] INST_ADDI_X2_A = {12'h708, 5'd2, 3'b000, 5'd2, 7'b0010011};

    // VADD8 x3, x1, x2
    localparam [31:0] INST_VADD8_X3_X1_X2 = {
        7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0001011
    };

    // VSUB8 x4, x2, x1
    localparam [31:0] INST_VSUB8_X4_X2_X1 = {
        7'b0000000, 5'd1, 5'd2, 3'b001, 5'd4, 7'b0001011
    };

    // VAND x5, x1, x2
    localparam [31:0] INST_VAND_X5_X1_X2 = {
        7'b0000000, 5'd2, 5'd1, 3'b010, 5'd5, 7'b0001011
    };

    // VOR x6, x1, x2
    localparam [31:0] INST_VOR_X6_X1_X2 = {
        7'b0000000, 5'd2, 5'd1, 3'b011, 5'd6, 7'b0001011
    };

    // sw instructions
    // sw x3, 0x100(x0)
    localparam [11:0] IMM_100 = 12'h100;
    localparam [31:0] INST_SW_X3_100 = {
        IMM_100[11:5], 5'd3, 5'd0, 3'b010, IMM_100[4:0], 7'b0100011
    };

    // sw x4, 0x104(x0)
    localparam [11:0] IMM_104 = 12'h104;
    localparam [31:0] INST_SW_X4_104 = {
        IMM_104[11:5], 5'd4, 5'd0, 3'b010, IMM_104[4:0], 7'b0100011
    };

    // sw x5, 0x108(x0)
    localparam [11:0] IMM_108 = 12'h108;
    localparam [31:0] INST_SW_X5_108 = {
        IMM_108[11:5], 5'd5, 5'd0, 3'b010, IMM_108[4:0], 7'b0100011
    };

    // sw x6, 0x10C(x0)
    localparam [11:0] IMM_10C = 12'h10C;
    localparam [31:0] INST_SW_X6_10C = {
        IMM_10C[11:5], 5'd6, 5'd0, 3'b010, IMM_10C[4:0], 7'b0100011
    };

    // jal x0, 0
    localparam [31:0] INST_LOOP = 32'h0000006F;

    always @(*) begin
        mem_ready = 1'b1;

        // Only the 256-byte ROM window decodes instructions; everything else
        // reads as 0 so a runaway PC or data load can never alias back into
        // the ROM (mem_addr[7:2] alone would mirror it across all 4 GB).
        if (mem_addr >= 32'h0000_0100)
            mem_rdata = 32'h0000_0000;
        else
        case (mem_addr[7:2])
            6'd0:  mem_rdata = INST_LUI_X1_A;
            6'd1:  mem_rdata = INST_ADDI_X1_A;
            6'd2:  mem_rdata = INST_LUI_X2_A;
            6'd3:  mem_rdata = INST_ADDI_X2_A;
            6'd4:  mem_rdata = INST_VADD8_X3_X1_X2;
            6'd5:  mem_rdata = INST_VSUB8_X4_X2_X1;
            6'd6:  mem_rdata = INST_VAND_X5_X1_X2;
            6'd7:  mem_rdata = INST_VOR_X6_X1_X2;
            6'd8:  mem_rdata = INST_SW_X3_100;
            6'd9:  mem_rdata = INST_SW_X4_104;
            6'd10: mem_rdata = INST_SW_X5_108;
            6'd11: mem_rdata = INST_SW_X6_10C;
            6'd12: mem_rdata = INST_LOOP;
            default: mem_rdata = 32'h00000013;
        endcase
    end

    always @(posedge clk) begin
        if (!resetn) begin
            test_done <= 1'b0;
            result_vadd8 <= 32'h00000000;
            result_vsub8 <= 32'h00000000;
            result_vand  <= 32'h00000000;
            result_vor   <= 32'h00000000;
        end else begin
            if (mem_valid && mem_ready && mem_wstrb != 4'b0000) begin
                case (mem_addr)
                    32'h00000100: result_vadd8 <= mem_wdata;
                    32'h00000104: result_vsub8 <= mem_wdata;
                    32'h00000108: result_vand  <= mem_wdata;
                    32'h0000010C: begin
                        result_vor <= mem_wdata;
                        test_done <= 1'b1;
                    end
                endcase
            end
        end
    end

    picorv32 #(
        .ENABLE_PCPI(1),
        .ENABLE_MUL(0),
        .ENABLE_DIV(0),
        .ENABLE_FAST_MUL(0)
    ) cpu (
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

        .mem_la_read(mem_la_read),
        .mem_la_write(mem_la_write),
        .mem_la_addr(mem_la_addr),
        .mem_la_wdata(mem_la_wdata),
        .mem_la_wstrb(mem_la_wstrb),

        .pcpi_valid(pcpi_valid),
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1),
        .pcpi_rs2(pcpi_rs2),
        .pcpi_wr(pcpi_wr),
        .pcpi_rd(pcpi_rd),
        .pcpi_wait(pcpi_wait),
        .pcpi_ready(pcpi_ready),

        .irq(irq),
        .eoi(eoi),

        .trace_valid(trace_valid),
        .trace_data(trace_data)
    );

    picorv32_pcpi_vec vec_unit (
        .clk(clk),
        .resetn(resetn),

        .pcpi_valid(pcpi_valid),
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1),
        .pcpi_rs2(pcpi_rs2),

        .pcpi_wr(pcpi_wr),
        .pcpi_rd(pcpi_rd),
        .pcpi_wait(pcpi_wait),
        .pcpi_ready(pcpi_ready)
    );

endmodule