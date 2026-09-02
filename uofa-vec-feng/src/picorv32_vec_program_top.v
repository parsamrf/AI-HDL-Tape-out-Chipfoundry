module picorv32_vec_program_top (
    input clk,
    input resetn,
    output trap,
    output reg test_done,
    output reg [31:0] test_result
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

    // Program instructions
    // x1 = 0x01020304
    localparam [31:0] INST_LUI_X1  = {20'h01020, 5'd1, 7'b0110111};
    localparam [31:0] INST_ADDI_X1 = {12'h304, 5'd1, 3'b000, 5'd1, 7'b0010011};

    // x2 = 0x05060708
    localparam [31:0] INST_LUI_X2  = {20'h05060, 5'd2, 7'b0110111};
    localparam [31:0] INST_ADDI_X2 = {12'h708, 5'd2, 3'b000, 5'd2, 7'b0010011};

    // VADD8 x3, x1, x2
    // custom-0 opcode = 0001011
    // funct3 = 000 for VADD8
    localparam [31:0] INST_VADD8_X3_X1_X2 = {
        7'b0000000,
        5'd2,
        5'd1,
        3'b000,
        5'd3,
        7'b0001011
    };

    // sw x3, 256(x0)
    localparam [11:0] STORE_IMM = 12'h100;
    localparam [31:0] INST_SW_X3_RESULT = {
        STORE_IMM[11:5],
        5'd3,
        5'd0,
        3'b010,
        STORE_IMM[4:0],
        7'b0100011
    };

    // jal x0, 0
    localparam [31:0] INST_LOOP = 32'h0000006F;

    always @(*) begin
        mem_ready = 1'b1;

        case (mem_addr[7:2])
            6'd0: mem_rdata = INST_LUI_X1;
            6'd1: mem_rdata = INST_ADDI_X1;
            6'd2: mem_rdata = INST_LUI_X2;
            6'd3: mem_rdata = INST_ADDI_X2;
            6'd4: mem_rdata = INST_VADD8_X3_X1_X2;
            6'd5: mem_rdata = INST_SW_X3_RESULT;
            6'd6: mem_rdata = INST_LOOP;
            default: mem_rdata = 32'h00000013; // NOP
        endcase
    end

    always @(posedge clk) begin
        if (!resetn) begin
            test_done <= 1'b0;
            test_result <= 32'h00000000;
        end else begin
            if (mem_valid && mem_ready && mem_wstrb != 4'b0000 && mem_addr == 32'h00000100) begin
                test_result <= mem_wdata;
                test_done <= 1'b1;
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