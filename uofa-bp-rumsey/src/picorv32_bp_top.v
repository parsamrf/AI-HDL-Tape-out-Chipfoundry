`timescale 1 ns / 1 ps

module picorv32_bp_top (
    input clk,
    input resetn,

    // Debug outputs
    output        trap,          // a halted CPU must be visible off-chip
    output        mem_valid_out,
    output        mem_instr_out,
    output [31:0] mem_addr_out,
    output [31:0] mem_wdata_out,
    output [ 3:0] mem_wstrb_out,
    output [31:0] sram_rdata_out,
    output        bht_predict_taken_out
);

    // PicoRV32 memory interface
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;

    // SRAM interface
    wire [31:0] sram_dout0;
    wire [31:0] sram_dout1;
    wire [ 8:0] sram_addr;

    // 2 kB SRAM = 512 words x 32 bits
    assign sram_addr = mem_addr[10:2];

    // The SRAM is synchronous, so acknowledge the request one cycle later
    reg mem_ready_reg;

    always @(posedge clk) begin
        if (!resetn)
            mem_ready_reg <= 1'b0;
        else
            mem_ready_reg <= mem_valid;
    end

    assign mem_ready = mem_ready_reg;
    assign mem_rdata = sram_dout0;

    // Debug outputs
    assign mem_valid_out         = mem_valid;
    assign mem_instr_out         = mem_instr;
    assign mem_addr_out          = mem_addr;
    assign mem_wdata_out         = mem_wdata;
    assign mem_wstrb_out         = mem_wstrb;
    assign sram_rdata_out        = mem_rdata;
    assign bht_predict_taken_out = bht_predict_taken;

    // Wires for Neural Branch History Table
    wire        bht_predict_taken;
    wire [35:0] trace_data;
    wire        trace_valid;

    // In picorv32, trace_data[35:32] == 1 denotes a TRACE_BRANCH
    wire is_trace_branch = (trace_data[35:32] == 4'b0001);

    // Simplified training feedback for demonstration
    wire bht_train_valid = trace_valid && is_trace_branch;
    wire bht_train_taken = 1'b1;
    wire bht_miss        = 1'b1;

    // PicoRV32 core
    picorv32 #(
        .ENABLE_TRACE(1)
    ) cpu (
        .clk         (clk),
        .resetn      (resetn),
        .trap        (trap),
        .irq         (32'b0),

        .mem_valid   (mem_valid),
        .mem_instr   (mem_instr),
        .mem_ready   (mem_ready),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_wstrb   (mem_wstrb),
        .mem_rdata   (mem_rdata),

        .trace_valid (trace_valid),
        .trace_data  (trace_data)
    );

    // Neural branch predictor
    neural_bht bht (
        .clk               (clk),
        .reset             (~resetn),

        .req_pc            (mem_addr),
        .req_taken         (bht_predict_taken),

        .update_valid      (bht_train_valid),
        .update_pc         ({trace_data[31:1], 1'b0}),
        .update_taken      (bht_train_taken),
        .update_mispredict (bht_miss)
    );

    // 2 kB SRAM hard macro
    sky130_sram_2kbyte_1rw1r_32x512_8 sram (
        // Port 0: CPU read/write port
        .clk0   (clk),
        .csb0   (~mem_valid),
        .web0   (~(|mem_wstrb)),
        .wmask0 (mem_wstrb),
        .addr0  (sram_addr),
        .din0   (mem_wdata),
        .dout0  (sram_dout0),

        // Port 1: unused read port, tied off
        .clk1   (clk),
        .csb1   (1'b1),
        .addr1  (9'b0),
        .dout1  (sram_dout1)
    );

endmodule
