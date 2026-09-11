/*
 * PicoRV32 + memory-mapped GPIO demonstrator with a hardwired boot ROM.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Self-test program: set the low GPIO byte to output, drive 0xA5, read the
 * GPIO input port (upper input byte is fed from the chip pins), then drive
 * the read-back byte onto the outputs and assert test_done. A single end
 * check on the output pins proves the whole CPU -> GPIO-write -> pin and
 * pin -> GPIO-read -> CPU chain.
 *
 * Memory map (every address answered; nothing can hang the CPU):
 *   0x0000_0000  boot ROM (hardwired)
 *   0x0000_2000  GPIO block (DIR +0x0, OUT +0x4, IN +0x8)
 *   0x0000_3000  result register (store here sets test_done)
 */
`default_nettype none

module gpio_demo_top (
    input  wire        clk,
    input  wire        resetn,
    output wire        trap,
    output reg         test_done,
    output reg  [31:0] result0,
    output wire [31:0] gpio_o,
    output wire [31:0] gpio_oe,
    input  wire [31:0] gpio_i
);

    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    reg  [31:0] mem_rdata;

    wire        pcpi_wr = 1'b0;
    wire [31:0] pcpi_rd = 32'b0;
    wire        pcpi_wait = 1'b0;
    wire        pcpi_ready = 1'b0;

    // ------------------------------------------------------------------
    // Address decode + single-pulse ready (answers every address)
    // ------------------------------------------------------------------
    wire rom_sel  = (mem_addr[31:12] == 20'h00000);
    wire gpio_sel = (mem_addr[31:12] == 20'h00002);
    wire res_sel  = (mem_addr[31:12] == 20'h00003);

    always @(posedge clk) begin
        if (!resetn)
            mem_ready <= 1'b0;
        else
            mem_ready <= mem_valid && !mem_ready;
    end

    // ------------------------------------------------------------------
    // Boot ROM
    // ------------------------------------------------------------------
    // x10 = 0x2000 (GPIO base), x11 = 0x3000 (result base)
    localparam [31:0] I_LUI_X10  = {20'h00002, 5'd10, 7'b0110111};
    localparam [31:0] I_LUI_X11  = {20'h00003, 5'd11, 7'b0110111};
    // x2 = 0xFF (DIR: low byte outputs), x3 = 0xA5 (pattern)
    localparam [31:0] I_ADDI_X2  = {12'h0FF, 5'd0, 3'b000, 5'd2, 7'b0010011};
    localparam [31:0] I_ADDI_X3  = {12'h0A5, 5'd0, 3'b000, 5'd3, 7'b0010011};
    // sw x2,0(x10) DIR ; sw x3,4(x10) OUT ; lw x5,8(x10) IN
    localparam [31:0] I_SW_DIR   = {7'b0000000, 5'd2, 5'd10, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_SW_OUT_A5= {7'b0000000, 5'd3, 5'd10, 3'b010, 5'b00100, 7'b0100011};
    localparam [31:0] I_LW_IN    = {12'h008, 5'd10, 3'b010, 5'd5, 7'b0000011};
    // srli x6,x5,8 (input byte lives at IN[15:8])
    localparam [31:0] I_SRLI_X6  = {7'b0000000, 5'd8, 5'd5, 3'b101, 5'd6, 7'b0010011};
    // sw x6,4(x10) OUT = loopback byte ; sw x6,0(x11) result -> test_done
    localparam [31:0] I_SW_OUT_LB= {7'b0000000, 5'd6, 5'd10, 3'b010, 5'b00100, 7'b0100011};
    localparam [31:0] I_SW_RES   = {7'b0000000, 5'd6, 5'd11, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_LOOP     = 32'h0000006F;

    reg [31:0] rom_word;
    always @(*) begin
        case (mem_addr[7:2])
            6'd0:  rom_word = I_LUI_X10;
            6'd1:  rom_word = I_LUI_X11;
            6'd2:  rom_word = I_ADDI_X2;
            6'd3:  rom_word = I_ADDI_X3;
            6'd4:  rom_word = I_SW_DIR;
            6'd5:  rom_word = I_SW_OUT_A5;
            6'd6:  rom_word = I_LW_IN;
            6'd7:  rom_word = I_SRLI_X6;
            6'd8:  rom_word = I_SW_OUT_LB;
            6'd9:  rom_word = I_SW_RES;
            6'd10: rom_word = I_LOOP;
            default: rom_word = 32'h0000_0013; // NOP
        endcase
    end

    // ------------------------------------------------------------------
    // GPIO block (combinationally ready inside; strobed by gpio_sel)
    // ------------------------------------------------------------------
    wire [31:0] gpio_rdata;
    wire        gpio_ready_unused;

    gpio #(
        .WIDTH(32),
        .ADDR_BITS(4)
    ) u_gpio (
        .clk       (clk),
        .resetn    (resetn),
        .mem_valid (mem_valid && gpio_sel),
        .mem_ready (gpio_ready_unused),
        .mem_addr  (mem_addr[3:0]),
        .mem_wdata (mem_wdata),
        .mem_wstrb (gpio_sel ? mem_wstrb : 4'b0000),
        .mem_rdata (gpio_rdata),
        .gpio_o    (gpio_o),
        .gpio_oe   (gpio_oe),
        .gpio_i    (gpio_i)
    );

    always @(*) begin
        if (rom_sel)       mem_rdata = rom_word;
        else if (gpio_sel) mem_rdata = gpio_rdata;
        else               mem_rdata = 32'h0000_0000;
    end

    // ------------------------------------------------------------------
    // Result capture
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            test_done <= 1'b0;
            result0   <= 32'h0;
        end else if (mem_valid && mem_ready && res_sel && mem_wstrb == 4'b1111) begin
            result0   <= mem_wdata;
            test_done <= 1'b1;
        end
    end

    picorv32 #(
        .ENABLE_PCPI(0),
        .ENABLE_MUL(0),
        .ENABLE_DIV(0),
        .ENABLE_FAST_MUL(0)
    ) cpu (
        .clk       (clk),
        .resetn    (resetn),
        .trap      (trap),
        .mem_valid (mem_valid),
        .mem_instr (mem_instr),
        .mem_ready (mem_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata),
        .mem_la_read  (),
        .mem_la_write (),
        .mem_la_addr  (),
        .mem_la_wdata (),
        .mem_la_wstrb (),
        .pcpi_valid (),
        .pcpi_insn  (),
        .pcpi_rs1   (),
        .pcpi_rs2   (),
        .pcpi_wr    (pcpi_wr),
        .pcpi_rd    (pcpi_rd),
        .pcpi_wait  (pcpi_wait),
        .pcpi_ready (pcpi_ready),
        .irq        (32'b0),
        .eoi        (),
        .trace_valid(),
        .trace_data ()
    );

endmodule
