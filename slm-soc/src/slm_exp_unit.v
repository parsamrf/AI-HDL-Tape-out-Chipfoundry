/*
 * slm_exp_unit — fixed-point power-of-two exponential for the softmax unit.
 *
 * out_e = 2^(in_d/16) in Q1.16 (i.e. 2^(d/16) * 65536) for d in [-255, 0].
 * Implementation: m = -d; integer part m[7:4] selects a right shift, the
 * fraction m[3:0] indexes a 16-entry LUT of round(2^(-f/16) * 65536).
 * Accuracy: |out_e - 2^(d/16)*65536| <= 2 LSB (0.5 LSB LUT rounding plus
 * < 1 LSB truncation from the shift). One-cycle latency; out_valid follows
 * in_valid by one cycle. d = 0 yields exactly 17'd65536.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.9.
 */
`default_nettype none

module slm_exp_unit (
  input  wire              clk,       // clock
  input  wire              rst_n,     // synchronous active-low reset
  input  wire              in_valid,  // input sample valid
  input  wire signed [8:0] in_d,      // d = x - max, range [-255, 0]
  output reg               out_valid, // result valid (1-cycle latency)
  output reg  [16:0]       out_e      // Q1.16: 2^(d/16) * 65536
);

  // m = -d, unsigned magnitude 0..255
  wire signed [8:0] m_s = -in_d;   // d in [-255, 0] so -d fits signed 9 bits
  wire [7:0] m      = m_s[7:0];    // magnitude 0..255
  wire [3:0] i_part = m[7:4];      // integer part of m/16
  wire [3:0] f_part = m[3:0];      // fractional index

  // 16-entry LUT: round(2^(-f/16) * 65536)
  reg [16:0] lut;
  always @(*) begin
    case (f_part)
      4'd0:  lut = 17'd65536;
      4'd1:  lut = 17'd62757;
      4'd2:  lut = 17'd60097;
      4'd3:  lut = 17'd57549;
      4'd4:  lut = 17'd55109;
      4'd5:  lut = 17'd52773;
      4'd6:  lut = 17'd50535;
      4'd7:  lut = 17'd48393;
      4'd8:  lut = 17'd46341;
      4'd9:  lut = 17'd44376;
      4'd10: lut = 17'd42495;
      4'd11: lut = 17'd40693;
      4'd12: lut = 17'd38968;
      4'd13: lut = 17'd37316;
      4'd14: lut = 17'd35734;
      default: lut = 17'd34219; // 4'd15
    endcase
  end

  wire [16:0] shifted = lut >> i_part;

  always @(posedge clk) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_e     <= 17'd0;
    end else begin
      out_valid <= in_valid;
      if (in_valid)
        out_e <= shifted;
    end
  end

  wire _unused = &{1'b0, m_s[8]};

endmodule

`default_nettype wire
