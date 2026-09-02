/*
 * slm_cpu_muldiv — iterative RV32M multiply / divide unit.
 *
 * op (funct3): 0 MUL, 1 MULH, 2 MULHSU, 3 MULHU, 4 DIV, 5 DIVU, 6 REM, 7 REMU.
 * Multiply: 32-cycle shift-add on operand magnitudes, sign fixed at the end.
 * Divide:   32-cycle non-restoring division on magnitudes with final
 *           remainder correction, sign fixed at the end.
 * RISC-V corner semantics (hard requirements):
 *   div  x/0 = -1,        divu x/0 = 2^32-1,
 *   rem  x/0 = x,         remu x/0 = x,
 *   div  INT_MIN/-1 = INT_MIN,  rem INT_MIN/-1 = 0.
 * Handshake: `start` is a 1-cycle pulse, ignored while busy. `done` is a
 * 1-cycle pulse; `result` is registered and holds until the next operation.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.3.
 */
`default_nettype none

module slm_cpu_muldiv (
  input  wire        clk,      // clock
  input  wire        rst_n,    // synchronous active-low reset
  input  wire        start,    // 1-cycle pulse; ignored while busy
  input  wire [2:0]  op,       // funct3 encoding, see header
  input  wire [31:0] in_a,     // rs1 (dividend / multiplicand)
  input  wire [31:0] in_b,     // rs2 (divisor / multiplier)
  output wire        busy,     // operation in progress
  output wire        done,     // 1-cycle pulse, result valid
  output wire [31:0] result   // operation result (held until next start)
);

  localparam [1:0] S_IDLE = 2'd0;
  localparam [1:0] S_MUL  = 2'd1;
  localparam [1:0] S_DIV  = 2'd2;
  localparam [1:0] S_FIN  = 2'd3;

  reg [1:0]  state;
  reg [4:0]  cnt;
  reg [2:0]  op_r;
  reg        neg_q;      // negate product / quotient at the end
  reg        neg_r;      // negate remainder at the end
  reg [63:0] prod;       // multiply working register {acc, multiplicand}
  reg [32:0] rem;        // division partial remainder (extra sign bit)
  reg [31:0] quo;        // division quotient
  reg [31:0] dvd;        // dividend magnitude, MSB-first shift out
  reg [31:0] dsr;        // divisor / multiplier magnitude
  reg        done_r;
  reg [31:0] result_r;

  // Operand signedness by op: mul ops 0/1 both signed, 2 a-only, 3 none;
  // div/rem ops signed when op[0] == 0.
  wire a_sgn = op[2] ? ~op[0] : (op[1:0] != 2'b11);
  wire b_sgn = op[2] ? ~op[0] : ~op[1];

  wire [31:0] mag_a = (a_sgn && in_a[31]) ? (~in_a + 32'd1) : in_a;
  wire [31:0] mag_b = (b_sgn && in_b[31]) ? (~in_b + 32'd1) : in_b;
  wire        sgn_q = (a_sgn && in_a[31]) ^ (b_sgn && in_b[31]);
  wire        sgn_r = a_sgn && in_a[31];

  wire div_by_zero = op[2] && (in_b == 32'b0);
  wire div_ovfl    = op[2] && ~op[0] &&
                     (in_a == 32'h8000_0000) && (in_b == 32'hFFFF_FFFF);

  // Multiply step: conditionally add multiplier into the high half, then
  // shift the whole 64-bit register right by one.
  wire [32:0] madd = {1'b0, prod[63:32]} + (prod[0] ? {1'b0, dsr} : 33'b0);

  // Non-restoring divide step.
  wire [32:0] rsh  = {rem[31:0], dvd[31]};
  wire [32:0] nrem = rem[32] ? (rsh + {1'b0, dsr}) : (rsh - {1'b0, dsr});

  // Final remainder correction (S_FIN).
  wire [32:0] rem_c = rem[32] ? (rem + {1'b0, dsr}) : rem;

  wire [63:0] prod_s = neg_q ? (~prod + 64'd1) : prod;

  always @(posedge clk) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      cnt      <= 5'd0;
      op_r     <= 3'd0;
      neg_q    <= 1'b0;
      neg_r    <= 1'b0;
      prod     <= 64'b0;
      rem      <= 33'b0;
      quo      <= 32'b0;
      dvd      <= 32'b0;
      dsr      <= 32'b0;
      done_r   <= 1'b0;
      result_r <= 32'b0;
    end else begin
      case (state)
        S_IDLE: begin
          done_r <= 1'b0;
          if (start) begin
            op_r <= op;
            cnt  <= 5'd0;
            if (op[2]) begin
              // divide family
              if (div_by_zero) begin
                quo   <= 32'hFFFF_FFFF;
                rem   <= {1'b0, in_a};
                dsr   <= in_b;
                neg_q <= 1'b0;
                neg_r <= 1'b0;
                state <= S_FIN;
              end else if (div_ovfl) begin
                quo   <= 32'h8000_0000;
                rem   <= 33'b0;
                dsr   <= in_b;
                neg_q <= 1'b0;
                neg_r <= 1'b0;
                state <= S_FIN;
              end else begin
                quo   <= 32'b0;
                rem   <= 33'b0;
                dvd   <= mag_a;
                dsr   <= mag_b;
                neg_q <= sgn_q;
                neg_r <= sgn_r;
                state <= S_DIV;
              end
            end else begin
              // multiply family
              prod  <= {32'b0, mag_a};
              dsr   <= mag_b;
              neg_q <= sgn_q;
              state <= S_MUL;
            end
          end
        end

        S_MUL: begin
          prod <= {madd, prod[31:1]};
          cnt  <= cnt + 5'd1;
          if (cnt == 5'd31)
            state <= S_FIN;
        end

        S_DIV: begin
          rem <= nrem;
          dvd <= {dvd[30:0], 1'b0};
          quo <= {quo[30:0], ~nrem[32]};
          cnt <= cnt + 5'd1;
          if (cnt == 5'd31)
            state <= S_FIN;
        end

        default: begin // S_FIN
          if (op_r[2]) begin
            if (!op_r[1])
              result_r <= neg_q ? (~quo + 32'd1) : quo;             // DIV/DIVU
            else
              result_r <= neg_r ? (~rem_c[31:0] + 32'd1) : rem_c[31:0]; // REM/REMU
          end else begin
            result_r <= (op_r == 3'd0) ? prod_s[31:0] : prod_s[63:32];
          end
          done_r <= 1'b1;
          state  <= S_IDLE;
        end
      endcase
    end
  end

  assign busy   = (state != S_IDLE);
  assign done   = done_r;
  assign result = result_r;

  wire _unused = &{1'b0, rem_c[32]};

endmodule

`default_nettype wire
