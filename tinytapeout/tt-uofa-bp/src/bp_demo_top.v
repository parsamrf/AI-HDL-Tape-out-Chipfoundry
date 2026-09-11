/* --------------------------------------------------------------------------------------------
     PicoRV32 + Neural Branch Predictor (perceptron BHT) demonstrator
     SPDX-License-Identifier: Apache-2.0

     The neural_bht is a 4-entry perceptron branch history table trained from
     the picorv32 TRACE interface (ENABLE_TRACE=1): every retired branch
     (trace_data[35:32] == TRACE_BRANCH) trains the table, and the request
     port continuously predicts on the current memory address, exactly as in
     the original integration top.

     A hardwired boot ROM runs a counted-loop self-test so the predictor sees
     real backward-branch traffic, and the results are latched into capture
     registers driving chip outputs:

     Memory map:
       0x0000_0000 - 0x0000_00FF  boot ROM (hardwired self-test program)
       0x0000_1000 - 0x0000_107F  128 B RAM (32 x 32-bit words)
       0x0000_2000 - 0x0000_200F  result capture registers -> chip outputs
     Every other address answers with rdata 0 (no unmapped-access hang).

     ROM program:
       x1 = 0; x2 = 8;
       loop: x1 = x1 + 1; if (x1 != x2) goto loop;   // BNE taken 7x, then falls through
       result0 = x1;                                  // expect 8
       x3 = 32'h600D600D;
       result1 = x3;                                  // sanity constant
       x4 = x1 + x3;                                  // 0x600D6015
       RAM[2] = x4; x5 = RAM[2];
       result3 = x5;                                  // SW/LW round-trip, sets test_done
       park (jal x0, 0)

     result2 is NOT written by the CPU: it is a hardware counter of cycles
     where bht_predict_taken was high before test_done (the CPU cannot read
     the predictor, so the count is exposed directly as a result register).

     Expected results (checked by test/test.py):
       result0 = 0x00000008
       result1 = 0x600D600D
       result2 = nonzero, less than total run cycles (timing-dependent)
       result3 = 0x600D6015
       test_done = 1, trap = 0
----------------------------------------------------------------------------------------------*/

