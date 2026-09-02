module bmi_unit #(
    parameter WIDTH = 32
)(
    input  [WIDTH-1:0] rs1,
    input  [WIDTH-1:0] rs2,
    input  [2:0]       op,
    output reg [WIDTH-1:0] result
);

    integer i;
    reg [5:0] count;
    reg found;

    always @(*) begin
        result = {WIDTH{1'b0}};
        count  = 6'd0;
        found  = 1'b0;

        case (op)

            // 000: POPCOUNT
            // Count number of 1 bits in rs1
            3'b000: begin
                count = 6'd0;
                for (i = 0; i < WIDTH; i = i + 1) begin
                    count = count + rs1[i];
                end
                result = {{(WIDTH-6){1'b0}}, count};
            end

            // 001: PARITY
            // 1 if odd number of 1 bits, 0 if even
            3'b001: begin
                result = {{(WIDTH-1){1'b0}}, ^rs1};
            end

            // 010: BIT REVERSE
            // Reverse bit order of rs1
            3'b010: begin
                for (i = 0; i < WIDTH; i = i + 1) begin
                    result[i] = rs1[WIDTH-1-i];
                end
            end

            // 011: LEADING ZERO COUNT
            // Count zeros from MSB side
            3'b011: begin
                count = 6'd0;
                found = 1'b0;

                for (i = WIDTH-1; i >= 0; i = i - 1) begin
                    if (!found) begin
                        if (rs1[i] == 1'b0)
                            count = count + 1'b1;
                        else
                            found = 1'b1;
                    end
                end

                result = {{(WIDTH-6){1'b0}}, count};
            end

            // 100: TRAILING ZERO COUNT
            // Count zeros from LSB side
            3'b100: begin
                count = 6'd0;
                found = 1'b0;

                for (i = 0; i < WIDTH; i = i + 1) begin
                    if (!found) begin
                        if (rs1[i] == 1'b0)
                            count = count + 1'b1;
                        else
                            found = 1'b1;
                    end
                end

                result = {{(WIDTH-6){1'b0}}, count};
            end

            // 101: AND-NOT
            // rs1 AND inverted rs2
            3'b101: begin
                result = rs1 & ~rs2;
            end

            default: begin
                result = {WIDTH{1'b0}};
            end

        endcase
    end

endmodule
