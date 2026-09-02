/*
 * slm_sync — parameterized multi-stage flop synchronizer.
 *
 * Brings asynchronous inputs (reset release, uart_rx, gpio_in) into the clk
 * domain. STAGES >= 2. Reset value of all stages is 0.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.1.
 */
`default_nettype none

module slm_sync #(
  parameter WIDTH  = 1,
  parameter STAGES = 2
) (
  input  wire             clk,
  input  wire             rst_n,
  input  wire [WIDTH-1:0] d,
  output wire [WIDTH-1:0] q
);

  reg [WIDTH-1:0] stage [0:STAGES-1];
  integer i;

  always @(posedge clk) begin
    if (!rst_n) begin
      for (i = 0; i < STAGES; i = i + 1)
        stage[i] <= {WIDTH{1'b0}};
    end else begin
      stage[0] <= d;
      for (i = 1; i < STAGES; i = i + 1)
        stage[i] <= stage[i-1];
    end
  end

  assign q = stage[STAGES-1];

endmodule

`default_nettype wire
