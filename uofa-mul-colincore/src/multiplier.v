module multiplier (
    input clk,
    input resetn,
    input start,           // Triggered by custom opcode decoding
    input [31:0] a,        // Operand 1 (pcpi_rs1)
    input [31:0] b,        // Operand 2 (pcpi_rs2)
    output reg [31:0] out, // Result (pcpi_rd)
    output reg done,       // Handshake completion (pcpi_ready)
    output busy            // Prevents CPU 16-cycle timeout (pcpi_wait)
);

    reg [31:0] multiplicand;
    reg [31:0] multiplier_reg;
    reg [31:0] accumulator;
    reg [5:0]  count;
    reg        state;      // 0: IDLE, 1: COMPUTING

    // Registered busy — no one-cycle gap between start and state updating.
    // This prevents the CPU from escaping before the multiplier finishes,
    // and prevents the next multiplication from starting before done clears.
    reg busy_reg;
    assign busy = busy_reg || start;

    always @(posedge clk) begin
        if (!resetn) begin
            state        <= 0;
            done         <= 0;
            busy_reg     <= 0;
            out          <= 0;
            multiplicand <= 0;
            multiplier_reg <= 0;
            accumulator  <= 0;
            count        <= 0;
        end else begin
            case (state)
                0: begin // IDLE
                    done     <= 0;
                    busy_reg <= 0;   // clear busy once fully back in IDLE
                    if (start) begin
                        busy_reg       <= 1; // latch immediately so no gap
                        multiplicand   <= a;
                        multiplier_reg <= b;
                        accumulator    <= 0;
                        count          <= 0;
                        state          <= 1;
                    end
                end
                1: begin // COMPUTING
                    busy_reg <= 1;   // hold busy for entire computation
                    if (count < 32) begin
                        if (multiplier_reg[0])
                            accumulator <= accumulator + multiplicand;
                        multiplicand   <= multiplicand << 1;
                        multiplier_reg <= multiplier_reg >> 1;
                        count          <= count + 1;
                    end else begin
                        out      <= accumulator;
                        done     <= 1;
                        busy_reg <= 0; // release busy at same time as done
                        state    <= 0;
                    end
                end
                default: state <= 0;
            endcase
        end
    end
endmodule