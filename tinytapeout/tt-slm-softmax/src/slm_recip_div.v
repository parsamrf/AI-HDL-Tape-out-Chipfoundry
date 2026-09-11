/*
 * slm_recip_div — iterative unsigned 32/32 restoring divider.
 *
 * quot = num / den (unsigned, floor). den == 0 returns quot = 32'hFFFF_FFFF
 * (this falls out of restoring division naturally: the remainder is always
 * >= 0, so every quotient bit is set). Latency ~34 cycles: 1 start cycle,
 * 32 iteration cycles, done pulses on the following cycle. start is ignored
 * while busy. num/den are captured on the accepted start cycle.
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.9.
 */
`default_nettype none

module slm_recip_div (
  input  wire        clk,    // clock
  input  wire        rst_n,  // synchronous active-low reset
  input  wire        start,  // 1-cycle pulse; ignored while busy
  input  wire [31:0] num,    // dividend
  input  wire [31:0] den,    // divisor
  output wire        busy,   // high while dividing
  output wire        done,   // 1-cycle pulse with quot valid
  output wire [31:0] quot    // quotient; den==0 -> 32'hFFFF_FFFF
);

  reg        busy_r;
  reg        done_r;
  reg [5:0]  count;    // iterations remaining
  reg [31:0] den_r;
  reg [31:0] num_r;    // dividend bits, MSB first
  reg [31:0] quot_r;
  reg [32:0] rem_r;    // partial remainder

  wire [32:0] rem_shift = {rem_r[31:0], num_r[31]};
  wire [32:0] rem_sub   = rem_shift - {1'b0, den_r};
  wire        ge        = (rem_shift >= {1'b0, den_r});

  always @(posedge clk) begin
    if (!rst_n) begin
      busy_r <= 1'b0;
      done_r <= 1'b0;
      count  <= 6'd0;
      den_r  <= 32'd0;
      num_r  <= 32'd0;
      quot_r <= 32'd0;
      rem_r  <= 33'd0;
    end else begin
      done_r <= 1'b0;
      if (!busy_r) begin
        if (start) begin
          busy_r <= 1'b1;
          count  <= 6'd32;
          den_r  <= den;
          num_r  <= num;
          quot_r <= 32'd0;
          rem_r  <= 33'd0;
        end
      end else begin
        rem_r  <= ge ? rem_sub : rem_shift;
        quot_r <= {quot_r[30:0], ge};
        num_r  <= {num_r[30:0], 1'b0};
        count  <= count - 6'd1;
        if (count == 6'd1) begin
          busy_r <= 1'b0;
          done_r <= 1'b1;
        end
      end
    end
  end

  assign busy = busy_r;
  assign done = done_r;
  assign quot = quot_r;

  wire _unused = &{1'b0, rem_r[32]};

endmodule

`default_nettype wire
