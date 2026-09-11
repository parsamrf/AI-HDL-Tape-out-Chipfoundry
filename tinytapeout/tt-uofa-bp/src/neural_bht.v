`timescale 1ns / 1ps

module neural_bht (
    input clk,
    input reset,

    // Request port
    input [31:0] req_pc,
    output req_taken,

    // Update port
    input update_valid,
    input [31:0] update_pc,
    input update_taken,
    input update_mispredict
);

    // Small, lightweight BHT parameters
    localparam HIST_LEN    = 3;
    localparam WEIGHT_BITS = 8;
    localparam NUM_ENTRIES = 4;
    localparam ADDR_BITS   = 2;

    // PC hashing for a 4-entry table
    function [ADDR_BITS-1:0] hashAddr;
        input [31:0] pc;
        begin
            hashAddr = pc[3:2] ^ pc[5:4];
        end
    endfunction

    // Global history register
    reg [HIST_LEN-1:0] history;

    // 4-entry x 32-bit perceptron table
    // Each entry stores: {w_h2, w_h1, w_h0, w_bias}
    reg [31:0] weight_table [0:NUM_ENTRIES-1];

    // Combinational hashed addresses
    wire [ADDR_BITS-1:0] read_addr_next   = hashAddr(req_pc);
    wire [ADDR_BITS-1:0] update_addr_next = hashAddr(update_pc);

    // Registered addresses
    reg [ADDR_BITS-1:0] read_addr_reg;
    reg [ADDR_BITS-1:0] update_addr_reg_1;
    reg [ADDR_BITS-1:0] update_addr_reg_2;

    // Registered table outputs
    reg [31:0] pred_weights_reg;
    reg [31:0] update_weights_reg;

    // Pipeline registers for update control/data
    reg                update_valid_reg_1;
    reg                update_valid_reg_2;
    reg                update_taken_reg_1;
    reg                update_taken_reg_2;
    reg                update_mispredict_reg_1;
    reg                update_mispredict_reg_2;
    reg [HIST_LEN-1:0] update_history_reg_1;
    reg [HIST_LEN-1:0] update_history_reg_2;

    // -----------------------------
    // Prediction logic
    // -----------------------------

    wire signed [7:0] w_bias = pred_weights_reg[7:0];
    wire signed [7:0] w_h0   = pred_weights_reg[15:8];
    wire signed [7:0] w_h1   = pred_weights_reg[23:16];
    wire signed [7:0] w_h2   = pred_weights_reg[31:24];

    // Since history terms are only +1 or -1, avoid synthesizing multipliers
    wire signed [8:0] term_h0 = history[0] ? w_h0 : -w_h0;
    wire signed [8:0] term_h1 = history[1] ? w_h1 : -w_h1;
    wire signed [8:0] term_h2 = history[2] ? w_h2 : -w_h2;

    wire signed [15:0] sum =
        w_bias + term_h0 + term_h1 + term_h2;

    assign req_taken = (sum >= 0);

    // -----------------------------
    // Update logic
    // -----------------------------

    wire signed [7:0] up_w_bias = update_weights_reg[7:0];
    wire signed [7:0] up_w_h0   = update_weights_reg[15:8];
    wire signed [7:0] up_w_h1   = update_weights_reg[23:16];
    wire signed [7:0] up_w_h2   = update_weights_reg[31:24];

    wire signed [7:0] delta_bias =
        update_taken_reg_2 ? 8'sd1 : -8'sd1;

    wire signed [7:0] delta_h0 =
        (update_taken_reg_2 == update_history_reg_2[0]) ? 8'sd1 : -8'sd1;

    wire signed [7:0] delta_h1 =
        (update_taken_reg_2 == update_history_reg_2[1]) ? 8'sd1 : -8'sd1;

    wire signed [7:0] delta_h2 =
        (update_taken_reg_2 == update_history_reg_2[2]) ? 8'sd1 : -8'sd1;

    // Saturating add helper
    function signed [7:0] sat_add;
        input signed [7:0] a;
        input signed [7:0] b;
        reg signed [8:0] temp;
        begin
            temp = a + b;
            if (temp > 127)
                sat_add = 8'sd127;
            else if (temp < -128)
                sat_add = -8'sd128;
            else
                sat_add = temp[7:0];
        end
    endfunction

    wire [31:0] next_update_weights = {
        sat_add(up_w_h2,   delta_h2),
        sat_add(up_w_h1,   delta_h1),
        sat_add(up_w_h0,   delta_h0),
        sat_add(up_w_bias, delta_bias)
    };

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            history <= 0;

            read_addr_reg   <= 0;
            update_addr_reg_1 <= 0;
            update_addr_reg_2 <= 0;

            pred_weights_reg   <= 0;
            update_weights_reg <= 0;

            update_valid_reg_1      <= 0;
            update_valid_reg_2      <= 0;
            update_taken_reg_1      <= 0;
            update_taken_reg_2      <= 0;
            update_mispredict_reg_1 <= 0;
            update_mispredict_reg_2 <= 0;
            update_history_reg_1    <= 0;
            update_history_reg_2    <= 0;

            for (i = 0; i < NUM_ENTRIES; i = i + 1)
                weight_table[i] <= 32'b0;
        end else begin
            // Stage 1: register request/update addresses
            read_addr_reg     <= read_addr_next;
            update_addr_reg_1 <= update_addr_next;

            // Stage 2: registered table reads
            pred_weights_reg   <= weight_table[read_addr_reg];
            update_weights_reg <= weight_table[update_addr_reg_1];

            // Pipeline update metadata to stay aligned with the table read
            update_addr_reg_2       <= update_addr_reg_1;

            update_valid_reg_1      <= update_valid;
            update_taken_reg_1      <= update_taken;
            update_mispredict_reg_1 <= update_mispredict;
            update_history_reg_1    <= history;

            update_valid_reg_2      <= update_valid_reg_1;
            update_taken_reg_2      <= update_taken_reg_1;
            update_mispredict_reg_2 <= update_mispredict_reg_1;
            update_history_reg_2    <= update_history_reg_1;

            // Delayed weight update
            if (update_valid_reg_2 && update_mispredict_reg_2)
                weight_table[update_addr_reg_2] <= next_update_weights;

            // Update global history
            if (update_valid)
                history <= {history[HIST_LEN-2:0], update_taken};
        end
    end

endmodule
