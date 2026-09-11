/*
 * slm_gemm_pe — weight-stationary INT8 processing element of the 8x8
 * systolic GEMM array.
 *
 * Holds one signed INT8 weight in a local register (captured when w_load is
 * asserted). Activations flow east (a_in -> a_out, one register stage);
 * partial sums flow south (psum_out = psum_in + a_in * w_reg when a_valid,
 * else psum_in passes through unchanged). All outputs are registered, so
 * activation and partial-sum wavefronts advance one PE per cycle.
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.8.
 */
`default_nettype none

module slm_gemm_pe (
  input  wire               clk,         // clock
  input  wire               rst_n,       // synchronous active-low reset
  input  wire               w_load,      // capture w_in into weight reg
  input  wire signed [7:0]  w_in,        // weight load value
  input  wire               a_valid,     // activation valid this cycle
  input  wire signed [7:0]  a_in,        // activation flowing east
  input  wire signed [31:0] psum_in,     // partial sum flowing south
  output reg                a_valid_out, // registered activation valid (east)
  output reg  signed [7:0]  a_out,       // registered activation (east)
  output reg  signed [31:0] psum_out     // psum_in + a_in * w_reg (south)
);

  reg signed [7:0] w_reg;

  wire signed [15:0] prod = a_in * w_reg;

  always @(posedge clk) begin
    if (!rst_n) begin
      w_reg       <= 8'sd0;
      a_valid_out <= 1'b0;
      a_out       <= 8'sd0;
      psum_out    <= 32'sd0;
    end else begin
      if (w_load)
        w_reg <= w_in;
      a_valid_out <= a_valid;
      a_out       <= a_in;
      psum_out    <= a_valid ? (psum_in + {{16{prod[15]}}, prod}) : psum_in;
    end
  end

endmodule

`default_nettype wire
