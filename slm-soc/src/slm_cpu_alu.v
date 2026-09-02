/*
 * slm_cpu_alu — combinational integer ALU for the RV32IM core.
 *
 * op: 0 ADD, 1 SUB, 2 SLL, 3 SLT, 4 SLTU, 5 XOR, 6 SRL, 7 SRA, 8 OR, 9 AND.
 * The comparison flags eq / lt / ltu are always computed from in_a and in_b
 * (independent of op) and are used by the EX stage for branch resolution.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.3.
 */
`default_nettype none

module slm_cpu_alu (
  input  wire [31:0] in_a,     // operand A
  input  wire [31:0] in_b,     // operand B (shift amount in [4:0])
  input  wire [3:0]  op,       // operation select, see header
  output wire [31:0] result,   // ALU result
  output wire        eq,       // in_a == in_b
  output wire        lt,       // signed in_a < in_b
  output wire        ltu      // unsigned in_a < in_b
);

  assign eq  = (in_a == in_b);
  assign lt  = ($signed(in_a) < $signed(in_b));
  assign ltu = (in_a < in_b);

  reg [31:0] r;

  always @(*) begin
    case (op)
      4'd0:    r = in_a + in_b;                              // ADD
      4'd1:    r = in_a - in_b;                              // SUB
      4'd2:    r = in_a << in_b[4:0];                        // SLL
      4'd3:    r = {31'b0, lt};                              // SLT
      4'd4:    r = {31'b0, ltu};                             // SLTU
      4'd5:    r = in_a ^ in_b;                              // XOR
      4'd6:    r = in_a >> in_b[4:0];                        // SRL
      4'd7:    r = $unsigned($signed(in_a) >>> in_b[4:0]);   // SRA
      4'd8:    r = in_a | in_b;                              // OR
      4'd9:    r = in_a & in_b;                              // AND
      default: r = 32'b0;
    endcase
  end

  assign result = r;

endmodule

`default_nettype wire
