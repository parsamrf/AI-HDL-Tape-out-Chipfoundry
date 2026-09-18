/*
 * slm_invsqrt — fixed-point reciprocal square root, Q1.15.
 *
 * out_r = round(32768 / sqrt(v)) for v in [1, 2^20] (spec accuracy +-4 LSB;
 * this implementation is exactly rounded, ties away from the floor).
 * Method: bit-serial search for the largest r with r^2 * v <= 2^30 (i.e.
 * r = floor(sqrt(2^30 / v))), then one rounding step: r += 1 when
 * (2r + 1)^2 * v <= 2^32, which is exactly the (r + 0.5)^2 * v <= 2^30
 * midpoint test. No LUT/Newton seed needed; the trial multiplies are
 * combinational per iteration. Latency ~19 cycles (1 start + 16 search +
 * 1 round + done). start is ignored while busy; in_v is captured at start;
 * out_r holds after done. v = 1 yields 32768 (fits in 16 bits unsigned).
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.10.
 */
`default_nettype none

module slm_invsqrt #(
  parameter VW = 32   // v_r width; tile uses 21 (module contract v in [1,2^20])
) (
  input  wire        clk,    // clock
  input  wire        rst_n,  // synchronous active-low reset
  input  wire        start,  // 1-cycle pulse; ignored while busy
  input  wire [31:0] in_v,   // v >= 1
  output wire        busy,   // high while computing
  output wire        done,   // 1-cycle pulse with out_r valid
  output wire [15:0] out_r   // Q1.15: round(32768 / sqrt(v))
);

  localparam [1:0] S_IDLE  = 2'd0;
  localparam [1:0] S_CALC  = 2'd1;
  localparam [1:0] S_ROUND = 2'd2;

  reg [1:0]  state;
  reg        done_r;
  reg [VW-1:0] v_r;
  reg [15:0] r_r;
  reg [3:0]  bit_i;

  // Search and rounding trials run in mutually-exclusive states (S_CALC vs
  // S_ROUND), so they share ONE squarer and ONE multiplier — halving the
  // dominant combinational area for tile routability. Bit-identical to the
  // two-multiplier form:
  //   S_CALC : t  = r | (1<<bit_i); accept when t^2  * v <= 2^30
  //   S_ROUND: t2 = 2r + 1;         accept when t2^2 * v <= 2^32
  wire [15:0] t     = r_r | (16'd1 << bit_i);
  wire [16:0] t2    = {r_r, 1'b1};
  wire [16:0] sq_in = (state == S_ROUND) ? t2 : {1'b0, t};
  wire [33:0] sq    = sq_in * sq_in;               // shared squarer (17x17)
  wire [33+VW:0] prod = sq * v_r;                  // shared multiplier (34xVW)
  wire        p_le  = (prod <= {{(VW){1'b0}}, 34'h0_4000_0000});      // <= 2^30
  wire        p2_le = (prod <= {{(VW-1){1'b0}}, 35'h1_0000_0000});    // <= 2^32

  always @(posedge clk) begin
    if (!rst_n) begin
      state  <= S_IDLE;
      done_r <= 1'b0;
      v_r    <= {{(VW-1){1'b0}}, 1'b1};
      r_r    <= 16'd0;
      bit_i  <= 4'd0;
    end else begin
      done_r <= 1'b0;
      case (state)
        S_IDLE: begin
          if (start) begin
            v_r   <= in_v[VW-1:0];
            r_r   <= 16'd0;
            bit_i <= 4'd15;
            state <= S_CALC;
          end
        end

        S_CALC: begin
          if (p_le)
            r_r <= t;
          if (bit_i == 4'd0)
            state <= S_ROUND;
          bit_i <= bit_i - 4'd1;
        end

        S_ROUND: begin
          if (p2_le)
            r_r <= r_r + 16'd1;
          done_r <= 1'b1;
          state  <= S_IDLE;
        end

        default: begin
          state <= S_IDLE;
        end
      endcase
    end
  end

  assign busy  = (state != S_IDLE);
  assign done  = done_r;
  assign out_r = r_r;

endmodule

`default_nettype wire
