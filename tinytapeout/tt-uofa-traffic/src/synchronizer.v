`default_nettype none

module synchronizer #(
    parameter STAGES = 2,  // Number of flip-flops in the chain
    parameter WIDTH  = 1   // Number of bits to synchronize
)(
    input  wire             clk,      // The destination clock domain
    input  wire [WIDTH-1:0] data_in,  // Asynchronous input from the outside world
    output wire [WIDTH-1:0] data_out  // Synchronized, safe output
);

    // Create a multi-dimensional array of flip-flops: 
    // [STAGES] is how many layers deep, [WIDTH] is how wide the signal is.
    reg [WIDTH-1:0] sync_regs [STAGES-1:0];

    integer i;

    always @(posedge clk) begin
        // The first stage always grabs the raw input
        sync_regs[0] <= data_in;

        // Every subsequent stage grabs the output of the previous one
        for (i = 1; i < STAGES; i = i + 1) begin
            sync_regs[i] <= sync_regs[i-1];
        end
    end

    // The output of the very last stage is the "clean" signal
    assign data_out = sync_regs[STAGES-1];

endmodule