module bp_demo_top (
    input  wire        clk,
    input  wire        resetn,
    output wire        trap,
    output reg         test_done,
    output wire        bht_predict_taken,
    output reg  [31:0] result0,
    output reg  [31:0] result1,
    output wire [31:0] result2,
    output reg  [31:0] result3
);

    // PicoRV32 memory interface
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    reg  [31:0] mem_rdata;

    // Trace Interface (feeds the neural BHT)
    wire        trace_valid;
    wire [35:0] trace_data;

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
    // Boot ROM: hardwired counted-loop self-test program
    // ------------------------------------------------------------------
    // x1 = 0; x2 = 8 (loop bound)
    localparam [31:0] I_ADDI_X1_0 = {12'h000, 5'd0, 3'b000, 5'd1, 7'b0010011};
    localparam [31:0] I_ADDI_X2_8 = {12'h008, 5'd0, 3'b000, 5'd2, 7'b0010011};
    // loop body: x1 = x1 + 1
    localparam [31:0] I_ADDI_X1_1 = {12'h001, 5'd1, 3'b000, 5'd1, 7'b0010011};
    // bne x1, x2, -4  (branch at word 3 / byte 0xC back to word 2 / byte 0x8)
    // offset -4 -> imm[12:0] = 1_1111_1111_1100:
    //   imm[12]=1, imm[11]=1, imm[10:5]=111111, imm[4:1]=1110, imm[0]=0 (implicit)
    localparam [31:0] I_BNE_BACK4 = {1'b1, 6'b111111, 5'd2, 5'd1, 3'b001, 4'b1110, 1'b1, 7'b1100011};
    // x10 = 0x2000 (result base), x9 = 0x1000 (RAM base)
    localparam [31:0] I_LUI_X10   = {20'h00002, 5'd10, 7'b0110111};
    localparam [31:0] I_LUI_X9    = {20'h00001, 5'd9,  7'b0110111};
    // x3 = 0x600D600D (LUI 0x600D6 then ADDI 0x00D; imm bit 11 = 0, no sign extension)
    localparam [31:0] I_LUI_X3    = {20'h600D6, 5'd3, 7'b0110111};
    localparam [31:0] I_ADDI_X3   = {12'h00D, 5'd3, 3'b000, 5'd3, 7'b0010011};
    // x4 = x1 + x3 = 8 + 0x600D600D = 0x600D6015 (round-trip payload)
    localparam [31:0] I_ADD_X4    = {7'b0000000, 5'd3, 5'd1, 3'b000, 5'd4, 7'b0110011};
    // RAM round-trip: sw x4, 8(x9); lw x5, 8(x9)
    localparam [31:0] I_SW_X4_RAM = {7'b0000000, 5'd4, 5'd9, 3'b010, 5'b01000, 7'b0100011};
    localparam [31:0] I_LW_X5_RAM = {12'h008, 5'd9, 3'b010, 5'd5, 7'b0000011};
    // result stores: sw xN, imm(x10)
    localparam [31:0] I_SW_X1_R0  = {7'b0000000, 5'd1, 5'd10, 3'b010, 5'b00000, 7'b0100011};
    localparam [31:0] I_SW_X3_R4  = {7'b0000000, 5'd3, 5'd10, 3'b010, 5'b00100, 7'b0100011};
    localparam [31:0] I_SW_X5_RC  = {7'b0000000, 5'd5, 5'd10, 3'b010, 5'b01100, 7'b0100011};
    // jal x0, 0 (park)
    localparam [31:0] I_LOOP      = 32'h0000006F;

    reg [31:0] rom_word;
    always @(*) begin
        case (mem_addr[7:2])
            6'd0:  rom_word = I_ADDI_X1_0;
            6'd1:  rom_word = I_ADDI_X2_8;
            6'd2:  rom_word = I_ADDI_X1_1;  // <- loop target
            6'd3:  rom_word = I_BNE_BACK4;  // backward branch, taken 7 times
            6'd4:  rom_word = I_LUI_X10;
            6'd5:  rom_word = I_SW_X1_R0;   // result0 = 8
            6'd6:  rom_word = I_LUI_X3;
            6'd7:  rom_word = I_ADDI_X3;
            6'd8:  rom_word = I_SW_X3_R4;   // result1 = 0x600D600D
            6'd9:  rom_word = I_ADD_X4;
            6'd10: rom_word = I_LUI_X9;
            6'd11: rom_word = I_SW_X4_RAM;  // RAM[2] = 0x600D6015
            6'd12: rom_word = I_LW_X5_RAM;  // x5 = RAM[2]
            6'd13: rom_word = I_SW_X5_RC;   // result3 = round-trip word, test_done
            6'd14: rom_word = I_LOOP;
            default: rom_word = 32'h0000_0013; // NOP
        endcase
    end

    // ------------------------------------------------------------------
    // Small RAM at 0x1000: 32 x 32-bit words, synchronous read
    // (read data is registered, valid on the mem_ready cycle)
    // ------------------------------------------------------------------
    reg [31:0] ram [0:31];
    reg [31:0] ram_rdata;
    always @(posedge clk) begin
        if (mem_valid && ram_sel) begin
            if (mem_wstrb[0]) ram[mem_addr[6:2]][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wstrb[1]) ram[mem_addr[6:2]][15: 8] <= mem_wdata[15: 8];
            if (mem_wstrb[2]) ram[mem_addr[6:2]][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) ram[mem_addr[6:2]][31:24] <= mem_wdata[31:24];
            ram_rdata <= ram[mem_addr[6:2]];
        end
    end

    // ------------------------------------------------------------------
    // Read-data return mux (address is held stable through the ready cycle)
    // ------------------------------------------------------------------
    always @(*) begin
        if (rom_sel)      mem_rdata = rom_word;
        else if (ram_sel) mem_rdata = ram_rdata;
        else              mem_rdata = 32'h0000_0000;
    end

    // ------------------------------------------------------------------
    // Result capture registers -> chip outputs
    // (result2 is the hardware predictor-taken cycle counter, not CPU-written)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            test_done <= 1'b0;
            result0   <= 32'h0;
            result1   <= 32'h0;
            result3   <= 32'h0;
        end else if (mem_valid && mem_ready && res_sel && mem_wstrb == 4'b1111) begin
            case (mem_addr[3:2])
                2'd0: result0 <= mem_wdata;
                2'd1: result1 <= mem_wdata;
                2'd3: begin
                    result3   <= mem_wdata;
                    test_done <= 1'b1;
                end
                default: ; // slot 2 is the hardware counter, CPU writes ignored
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Neural BHT wiring (same as the original integration top):
    // predict on the current memory address, train on every retired branch
    // from the trace stream.
    // ------------------------------------------------------------------

    // In picorv32, trace_data[35:32] == 1 denotes a TRACE_BRANCH
    wire is_trace_branch = (trace_data[35:32] == 4'b0001);

    // Simplified training feedback for demonstration
    wire bht_train_valid = trace_valid && is_trace_branch;
    wire bht_train_taken = 1'b1;
    wire bht_miss        = 1'b1;

    // Count the cycles where the predictor says "taken" while the self-test
    // is still running; exposed as result register 2 (the CPU cannot read
    // the predictor, so the observation point is pure hardware).
    reg [31:0] bht_taken_count;
    always @(posedge clk) begin
        if (!resetn)
            bht_taken_count <= 32'h0;
        else if (!test_done && bht_predict_taken)
            bht_taken_count <= bht_taken_count + 1;
    end
    assign result2 = bht_taken_count;

    // PicoRV32 core (trace enabled so the BHT gets branch retirement info)
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

    wire _unused = &{mem_instr, 1'b0};

endmodule
