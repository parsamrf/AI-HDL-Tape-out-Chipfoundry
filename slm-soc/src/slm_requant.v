/*
 * slm_requant — INT32 -> INT8 requantization stage.
 *
 * out_q = sat8( ((in_acc * cfg_scale) >>> cfg_shift) + cfg_zp )
 *
 * The 64-bit signed product is arithmetically shifted right by cfg_shift
 * (0..31), the signed zero-point is added, and the result saturates to
 * [-128, 127]. One-cycle latency; out_valid follows in_valid by one cycle.
 * Shared by the GEMM drain path, softmax, and RMSNorm units, and directly
 * exercised by their testbenches.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.2.
 */
`default_nettype none

module slm_requant (
  input  wire               clk,
  input  wire               rst_n,
  input  wire               in_valid,
  input  wire signed [31:0] in_acc,      // accumulator value
  input  wire signed [31:0] cfg_scale,   // fixed-point multiplier
  input  wire        [4:0]  cfg_shift,   // arithmetic right shift amount
  input  wire signed [7:0]  cfg_zp,      // output zero point
  output reg                out_valid,
  output reg  signed [7:0]  out_q
);

  wire signed [63:0] product = in_acc * cfg_scale;
  wire signed [63:0] shifted = product >>> cfg_shift;
  wire signed [63:0] biased  = shifted + {{56{cfg_zp[7]}}, cfg_zp};

  wire signed [7:0] saturated = (biased > 64'sd127)  ? 8'sd127 :
                                (biased < -64'sd128) ? -8'sd128 :
                                                       biased[7:0];

  always @(posedge clk) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_q     <= 8'sd0;
    end else begin
      out_valid <= in_valid;
      if (in_valid)
        out_q <= saturated;
    end
  end

endmodule

`default_nettype wire
