/*
 * TinyTapeout wrapper for the PicoRV32 + neural branch predictor demonstrator.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The core boots a hardwired ROM self-test (counted loop with a backward
 * BNE, a sanity constant, and a RAM round-trip) while a perceptron branch
 * history table predicts on the live memory address stream. Four 32-bit
 * results are exposed through a byte-select mux:
 *
 *   ui_in[1:0] : byte select (0 = bits 7:0 ... 3 = bits 31:24)
 *   ui_in[3:2] : result select (0=loop count, 1=sanity constant,
 *                               2=predictor-taken cycle count, 3=RAM round-trip)
 *   uo_out     : selected result byte
 *   uio[0]     : test_done (output)
 *   uio[1]     : trap      (output)
 *   uio[2]     : bht_predict_taken, live (output)
 */
`default_nettype none

module tt_um_bp_soc (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  wire        trap;
  wire        test_done;
  wire        bht_predict_taken;
  wire [31:0] r0, r1, r2, r3;

  bp_demo_top core (
      .clk               (clk),
      .resetn            (rst_n),
      .trap              (trap),
      .test_done         (test_done),
      .bht_predict_taken (bht_predict_taken),
      .result0           (r0),
      .result1           (r1),
      .result2           (r2),
      .result3           (r3)
  );

  reg [31:0] sel_word;
  always @(*) begin
    case (ui_in[3:2])
      2'd0: sel_word = r0;
      2'd1: sel_word = r1;
      2'd2: sel_word = r2;
      default: sel_word = r3;
    endcase
  end

  assign uo_out  = sel_word >> {ui_in[1:0], 3'b000};
  assign uio_out = {5'b0, bht_predict_taken, trap, test_done};
  assign uio_oe  = 8'b0000_0111;

  wire _unused = &{ena, uio_in, ui_in[7:4], 1'b0};

endmodule
