/*
 * TinyTapeout wrapper for the PicoRV32 SIMD vector co-processor demonstrator.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The core design boots a hardwired program that runs VADD8 / VSUB8 / VAND /
 * VOR on the vector unit and latches the four 32-bit results. This wrapper
 * exposes them through a byte-select mux (32 result bytes don't fit 8 pins):
 *
 *   ui_in[1:0] : byte select (0 = bits 7:0 ... 3 = bits 31:24)
 *   ui_in[3:2] : result select (0=VADD8, 1=VSUB8, 2=VAND, 3=VOR)
 *   uo_out     : selected result byte
 *   uio[0]     : test_done (output)
 *   uio[1]     : trap      (output)
 */
`default_nettype none

module tt_um_vec_coproc (
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
  wire [31:0] r_vadd8, r_vsub8, r_vand, r_vor;

  picorv32_vec_all_program_top core (
      .clk          (clk),
      .resetn       (rst_n),
      .trap         (trap),
      .test_done    (test_done),
      .result_vadd8 (r_vadd8),
      .result_vsub8 (r_vsub8),
      .result_vand  (r_vand),
      .result_vor   (r_vor)
  );

  reg [31:0] sel_word;
  always @(*) begin
    case (ui_in[3:2])
      2'd0: sel_word = r_vadd8;
      2'd1: sel_word = r_vsub8;
      2'd2: sel_word = r_vand;
      default: sel_word = r_vor;
    endcase
  end

  assign uo_out  = sel_word >> {ui_in[1:0], 3'b000};
  assign uio_out = {6'b0, trap, test_done};
  assign uio_oe  = 8'b0000_0011;

  wire _unused = &{ena, uio_in, ui_in[7:4], 1'b0};

endmodule
