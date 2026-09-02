`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: University of Arizona
// Engineer: Lucas Jimenez
// 
// Create Date: 05/03/2026 06:31:09 PM
// Design Name: Bit Manipulation Instructions Unit
// Module Name: BMU
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision: B
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module BMU (
    input  wire [31:0] data_in,   // Operand from the RISC-V register file 
    input  wire [2:0]  sel_op,    // Operation select: 0=LZC, 1=TZC, 2=Reverse, 3=PopCount
    output reg  [31:0] data_out   // Result to be sent back to the CPU pipeline
);

    integer i;
    reg found;
    reg [5:0] count;
    reg [5:0] bitcount;
    

    always @(*) begin
        // Default values
        data_out = 32'b0;
        count = 32;
        found = 0;
        bitcount = 6'b0;

        case (sel_op)
            // 0: Leading Zero Count (LZC) 
            3'd0: begin
                for (i = 31; i >= 0; i = i - 1) begin
                    if (data_in[i] && !found) begin
                        count = 31 - i;
                        found = 1;
                    end
                end
                data_out = {26'b0, count};
            end

            // 1: Trailing Zero Count (TZC) [cite: 198]
            3'd1: begin
                for (i = 0; i <= 31; i = i + 1) begin
                    if (data_in[i] && !found) begin
                        count = i;
                        found = 1;
                    end
                end
                data_out = {26'b0, count};
            end

            // 2: Bit Reversal 
            3'd2: begin
                for (i = 0; i < 32; i = i + 1) begin
                    data_out[i] = data_in[31 - i];
                end
            end 

            // 3: Bit Population (Popcount) 
            3'd3: begin
    for (i = 0; i < 32; i = i + 1) begin
        if (data_in[i]) begin
            bitcount = bitcount + 1;
        end
    end
     data_out = {26'b0, bitcount};
     end

            default: data_out = 32'b0;
        endcase
    end

endmodule
