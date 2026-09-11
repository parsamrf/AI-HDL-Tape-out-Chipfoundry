/*
 * RV32IM CPU demonstrator with a hardwired boot ROM.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The five-stage RV32IM core (with forwarding, iterative mul/div, and CSRs)
 * boots from a hardwired ROM on its fetch port and runs a self-test:
 * 32x32 multiply, signed divide and remainder (RV32M), and a store/load
 * round-trip through a small data RAM on its SLB data port. Four 32-bit
 * results are latched; test_done asserts on the final store.
 *
 * Data-port map (every request answered; nothing can hang):
 *   0x0000_1000  32-word RAM
 *   0x0000_2000  result registers (+0,+4,+8,+12; +12 sets test_done)
 */
`default_nettype none

module cpu_demo_top (
    input  wire        clk,
    input  wire        rst_n,
    output reg         test_done,
    output reg  [31:0] result0,
    output reg  [31:0] result1,
    output reg  [31:0] result2,
    output reg  [31:0] result3
);

    // ------------------------------------------------------------------
    // Fetch port: registered boot ROM (if_rdata valid the cycle after
    // if_addr, exactly the contract slm_cpu_top expects)
    // ------------------------------------------------------------------
    wire [31:0] if_addr;
    reg  [31:0] if_rdata;

    // x1 = 0x00001234, x2 = 0x00005678
    localparam [31:0] I_LUI_X1  = {20'h00001, 5'd1, 7'b0110111};
    localparam [31:0] I_ADDI_X1 = {12'h234, 5'd1, 3'b000, 5'd1, 7'b0010011};
    localparam [31:0] I_LUI_X2  = {20'h00005, 5'd2, 7'b0110111};
    localparam [31:0] I_ADDI_X2 = {12'h678, 5'd2, 3'b000, 5'd2, 7'b0010011};
    // MUL x3,x1,x2 (RV32M: funct7=0000001)
    localparam [31:0] I_MUL_X3  = {7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0110011};
    // x4 = -100, x5 = 7
    localparam [31:0] I_ADDI_X4 = {12'hF9C, 5'd0, 3'b000, 5'd4, 7'b0010011};
    localparam [31:0] I_ADDI_X5 = {12'h007, 5'd0, 3'b000, 5'd5, 7'b0010011};
    // DIV x6,x4,x5 ; REM x7,x4,x5
    localparam [31:0] I_DIV_X6  = {7'b0000001, 5'd5, 5'd4, 3'b100, 5'd6, 7'b0110011};
    localparam [31:0] I_REM_X7  = {7'b0000001, 5'd5, 5'd4, 3'b110, 5'd7, 7'b0110011};
    // x9 = 0x1000 (RAM), x10 = 0x2000 (results)
    localparam [31:0] I_LUI_X9  = {20'h00001, 5'd9,  7'b0110111};
    localparam [31:0] I_LUI_X10 = {20'h00002, 5'd10, 7'b0110111};
    // sw x3,0(x9) ; lw x8,0(x9)
    localparam [31:0] I_SW_RAM  = {7'b0000000, 5'd3, 5'd9, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_LW_RAM  = {12'h000, 5'd9, 3'b010, 5'd8, 7'b0000011};
    // result stores
    localparam [31:0] I_SW_R0 = {7'b0000000, 5'd3, 5'd10, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_SW_R1 = {7'b0000000, 5'd6, 5'd10, 3'b010, 5'b00100, 7'b0100011};
    localparam [31:0] I_SW_R2 = {7'b0000000, 5'd7, 5'd10, 3'b010, 5'b01000, 7'b0100011};
    localparam [31:0] I_SW_R3 = {7'b0000000, 5'd8, 5'd10, 3'b010, 5'b01100, 7'b0100011};
    localparam [31:0] I_LOOP  = 32'h0000006F;

    reg [31:0] rom_word;
    always @(*) begin
        case (if_addr[7:2])
            6'd0:  rom_word = I_LUI_X1;
            6'd1:  rom_word = I_ADDI_X1;
            6'd2:  rom_word = I_LUI_X2;
            6'd3:  rom_word = I_ADDI_X2;
            6'd4:  rom_word = I_MUL_X3;
            6'd5:  rom_word = I_ADDI_X4;
            6'd6:  rom_word = I_ADDI_X5;
            6'd7:  rom_word = I_DIV_X6;
            6'd8:  rom_word = I_REM_X7;
            6'd9:  rom_word = I_LUI_X9;
            6'd10: rom_word = I_LUI_X10;
            6'd11: rom_word = I_SW_RAM;
            6'd12: rom_word = I_LW_RAM;
            6'd13: rom_word = I_SW_R0;
            6'd14: rom_word = I_SW_R1;
            6'd15: rom_word = I_SW_R2;
            6'd16: rom_word = I_SW_R3;
            6'd17: rom_word = I_LOOP;
            default: rom_word = 32'h0000_0013;
        endcase
    end

    always @(posedge clk) if_rdata <= rom_word;

    // ------------------------------------------------------------------
    // Data SLB slave: RAM + results, always ready, 1-cycle response
    // ------------------------------------------------------------------
    wire        d_req_valid, d_req_write;
    wire [31:0] d_req_addr, d_req_wdata;
    wire [3:0]  d_req_wstrb;
    reg         d_rsp_valid;
    reg  [31:0] d_rsp_rdata;

    wire ram_sel = (d_req_addr[31:12] == 20'h00001);
    wire res_sel = (d_req_addr[31:12] == 20'h00002);

    reg [31:0] ram [0:31];
    wire [4:0] widx = d_req_addr[6:2];

    always @(posedge clk) begin
        if (!rst_n) begin
            d_rsp_valid <= 1'b0;
            d_rsp_rdata <= 32'h0;
            test_done   <= 1'b0;
            result0 <= 32'h0; result1 <= 32'h0; result2 <= 32'h0; result3 <= 32'h0;
        end else begin
            d_rsp_valid <= d_req_valid;
            d_rsp_rdata <= 32'h0;
            if (d_req_valid && !d_req_write && ram_sel)
                d_rsp_rdata <= ram[widx];
            if (d_req_valid && d_req_write && ram_sel) begin
                if (d_req_wstrb[0]) ram[widx][ 7: 0] <= d_req_wdata[ 7: 0];
                if (d_req_wstrb[1]) ram[widx][15: 8] <= d_req_wdata[15: 8];
                if (d_req_wstrb[2]) ram[widx][23:16] <= d_req_wdata[23:16];
                if (d_req_wstrb[3]) ram[widx][31:24] <= d_req_wdata[31:24];
            end
            if (d_req_valid && d_req_write && res_sel && d_req_wstrb == 4'b1111) begin
                case (d_req_addr[3:2])
                    2'd0: result0 <= d_req_wdata;
                    2'd1: result1 <= d_req_wdata;
                    2'd2: result2 <= d_req_wdata;
                    2'd3: begin result3 <= d_req_wdata; test_done <= 1'b1; end
                endcase
            end
        end
    end

    slm_cpu_top #(
        .RESET_PC(32'h0000_0000)
    ) cpu (
        .clk         (clk),
        .rst_n       (rst_n),
        .if_addr     (if_addr),
        .if_rdata    (if_rdata),
        .d_req_valid (d_req_valid),
        .d_req_ready (1'b1),
        .d_req_write (d_req_write),
        .d_req_addr  (d_req_addr),
        .d_req_wdata (d_req_wdata),
        .d_req_wstrb (d_req_wstrb),
        .d_rsp_valid (d_rsp_valid),
        .d_rsp_rdata (d_rsp_rdata),
        .irq_timer   (1'b0),
        .irq_external(1'b0)
    );

endmodule
